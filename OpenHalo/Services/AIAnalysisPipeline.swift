import CoreGraphics
import Foundation
import AppKit

@MainActor
final class AIAnalysisPipeline {
    private let capture: ScreenCaptureService
    private let client: OpenRouterClient
    private let maximumRefinementPasses = 8
    private let visibleRefinementDelayNanoseconds: UInt64 = 250_000_000
    private let minimumRefinementBoxPixelSize = CGSize(width: 24, height: 24)
    private let minimumCropPixelSize = CGSize(width: 420, height: 420)
    private let cropExpansionFactor = 10.0
    private let oscillationMergeMarginPixels = CGSize(width: 8, height: 6)
    private let maximumOscillationMergePixelSize = CGSize(width: 96, height: 72)
    private let stableClusterMergeMarginPixels = CGSize(width: 8, height: 6)
    private let stableClusterWindowSize = 3
    private let stableClusterMaximumPixelSize = CGSize(width: 88, height: 72)
    private let stableClusterMaximumAverageBoxSize = CGSize(width: 48, height: 64)
    private let stableClusterMaximumCenterSpreadPixels = CGSize(width: 36, height: 32)
    private let actionChangeThreshold = 0.000_01
    private let defaultInitialPresentationConfidence = 0.62

    init(capture: ScreenCaptureService, client: OpenRouterClient) {
        self.capture = capture
        self.client = client
    }

    func analyze(
        query: String,
        settings: AppSettings,
        onIntermediateHighlights: ((NSScreen, [HighlightRegion]) -> Void)? = nil
    ) async throws -> AnalysisResult {
        let captureTarget = try resolveCaptureTarget()
        let debugSession = AnalysisDebugSession.create(
            query: query,
            model: settings.selectedModel
        )
        let reasoningConfiguration = settings.reasoningConfiguration

        if let debugSession {
            print("[OpenHalo] Debug artifacts will be saved to \(debugSession.rootURL.path)")
            debugSession.writeText(
                """
                Query: \(query)
                Model: \(settings.selectedModel)
                Compression quality: \(settings.compressionQuality)
                Reasoning enabled: \(reasoningConfiguration != nil)
                Reasoning effort: \(reasoningConfiguration?.effort ?? "off")
                Reasoning exclude trace: \(reasoningConfiguration?.exclude ?? false)
                Structured output mode: json_schema with json_object fallback
                Target display ID: \(captureTarget.displayID)
                Screen frame: \(NSStringFromRect(captureTarget.screen.frame))
                """,
                named: "00_run_context.txt"
            )
        }

        // 1. Capture screenshot from the same display we will later overlay on
        let screenshot = try await capture.captureDisplay(displayID: captureTarget.displayID)
        debugSession?.writeImage(screenshot, named: "01_initial_capture.png")

        // 2. Get screen dimensions for coordinate mapping
        let screenSize = captureTarget.screen.frame.size
        let screenshotSize = CGSize(width: screenshot.width, height: screenshot.height)

        // 3. Convert to JPEG base64
        let base64 = try screenshot.toBase64JPEG(quality: settings.compressionQuality)

        // 4. Build system prompt
        let systemPrompt = Self.buildDetectionPrompt(
            imageWidth: Int(screenshotSize.width),
            imageHeight: Int(screenshotSize.height)
        )
        debugSession?.writeText(
            """
            === SYSTEM PROMPT ===
            \(systemPrompt)

            === USER QUERY ===
            \(query)
            """,
            named: "02_initial_request.txt"
        )

        // 5. Send to OpenRouter
        let rawInitialResponse: AIAnalysisResponse
        do {
            rawInitialResponse = try await client.analyzeScreenshot(
                base64Image: base64,
                userQuery: query,
                model: settings.selectedModel,
                apiKey: settings.apiKey,
                systemPrompt: systemPrompt,
                reasoning: reasoningConfiguration,
                rawContentHandler: { rawContent in
                    debugSession?.writeText(
                        rawContent,
                        named: "03_initial_response_content.txt"
                    )
                }
            )
        } catch {
            debugSession?.writeText(
                "error=\(error.localizedDescription)",
                named: "03_initial_error.txt"
            )
            throw error
        }
        debugSession?.writeText(
            Self.describe(rawInitialResponse),
            named: "03_initial_response_raw.txt"
        )

        let initialResponse = Self.normalizedResponse(
            rawInitialResponse,
            imageSize: screenshotSize,
            debugSession: debugSession
        )
        debugSession?.writeText(
            Self.describe(initialResponse),
            named: "04_initial_response.txt"
        )

        let aiResponse = await refineHighlightsIfNeeded(
            initialResponse,
            captureTarget: captureTarget,
            screenshotSize: screenshotSize,
            query: query,
            settings: settings,
            debugSession: debugSession,
            onIntermediateHighlights: onIntermediateHighlights
        )
        debugSession?.writeText(
            Self.describe(aiResponse),
            named: "99_final_response.txt"
        )

        // 6. Convert normalized coordinates to screen points
        let highlights = buildHighlightRegions(
            from: aiResponse.highlights,
            primaryHighlightId: aiResponse.nextAction?.highlightId,
            screenSize: screenSize,
            showsLabels: true
        )

        return AnalysisResult(
            responseText: Self.responseText(from: aiResponse),
            highlights: highlights,
            targetScreen: captureTarget.screen
        )
    }

    private func resolveCaptureTarget() throws -> CaptureTarget {
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        guard let screen = targetScreen else {
            throw ScreenCaptureError.noDisplayFound
        }

        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw ScreenCaptureError.noDisplayFound
        }

        return CaptureTarget(
            screen: screen,
            displayID: CGDirectDisplayID(screenNumber.uint32Value)
        )
    }

    private func refineHighlightsIfNeeded(
        _ response: AIAnalysisResponse,
        captureTarget: CaptureTarget,
        screenshotSize: CGSize,
        query: String,
        settings: AppSettings,
        debugSession: AnalysisDebugSession?,
        onIntermediateHighlights: ((NSScreen, [HighlightRegion]) -> Void)?
    ) async -> AIAnalysisResponse {
        guard !response.highlights.isEmpty else {
            print("[OpenHalo] No highlights to refine")
            debugSession?.appendLine("No highlights returned from initial detection.")
            return response
        }

        let activeHighlightIndex = Self.activeHighlightIndex(
            highlights: response.highlights,
            primaryHighlightId: response.nextAction?.highlightId
        )
        guard let activeHighlightIndex else {
            print("[OpenHalo] No active highlight resolved for refinement")
            debugSession?.appendLine("No active highlight index resolved for refinement.")
            return response
        }

        print("[OpenHalo] Starting VLA refinement for highlight index \(activeHighlightIndex) out of \(response.highlights.count)")
        debugSession?.appendLine("Active highlight index: \(activeHighlightIndex)")

        var currentHighlights = response.highlights.map {
            AIAnalysisResponse.HighlightData(
                id: $0.id,
                label: $0.label,
                boundingBox: $0.boundingBox.clampedToUnitSpace(),
                elementType: $0.elementType
            )
        }
        var bestPresentationCandidate = PresentationCandidate(
            box: currentHighlights[activeHighlightIndex].boundingBox,
            confidence: defaultInitialPresentationConfidence,
            source: "initial_detection"
        )

        let seededBox = currentHighlights[activeHighlightIndex]
            .boundingBox
            .expandedToMinimumPixelSize(
                imageSize: screenshotSize,
                minimumPixelSize: minimumRefinementBoxPixelSize
            )
        if !seededBox.isClose(
            to: currentHighlights[activeHighlightIndex].boundingBox,
            threshold: actionChangeThreshold
        ) {
            debugSession?.appendLine(
                "Expanded active refinement box from \(Self.describe(currentHighlights[activeHighlightIndex].boundingBox)) to \(Self.describe(seededBox))"
            )
            currentHighlights[activeHighlightIndex] = AIAnalysisResponse.HighlightData(
                id: currentHighlights[activeHighlightIndex].id,
                label: currentHighlights[activeHighlightIndex].label,
                boundingBox: seededBox,
                elementType: currentHighlights[activeHighlightIndex].elementType
            )
        }

        let screenSize = captureTarget.screen.frame.size
        var refinementHistory = [currentHighlights[activeHighlightIndex].boundingBox]
        onIntermediateHighlights?(
            captureTarget.screen,
            buildHighlightRegions(
                from: currentHighlights,
                primaryHighlightId: response.nextAction?.highlightId,
                screenSize: screenSize,
                showsLabels: false
            )
        )

        for pass in 1...maximumRefinementPasses {
            do {
                try await Task.sleep(nanoseconds: visibleRefinementDelayNanoseconds)
            } catch {
                print("[OpenHalo] Refinement sleep interrupted on pass \(pass)")
            }

            let currentScreenshot: CGImage
            do {
                currentScreenshot = try await capture.captureDisplay(displayID: captureTarget.displayID)
            } catch {
                print("[OpenHalo] Failed to recapture display for refinement pass \(pass): \(error.localizedDescription)")
                debugSession?.appendLine("Pass \(pass): recapture failed - \(error.localizedDescription)")
                break
            }
            debugSession?.writeImage(
                currentScreenshot,
                named: String(format: "%02d_refinement_capture.png", pass)
            )

            let activeHighlight = currentHighlights[activeHighlightIndex]
            let refinementResult = await refineHighlight(
                activeHighlight,
                bestPresentationBox: bestPresentationCandidate.box,
                historyBoxes: refinementHistory,
                screenshot: currentScreenshot,
                query: query,
                settings: settings,
                pass: pass,
                debugSession: debugSession
            )

            if refinementResult.accepted {
                let selectedCandidate = Self.resolveModelPreferredCandidate(
                    preferredCandidate: refinementResult.preferredCandidate,
                    current: PresentationCandidate(
                        box: activeHighlight.boundingBox,
                        confidence: refinementResult.confidence,
                        source: "accept_pass_\(pass)"
                    ),
                    bestSoFar: bestPresentationCandidate
                )
                bestPresentationCandidate = selectedCandidate
                currentHighlights[activeHighlightIndex] = AIAnalysisResponse.HighlightData(
                    id: currentHighlights[activeHighlightIndex].id,
                    label: currentHighlights[activeHighlightIndex].label,
                    boundingBox: selectedCandidate.box,
                    elementType: currentHighlights[activeHighlightIndex].elementType
                )
                print("[OpenHalo] VLA controller accepted current box on pass \(pass)")
                debugSession?.writeText(
                    """
                    status=accept
                    pass=\(pass)
                    preferred_candidate=\(refinementResult.preferredCandidate?.rawValue ?? "fallback")
                    current_box=\(Self.describe(activeHighlight.boundingBox))
                    best_so_far_box=\(Self.describe(bestPresentationCandidate.box))
                    selected_source=\(selectedCandidate.source)
                    selected_box=\(Self.describe(selectedCandidate.box))
                    """,
                    named: String(format: "%02d_refinement_decision.txt", pass)
                )
                break
            }

            guard refinementResult.replacementBox != nil ||
                refinementResult.adjustment != nil ||
                (refinementResult.action != nil && refinementResult.stepSize != nil) else {
                print("[OpenHalo] Refinement returned adjust without usable compensation on pass \(pass); stopping")
                debugSession?.appendLine("Pass \(pass): received adjust without usable compensation.")
                break
            }

            let previousBox = currentHighlights[activeHighlightIndex].boundingBox
            let updatedBox: AIAnalysisResponse.BoundingBox
            if let replacementBox = refinementResult.replacementBox {
                updatedBox = replacementBox.clampedToUnitSpace()
            } else if let adjustment = refinementResult.adjustment {
                updatedBox = Self.applyAdjustment(
                    to: previousBox,
                    adjustment: adjustment
                )
            } else if let action = refinementResult.action, let stepSize = refinementResult.stepSize {
                updatedBox = Self.applyAction(
                    to: previousBox,
                    action: action,
                    stepSize: stepSize
                )
            } else {
                break
            }
            let changed = !updatedBox.isClose(
                to: previousBox,
                threshold: actionChangeThreshold
            )

            currentHighlights[activeHighlightIndex] = AIAnalysisResponse.HighlightData(
                id: currentHighlights[activeHighlightIndex].id,
                label: currentHighlights[activeHighlightIndex].label,
                boundingBox: updatedBox,
                elementType: currentHighlights[activeHighlightIndex].elementType
            )
            refinementHistory.append(updatedBox)

            let currentCandidate = PresentationCandidate(
                box: updatedBox,
                confidence: refinementResult.confidence,
                source: "pass_\(pass)"
            )
            let promotedCandidate = Self.resolveModelPreferredCandidate(
                preferredCandidate: refinementResult.preferredCandidate,
                current: currentCandidate,
                bestSoFar: bestPresentationCandidate
            )
            if promotedCandidate.box != bestPresentationCandidate.box || promotedCandidate.source != bestPresentationCandidate.source {
                debugSession?.appendLine(
                    "Pass \(pass): promoted best presentation candidate from \(Self.describe(bestPresentationCandidate.box)) to \(Self.describe(promotedCandidate.box)) [source=\(promotedCandidate.source)]."
                )
                bestPresentationCandidate = promotedCandidate
            }

            debugSession?.writeText(
                """
                status=adjust
                pass=\(pass)
                preferred_candidate=\(refinementResult.preferredCandidate?.rawValue ?? "current(default)")
                dx=\(refinementResult.adjustment?.dx ?? 0.0)
                dy=\(refinementResult.adjustment?.dy ?? 0.0)
                dw=\(refinementResult.adjustment?.dw ?? 0.0)
                dh=\(refinementResult.adjustment?.dh ?? 0.0)
                action=\(refinementResult.action?.rawValue ?? "nil")
                step=\(refinementResult.stepSize?.rawValue ?? "nil")
                replacement_box=\(refinementResult.replacementBox.map(Self.describe) ?? "nil")
                previous_box=\(Self.describe(previousBox))
                updated_box=\(Self.describe(updatedBox))
                best_so_far_box=\(Self.describe(bestPresentationCandidate.box))
                best_so_far_source=\(bestPresentationCandidate.source)
                """,
                named: String(format: "%02d_refinement_decision.txt", pass)
            )

            onIntermediateHighlights?(
                captureTarget.screen,
                buildHighlightRegions(
                    from: currentHighlights,
                    primaryHighlightId: response.nextAction?.highlightId,
                    screenSize: screenSize,
                    showsLabels: false
                )
            )

            if !changed {
                print("[OpenHalo] Refinement compensation produced no meaningful box change on pass \(pass); stopping")
                debugSession?.appendLine("Pass \(pass): compensation produced no meaningful change.")
                break
            }
        }

        currentHighlights[activeHighlightIndex] = AIAnalysisResponse.HighlightData(
            id: currentHighlights[activeHighlightIndex].id,
            label: currentHighlights[activeHighlightIndex].label,
            boundingBox: bestPresentationCandidate.box,
            elementType: currentHighlights[activeHighlightIndex].elementType
        )
        debugSession?.appendLine(
            "Final selected presentation box: \(Self.describe(bestPresentationCandidate.box)) [source=\(bestPresentationCandidate.source)]."
        )

        return AIAnalysisResponse(
            message: response.message,
            summary: response.summary,
            nextAction: response.nextAction,
            steps: response.steps,
            highlights: currentHighlights
        )
    }

    private func refineHighlight(
        _ highlight: AIAnalysisResponse.HighlightData,
        bestPresentationBox: AIAnalysisResponse.BoundingBox,
        historyBoxes: [AIAnalysisResponse.BoundingBox],
        screenshot: CGImage,
        query: String,
        settings: AppSettings,
        pass: Int,
        debugSession: AnalysisDebugSession?
    ) async -> HighlightRefinementResult {
        let currentBox = highlight.boundingBox.clampedToUnitSpace()

        print("[OpenHalo] Refining highlight \(highlight.id) label=\"\(highlight.label)\" pass=\(pass) startingBox=\(currentBox)")

        do {
            let renderings = try AnnotatedScreenshotRenderer.renderRefinementImages(
                image: screenshot,
                currentBox: currentBox,
                historyBoxes: historyBoxes,
                bestPresentationBox: bestPresentationBox,
                minimumCropPixelSize: minimumCropPixelSize,
                cropExpansionFactor: cropExpansionFactor
            )
            debugSession?.writeImage(
                renderings.fullAnnotatedImage,
                named: String(format: "%02d_refinement_full_annotated.png", pass)
            )
            debugSession?.writeImage(
                renderings.cropAnnotatedImage,
                named: String(format: "%02d_refinement_crop_annotated.png", pass)
            )
            debugSession?.writeImage(
                renderings.cropAnnotatedImage,
                named: String(format: "%02d_refinement_annotated.png", pass)
            )
            let fullAnnotatedBase64 = try renderings.fullAnnotatedImage.toBase64JPEG(
                quality: settings.compressionQuality
            )
            let cropAnnotatedBase64 = try renderings.cropAnnotatedImage.toBase64JPEG(
                quality: settings.compressionQuality
            )
            let userPrompt = Self.buildRefinementUserPrompt(
                query: query,
                highlight: highlight,
                currentBox: currentBox,
                bestPresentationBox: bestPresentationBox,
                historyBoxes: historyBoxes,
                cropBox: renderings.cropBoxInImage,
                currentBoxInCrop: renderings.currentBoxInCrop,
                bestBoxInCrop: renderings.bestBoxInCrop,
                iteration: pass
            )
            debugSession?.writeText(
                """
                === SYSTEM PROMPT ===
                \(Self.buildRefinementPrompt())

                === USER PROMPT ===
                \(userPrompt)
                """,
                named: String(format: "%02d_refinement_request.txt", pass)
            )

            let refinement = try await client.refineHighlight(
                base64Images: [
                    fullAnnotatedBase64,
                    cropAnnotatedBase64,
                ],
                userPrompt: userPrompt,
                model: settings.selectedModel,
                apiKey: settings.apiKey,
                systemPrompt: Self.buildRefinementPrompt(),
                reasoning: settings.reasoningConfiguration,
                rawContentHandler: { rawContent in
                    debugSession?.writeText(
                        rawContent,
                        named: String(format: "%02d_refinement_response_content.txt", pass)
                    )
                }
            )
            debugSession?.writeText(
                Self.describe(refinement),
                named: String(format: "%02d_refinement_response.txt", pass)
            )

            print("[OpenHalo] Refinement pass \(pass) for \(highlight.id): status=\(refinement.status.rawValue) confidence=\(refinement.confidence ?? -1) reason=\(refinement.reason ?? "n/a")")

            switch refinement.status {
            case .accept:
                return HighlightRefinementResult(
                    accepted: true,
                    preferredCandidate: refinement.preferredCandidate,
                    coordinateSpace: refinement.coordinateSpace,
                    replacementBox: nil,
                    adjustment: nil,
                    action: nil,
                    stepSize: nil,
                    confidence: refinement.confidence
                )

            case .adjust:
                if let targetBox = refinement.targetBox,
                   let coordinateSpace = refinement.coordinateSpace {
                    let globalTargetBox: AIAnalysisResponse.BoundingBox
                    switch coordinateSpace {
                    case .crop:
                        let normalizedCropBox = targetBox.normalizedForImageSize(renderings.cropImageSize)
                        globalTargetBox = Self.mapCropBoxToImage(
                            normalizedCropBox,
                            cropBoxInImage: renderings.cropBoxInImage
                        )
                    case .screen:
                        let screenImageSize = CGSize(
                            width: screenshot.width,
                            height: screenshot.height
                        )
                        globalTargetBox = targetBox.normalizedForImageSize(screenImageSize)
                    }

                    return HighlightRefinementResult(
                        accepted: false,
                        preferredCandidate: refinement.preferredCandidate,
                        coordinateSpace: refinement.coordinateSpace,
                        replacementBox: globalTargetBox,
                        adjustment: nil,
                        action: nil,
                        stepSize: nil,
                        confidence: refinement.confidence
                    )
                }

                if refinement.hasRelativeAdjustment {
                    return HighlightRefinementResult(
                        accepted: false,
                        preferredCandidate: refinement.preferredCandidate,
                        coordinateSpace: refinement.coordinateSpace,
                        replacementBox: nil,
                        adjustment: Self.normalizedAdjustment(from: refinement),
                        action: nil,
                        stepSize: nil,
                        confidence: refinement.confidence
                    )
                }

                guard let action = refinement.action, let stepSize = refinement.stepSize else {
                    print("[OpenHalo] Refinement returned adjust without compensation for \(highlight.id); stopping")
                    return HighlightRefinementResult(
                        accepted: true,
                        preferredCandidate: refinement.preferredCandidate,
                        coordinateSpace: refinement.coordinateSpace,
                        replacementBox: nil,
                        adjustment: nil,
                        action: nil,
                        stepSize: nil,
                        confidence: refinement.confidence
                    )
                }

                return HighlightRefinementResult(
                    accepted: false,
                    preferredCandidate: refinement.preferredCandidate,
                    coordinateSpace: refinement.coordinateSpace,
                    replacementBox: nil,
                    adjustment: nil,
                    action: action,
                    stepSize: stepSize,
                    confidence: refinement.confidence
                )
            }
        } catch {
            print("[OpenHalo] Refinement failed for \(highlight.id) on pass \(pass): \(error.localizedDescription)")
            debugSession?.writeText(
                "error=\(error.localizedDescription)",
                named: String(format: "%02d_refinement_error.txt", pass)
            )
            return HighlightRefinementResult(
                accepted: true,
                preferredCandidate: .bestSoFar,
                coordinateSpace: nil,
                replacementBox: nil,
                adjustment: nil,
                action: nil,
                stepSize: nil,
                confidence: nil
            )
        }
    }

    nonisolated static func applyAdjustment(
        to box: AIAnalysisResponse.BoundingBox,
        adjustment: RelativeBoxAdjustment
    ) -> AIAnalysisResponse.BoundingBox {
        let clampedBox = box.clampedToUnitSpace()
        let safeWidth = max(clampedBox.width, 0.001)
        let safeHeight = max(clampedBox.height, 0.001)

        let centerX = clampedBox.x + (clampedBox.width / 2) + (adjustment.dx * safeWidth)
        let centerY = clampedBox.y + (clampedBox.height / 2) + (adjustment.dy * safeHeight)
        let widthScale = max(0.1, 1.0 + adjustment.dw)
        let heightScale = max(0.1, 1.0 + adjustment.dh)
        let width = clampedBox.width * widthScale
        let height = clampedBox.height * heightScale

        return AIAnalysisResponse.BoundingBox(
            x: centerX - (width / 2),
            y: centerY - (height / 2),
            width: width,
            height: height
        ).clampedToUnitSpace()
    }

    nonisolated static func mapCropBoxToImage(
        _ cropBox: AIAnalysisResponse.BoundingBox,
        cropBoxInImage: AIAnalysisResponse.BoundingBox
    ) -> AIAnalysisResponse.BoundingBox {
        AIAnalysisResponse.BoundingBox(
            x: cropBoxInImage.x + (cropBox.x * cropBoxInImage.width),
            y: cropBoxInImage.y + (cropBox.y * cropBoxInImage.height),
            width: cropBox.width * cropBoxInImage.width,
            height: cropBox.height * cropBoxInImage.height
        ).clampedToUnitSpace()
    }

    nonisolated static func oscillationMergeBox(
        from history: [AIAnalysisResponse.BoundingBox],
        imageSize: CGSize,
        marginPixels: CGSize,
        maximumPixelSize: CGSize
    ) -> AIAnalysisResponse.BoundingBox? {
        guard history.count >= 3 else { return nil }

        let recent = Array(history.suffix(3))
        let first = recent[0].clampedToUnitSpace()
        let second = recent[1].clampedToUnitSpace()
        let third = recent[2].clampedToUnitSpace()

        let averageWidth = (first.width + second.width + third.width) / 3
        let averageHeight = (first.height + second.height + third.height) / 3
        let revisitThreshold = max(0.002, max(averageWidth, averageHeight) * 0.35)

        guard first.isClose(to: third, threshold: revisitThreshold) else { return nil }
        guard !first.isClose(to: second, threshold: revisitThreshold) else { return nil }

        let centerYs = [
            first.y + (first.height / 2),
            second.y + (second.height / 2),
            third.y + (third.height / 2),
        ]
        let verticalSpreadPixels = (centerYs.max()! - centerYs.min()!) * imageSize.height
        let averageHeightPixels = averageHeight * imageSize.height
        guard verticalSpreadPixels <= max(12.0, averageHeightPixels * 0.75) else { return nil }

        let merged = mergeBoxes(
            [first, second, third],
            imageSize: imageSize,
            marginPixels: marginPixels
        )
        let mergedWidthPixels = merged.width * imageSize.width
        let mergedHeightPixels = merged.height * imageSize.height
        let averageWidthPixels = averageWidth * imageSize.width
        let maximumAllowedWidthPixels = min(
            maximumPixelSize.width,
            max(44.0, averageWidthPixels * 3.4)
        )
        let maximumAllowedHeightPixels = min(
            maximumPixelSize.height,
            max(28.0, averageHeightPixels * 1.8)
        )

        guard mergedWidthPixels <= maximumAllowedWidthPixels else { return nil }
        guard mergedHeightPixels <= maximumAllowedHeightPixels else { return nil }

        return merged
    }

    nonisolated static func stableClusterMergeBox(
        from history: [AIAnalysisResponse.BoundingBox],
        imageSize: CGSize,
        recentCount: Int,
        marginPixels: CGSize,
        maximumPixelSize: CGSize,
        maximumAverageBoxSize: CGSize,
        maximumCenterSpreadPixels: CGSize
    ) -> AIAnalysisResponse.BoundingBox? {
        guard history.count >= recentCount else { return nil }

        let recent = Array(history.suffix(recentCount)).map { $0.clampedToUnitSpace() }
        let centerXs = recent.map { ($0.x + ($0.width / 2)) * imageSize.width }
        let centerYs = recent.map { ($0.y + ($0.height / 2)) * imageSize.height }
        let widths = recent.map { $0.width * imageSize.width }
        let heights = recent.map { $0.height * imageSize.height }

        let centerSpreadX = (centerXs.max() ?? 0) - (centerXs.min() ?? 0)
        let centerSpreadY = (centerYs.max() ?? 0) - (centerYs.min() ?? 0)
        let averageWidth = widths.reduce(0, +) / Double(max(widths.count, 1))
        let averageHeight = heights.reduce(0, +) / Double(max(heights.count, 1))

        guard centerSpreadX <= maximumCenterSpreadPixels.width else { return nil }
        guard centerSpreadY <= maximumCenterSpreadPixels.height else { return nil }
        guard averageWidth <= maximumAverageBoxSize.width else { return nil }
        guard averageHeight <= maximumAverageBoxSize.height else { return nil }

        let first = recent.first!
        let last = recent.last!
        guard !first.isClose(to: last, threshold: 0.0015) else { return nil }

        let merged = mergeBoxes(
            recent,
            imageSize: imageSize,
            marginPixels: marginPixels
        )
        let mergedWidthPixels = merged.width * imageSize.width
        let mergedHeightPixels = merged.height * imageSize.height

        guard mergedWidthPixels <= maximumPixelSize.width else { return nil }
        guard mergedHeightPixels <= maximumPixelSize.height else { return nil }

        return merged
    }

    nonisolated static func resolveModelPreferredCandidate(
        preferredCandidate: AIHighlightRefinementResponse.PreferredCandidate?,
        current: PresentationCandidate,
        bestSoFar: PresentationCandidate
    ) -> PresentationCandidate {
        switch preferredCandidate {
        case .current:
            return current
        case .bestSoFar:
            return bestSoFar
        case nil:
            return current
        }
    }

    nonisolated static func intersectionOverUnion(
        _ lhs: AIAnalysisResponse.BoundingBox,
        _ rhs: AIAnalysisResponse.BoundingBox
    ) -> Double {
        let left = max(lhs.x, rhs.x)
        let top = max(lhs.y, rhs.y)
        let right = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let bottom = min(lhs.y + lhs.height, rhs.y + rhs.height)

        guard right > left, bottom > top else { return 0.0 }

        let intersection = (right - left) * (bottom - top)
        let union = (lhs.width * lhs.height) + (rhs.width * rhs.height) - intersection
        guard union > 0 else { return 0.0 }
        return intersection / union
    }

    nonisolated static func centerDistancePixels(
        _ lhs: AIAnalysisResponse.BoundingBox,
        _ rhs: AIAnalysisResponse.BoundingBox,
        imageSize: CGSize
    ) -> Double {
        let lhsCenterX = (lhs.x + (lhs.width / 2)) * imageSize.width
        let lhsCenterY = (lhs.y + (lhs.height / 2)) * imageSize.height
        let rhsCenterX = (rhs.x + (rhs.width / 2)) * imageSize.width
        let rhsCenterY = (rhs.y + (rhs.height / 2)) * imageSize.height
        return hypot(lhsCenterX - rhsCenterX, lhsCenterY - rhsCenterY)
    }

    nonisolated private static func mergeBoxes(
        _ boxes: [AIAnalysisResponse.BoundingBox],
        imageSize: CGSize,
        marginPixels: CGSize
    ) -> AIAnalysisResponse.BoundingBox {
        let minX = boxes.map(\.x).min() ?? 0.0
        let minY = boxes.map(\.y).min() ?? 0.0
        let maxX = boxes.map { $0.x + $0.width }.max() ?? 0.0
        let maxY = boxes.map { $0.y + $0.height }.max() ?? 0.0

        let marginX = marginPixels.width / max(imageSize.width, 1.0)
        let marginY = marginPixels.height / max(imageSize.height, 1.0)

        return AIAnalysisResponse.BoundingBox(
            x: minX - marginX,
            y: minY - marginY,
            width: (maxX - minX) + (marginX * 2),
            height: (maxY - minY) + (marginY * 2)
        ).clampedToUnitSpace()
    }

    nonisolated static func applyAction(
        to box: AIAnalysisResponse.BoundingBox,
        action: AIHighlightRefinementResponse.Action,
        stepSize: AIHighlightRefinementResponse.StepSize
    ) -> AIAnalysisResponse.BoundingBox {
        let clampedBox = box.clampedToUnitSpace()
        let movementFactor = Self.movementFactor(for: stepSize)
        let minimumMovement = Self.minimumMovement(for: stepSize)
        let scaleFactor = Self.scaleFactor(for: stepSize)

        var x = clampedBox.x
        var y = clampedBox.y
        var width = clampedBox.width
        var height = clampedBox.height

        switch action {
        case .left:
            x -= max(movementFactor * clampedBox.width, minimumMovement)
        case .right:
            x += max(movementFactor * clampedBox.width, minimumMovement)
        case .up:
            y -= max(movementFactor * clampedBox.height, minimumMovement)
        case .down:
            y += max(movementFactor * clampedBox.height, minimumMovement)
        case .wider:
            width *= scaleFactor
            x -= (width - clampedBox.width) / 2
        case .narrower:
            width /= scaleFactor
            x += (clampedBox.width - width) / 2
        case .taller:
            height *= scaleFactor
            y -= (height - clampedBox.height) / 2
        case .shorter:
            height /= scaleFactor
            y += (clampedBox.height - height) / 2
        case .grow:
            width *= scaleFactor
            height *= scaleFactor
            x -= (width - clampedBox.width) / 2
            y -= (height - clampedBox.height) / 2
        case .shrink:
            width /= scaleFactor
            height /= scaleFactor
            x += (clampedBox.width - width) / 2
            y += (clampedBox.height - height) / 2
        }

        return AIAnalysisResponse.BoundingBox(
            x: x,
            y: y,
            width: width,
            height: height
        ).clampedToUnitSpace()
    }

    nonisolated static func isOpposite(
        _ lhs: AIHighlightRefinementResponse.Action,
        _ rhs: AIHighlightRefinementResponse.Action
    ) -> Bool {
        switch (lhs, rhs) {
        case (.left, .right), (.right, .left),
             (.up, .down), (.down, .up),
             (.wider, .narrower), (.narrower, .wider),
             (.taller, .shorter), (.shorter, .taller),
             (.grow, .shrink), (.shrink, .grow):
            return true
        default:
            return false
        }
    }

    nonisolated private static func movementFactor(
        for stepSize: AIHighlightRefinementResponse.StepSize
    ) -> Double {
        switch stepSize {
        case .small:
            return 0.25
        case .medium:
            return 0.60
        case .large:
            return 1.20
        }
    }

    nonisolated private static func minimumMovement(
        for stepSize: AIHighlightRefinementResponse.StepSize
    ) -> Double {
        switch stepSize {
        case .small:
            return 0.03
        case .medium:
            return 0.06
        case .large:
            return 0.12
        }
    }

    nonisolated private static func scaleFactor(
        for stepSize: AIHighlightRefinementResponse.StepSize
    ) -> Double {
        switch stepSize {
        case .small:
            return 1.10
        case .medium:
            return 1.20
        case .large:
            return 1.35
        }
    }

    nonisolated private static func normalizedAdjustment(
        from refinement: AIHighlightRefinementResponse
    ) -> RelativeBoxAdjustment {
        RelativeBoxAdjustment(
            dx: clampCompensation(refinement.dx),
            dy: clampCompensation(refinement.dy),
            dw: clampCompensation(refinement.dw),
            dh: clampCompensation(refinement.dh)
        )
    }

    nonisolated private static func clampCompensation(_ value: Double?) -> Double {
        let raw = value ?? 0.0
        guard raw.isFinite else { return 0.0 }
        return min(max(raw, -6.0), 6.0)
    }

    nonisolated private static func activeHighlightIndex(
        highlights: [AIAnalysisResponse.HighlightData],
        primaryHighlightId: String?
    ) -> Int? {
        if let primaryHighlightId,
           let index = highlights.firstIndex(where: { $0.id == primaryHighlightId }) {
            return index
        }

        return highlights.isEmpty ? nil : 0
    }

    private func buildHighlightRegions(
        from highlights: [AIAnalysisResponse.HighlightData],
        primaryHighlightId: String?,
        screenSize: CGSize,
        showsLabels: Bool
    ) -> [HighlightRegion] {
        highlights.enumerated().map { index, data in
            let screenRect = ScreenGeometry.normalizedToOverlayRect(
                box: data.boundingBox,
                screenSize: screenSize
            )
            let isPrimary = if let primaryHighlightId {
                data.id == primaryHighlightId
            } else {
                index == 0
            }
            return HighlightRegion(
                id: data.id,
                label: data.label,
                screenRect: screenRect,
                stepNumber: nil,
                elementType: data.elementType,
                color: isPrimary ? .primary : .secondary,
                showsLabel: showsLabels
            )
        }
    }

    static func buildDetectionPrompt(imageWidth: Int, imageHeight: Int) -> String {
        """
        You are OpenHalo, a macOS screen assistant.
        Screenshot size: \(imageWidth)x\(imageHeight).

        Goal:
        - Find the UI element(s) that best satisfy the user's request on the CURRENT screenshot.
        - Return exactly one immediate next action the user can do right now.

        Output:
        - Return valid JSON only.
        - Follow the provided schema exactly.
        - Use these top-level keys only when applicable: message, summary, next_action, highlights.
        - Do not invent alternate keys such as element or bbox.
        - next_action must be an object, not a plain string.

        Bounding boxes:
        - Use normalized decimals in [0,1].
        - x/y are LEFT/TOP edges.
        - width/height are extents.
        - Never return pixel coordinates.
        - Keep boxes tight but visible.

        Semantics:
        - Interpret the request as the intended UI control/action, not as literal text to match.
        - Prefer control role, iconography, and app context over echoed words.
        - Ignore the OpenHalo assistant window, its chat bubbles, and any text that merely repeats the user's request unless the user explicitly asks about OpenHalo itself.
        - If nothing actionable is visible, return no highlight and say so briefly.

        next_action:
        - Return exactly one immediate next action.
        - Do not fabricate later steps from the initial screenshot.
        - Keep instruction concise, non-repetitive, and under 160 characters when possible.
        - Mention a keyboard shortcut at most once.
        - Do not repeat the same sentence or shortcut multiple times.

        Example valid response:
        {"message":"I found the Chrome close button.","summary":"Chrome close button is visible.","next_action":{"instruction":"Click the red close button at the top-left of the Chrome window.","highlight_id":"h1"},"highlights":[{"id":"h1","label":"Chrome close button","bounding_box":{"x":0.008,"y":0.018,"width":0.018,"height":0.03},"element_type":"button"}]}

        Example valid no-match response:
        {"message":"I cannot see a visible close button on this screenshot.","summary":"No actionable close button is visible.","next_action":{"instruction":"Bring the target window into view first.","highlight_id":null},"highlights":[]}

        Example invalid response shape:
        {"element":"Chrome close button","bbox":{"x":0.008,"y":0.018,"width":0.018,"height":0.03},"next_action":"Click it"}
        """
    }

    static func buildRefinementPrompt() -> String {
        """
        You refine a UI highlight for OpenHalo.

        Inputs:
        - Image 1: full-screen context with the CURRENT candidate box.
        - Image 2: zoomed crop around the CURRENT candidate box.

        Visual markers:
        - Current candidate: thick white/magenta box.
        - Best-so-far presentation candidate: green dashed box.
        - Earlier candidates: thin yellow dashed boxes with a teal trajectory.

        Goal:
        - Choose the most useful FINAL presentation box for a human click, not just the newest box.
        - If the current hypothesis is semantically wrong, retarget.
        - Prefer crop-space target_box when possible; use screen-space only for larger retargets.

        Output:
        - Return valid JSON only and follow the provided schema exactly.
        - Always set preferred_candidate to current or best_so_far on every response.
        - For accept, keep the selected preferred_candidate and do not move the box.
        - For adjust, return coordinate_space plus target_box and also say whether current or best_so_far is the better final presentation candidate right now.
        - Never return pixels.
        - Do not repeat explanations or output extra prose.

        Rules:
        - Reason from UI semantics and app context, not literal text.
        - Ignore the OpenHalo assistant window and echoed user text unless the user explicitly asks about OpenHalo.
        - The user clicks manually, so perfect click-precision is unnecessary.
        - Slightly larger but stable is better than tiny and jittery.
        - You, not the framework, decide which candidate is currently best for the final presentation box.

        Example accept:
        {"status":"accept","preferred_candidate":"best_so_far","reason":"The target is already clearly inside the best-so-far box.","confidence":0.91}

        Example adjust:
        {"status":"adjust","preferred_candidate":"current","coordinate_space":"crop","target_box":{"x":0.34,"y":0.28,"width":0.22,"height":0.24},"reason":"The target is slightly to the right in the crop, and this updated candidate is already the better final box.","confidence":0.78}
        """
    }

    nonisolated static func buildRefinementUserPrompt(
        query: String,
        highlight: AIAnalysisResponse.HighlightData,
        currentBox: AIAnalysisResponse.BoundingBox,
        bestPresentationBox: AIAnalysisResponse.BoundingBox,
        historyBoxes: [AIAnalysisResponse.BoundingBox],
        cropBox: AIAnalysisResponse.BoundingBox,
        currentBoxInCrop: AIAnalysisResponse.BoundingBox,
        bestBoxInCrop: AIAnalysisResponse.BoundingBox?,
        iteration: Int
    ) -> String {
        let historySummary: String
        if historyBoxes.count <= 1 {
            historySummary = "History: none."
        } else {
            let recentHistory = Array(historyBoxes.suffix(4))
            let lines = recentHistory.enumerated().map { index, box in
                "\(index + 1). \(describe(box))"
            }
            historySummary = "Recent history oldest->newest: \(lines.joined(separator: " | "))"
        }

        return """
        User request: \(query)
        Hypothesis label: \(highlight.label)
        Element type: \(highlight.elementType ?? "unknown")
        Pass: \(iteration)
        \(historySummary)

        Full-screen current box: \(describe(currentBox))
        Full-screen best-so-far box: \(describe(bestPresentationBox))
        Full-screen crop window: \(describe(cropBox))
        Crop-local current box: \(describe(currentBoxInCrop))
        Crop-local best-so-far box: \(bestBoxInCrop.map(describe) ?? "not_visible")

        Choose the UI element that best satisfies the request.
        On every response, choose which candidate is currently the better FINAL presentation box by setting preferred_candidate.
        If current is already good enough, return accept with the better preferred_candidate.
        Otherwise return a target_box in crop or screen space and still set preferred_candidate.
        """
    }

    nonisolated static func normalizedResponse(
        _ response: AIAnalysisResponse,
        imageSize: CGSize,
        debugSession: AnalysisDebugSession? = nil
    ) -> AIAnalysisResponse {
        let normalizedHighlights = response.highlights.map { highlight -> AIAnalysisResponse.HighlightData in
            let normalizedBox = highlight.boundingBox.normalizedForImageSize(imageSize)

            if !normalizedBox.isClose(to: highlight.boundingBox, threshold: 0.0001) {
                let rawDescription = String(
                    format: "x=%.4f y=%.4f width=%.4f height=%.4f",
                    highlight.boundingBox.x,
                    highlight.boundingBox.y,
                    highlight.boundingBox.width,
                    highlight.boundingBox.height
                )
                let normalizedDescription = String(
                    format: "x=%.4f y=%.4f width=%.4f height=%.4f",
                    normalizedBox.x,
                    normalizedBox.y,
                    normalizedBox.width,
                    normalizedBox.height
                )
                debugSession?.appendLine(
                    "Normalized box for \(highlight.id): raw=\(rawDescription) normalized=\(normalizedDescription)"
                )
            }

            return AIAnalysisResponse.HighlightData(
                id: highlight.id,
                label: highlight.label,
                boundingBox: normalizedBox,
                elementType: highlight.elementType
            )
        }

        let sanitizedMessage = sanitizeOptionalText(
            response.message,
            maxSentences: 3,
            maxCharacters: 280
        )
        let sanitizedSummary = sanitizeText(
            response.summary,
            maxSentences: 2,
            maxCharacters: 180
        )
        let sanitizedLegacySteps = response.steps
            .sorted(by: { $0.stepNumber < $1.stepNumber })
            .prefix(1)
            .map { step in
                AIAnalysisResponse.Step(
                    stepNumber: step.stepNumber,
                    instruction: sanitizeText(
                        step.instruction,
                        maxSentences: 3,
                        maxCharacters: 220
                    ),
                    highlightId: step.highlightId
                )
            }
            .filter { !$0.instruction.isEmpty }

        let sanitizedNextAction = sanitizeNextAction(
            response.nextAction ??
                sanitizedLegacySteps.first.map {
                    AIAnalysisResponse.NextAction(
                        instruction: $0.instruction,
                        highlightId: $0.highlightId
                    )
                }
        )
        let normalizedSteps = sanitizedNextAction.map {
            [
                AIAnalysisResponse.Step(
                    stepNumber: 1,
                    instruction: $0.instruction,
                    highlightId: $0.highlightId
                )
            ]
        } ?? []

        return AIAnalysisResponse(
            message: sanitizedMessage,
            summary: sanitizedSummary,
            nextAction: sanitizedNextAction,
            steps: normalizedSteps,
            highlights: normalizedHighlights
        )
    }

    nonisolated static func sanitizeText(
        _ text: String,
        maxSentences: Int,
        maxCharacters: Int
    ) -> String {
        let ellipsisPlaceholder = "<OPENHALO_ELLIPSIS>"
        let collapsedWhitespace = text
            .replacingOccurrences(of: "...", with: ellipsisPlaceholder)
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsedWhitespace.isEmpty else { return "" }

        let sentenceUnits = splitIntoSentenceUnits(collapsedWhitespace)
        var seen = Set<String>()
        var uniqueUnits: [String] = []

        for unit in sentenceUnits {
            let normalizedUnit = unit
                .replacingOccurrences(
                    of: #"\s+"#,
                    with: " ",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !normalizedUnit.isEmpty else { continue }
            let dedupeKey = normalizedUnit.lowercased()
            guard !seen.contains(dedupeKey) else { continue }
            seen.insert(dedupeKey)
            uniqueUnits.append(normalizedUnit)

            if uniqueUnits.count >= maxSentences {
                break
            }
        }

        let joined = uniqueUnits
            .joined(separator: " ")
            .replacingOccurrences(of: ellipsisPlaceholder, with: "...")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count > maxCharacters else { return joined }

        let trimmed = String(joined.prefix(maxCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let lastPunctuationIndex = trimmed.lastIndex(where: { ".。!?！？;；".contains($0) }) {
            return String(trimmed[...lastPunctuationIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    nonisolated private static func sanitizeOptionalText(
        _ text: String?,
        maxSentences: Int,
        maxCharacters: Int
    ) -> String? {
        guard let text else { return nil }
        let sanitized = sanitizeText(
            text,
            maxSentences: maxSentences,
            maxCharacters: maxCharacters
        )
        return sanitized.isEmpty ? nil : sanitized
    }

    nonisolated private static func sanitizeNextAction(
        _ action: AIAnalysisResponse.NextAction?
    ) -> AIAnalysisResponse.NextAction? {
        guard let action else { return nil }
        let instruction = sanitizeText(
            action.instruction,
            maxSentences: 3,
            maxCharacters: 220
        )
        guard !instruction.isEmpty else { return nil }
        return AIAnalysisResponse.NextAction(
            instruction: instruction,
            highlightId: action.highlightId
        )
    }

    nonisolated private static func splitIntoSentenceUnits(_ text: String) -> [String] {
        let terminators = CharacterSet(charactersIn: ".!?。！？;；")
        var units: [String] = []
        var current = ""

        for scalar in text.unicodeScalars {
            current.unicodeScalars.append(scalar)
            if terminators.contains(scalar) {
                let unit = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !unit.isEmpty {
                    units.append(unit)
                }
                current = ""
            }
        }

        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            units.append(trailing)
        }

        return units.isEmpty ? [text] : units
    }

    nonisolated private static func responseText(from response: AIAnalysisResponse) -> String {
        let message = response.message?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !message.isEmpty {
            return message
        }

        let nextInstruction = response.nextAction?.instruction
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if nextInstruction.isEmpty {
            return response.summary
        }

        let normalizedSummary = response.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSummary.isEmpty else {
            return nextInstruction
        }

        if normalizedSummary.caseInsensitiveCompare(nextInstruction) == .orderedSame {
            return nextInstruction
        }

        return "\(normalizedSummary)\n\nNext: \(nextInstruction)"
    }

    nonisolated private static func describe(_ response: AIAnalysisResponse) -> String {
        var lines: [String] = [
            "message: \(response.message ?? "")",
            "summary: \(response.summary)",
            "next_action: \(response.nextAction?.instruction ?? "") [highlight_id=\(response.nextAction?.highlightId ?? "nil")]",
            "steps:"
        ]

        if response.steps.isEmpty {
            lines.append("  (none)")
        } else {
            for step in response.steps.sorted(by: { $0.stepNumber < $1.stepNumber }) {
                lines.append("  \(step.stepNumber). \(step.instruction) [highlight_id=\(step.highlightId ?? "nil")]")
            }
        }

        lines.append("highlights:")
        if response.highlights.isEmpty {
            lines.append("  (none)")
        } else {
            for highlight in response.highlights {
                lines.append(
                    "  \(highlight.id) label=\"\(highlight.label)\" type=\(highlight.elementType ?? "unknown") box=\(describe(highlight.boundingBox))"
                )
            }
        }

        return lines.joined(separator: "\n")
    }

    nonisolated private static func describe(_ response: AIHighlightRefinementResponse) -> String {
        let confidence = response.confidence.map { String($0) } ?? "nil"
        let lines = [
            "status: \(response.status.rawValue)",
            "preferred_candidate: \(response.preferredCandidate?.rawValue ?? "nil")",
            "coordinate_space: \(response.coordinateSpace?.rawValue ?? "nil")",
            "target_box: \(response.targetBox.map(describe) ?? "nil")",
            "dx: \(response.dx.map { String($0) } ?? "nil")",
            "dy: \(response.dy.map { String($0) } ?? "nil")",
            "dw: \(response.dw.map { String($0) } ?? "nil")",
            "dh: \(response.dh.map { String($0) } ?? "nil")",
            "action: \(response.action?.rawValue ?? "nil")",
            "step: \(response.stepSize?.rawValue ?? "nil")",
            "confidence: \(confidence)",
            "reason: \(response.reason ?? "nil")"
        ]
        return lines.joined(separator: "\n")
    }

    nonisolated private static func describe(_ box: AIAnalysisResponse.BoundingBox) -> String {
        String(
            format: "x=%.4f y=%.4f width=%.4f height=%.4f",
            box.x,
            box.y,
            box.width,
            box.height
        )
    }
}

struct AnalysisResult {
    let responseText: String
    let highlights: [HighlightRegion]
    let targetScreen: NSScreen
}

private struct HighlightRefinementResult {
    let accepted: Bool
    let preferredCandidate: AIHighlightRefinementResponse.PreferredCandidate?
    let coordinateSpace: AIHighlightRefinementResponse.CoordinateSpace?
    let replacementBox: AIAnalysisResponse.BoundingBox?
    let adjustment: RelativeBoxAdjustment?
    let action: AIHighlightRefinementResponse.Action?
    let stepSize: AIHighlightRefinementResponse.StepSize?
    let confidence: Double?
}

private struct CaptureTarget {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
}

struct PresentationCandidate: Equatable {
    let box: AIAnalysisResponse.BoundingBox
    let confidence: Double?
    let source: String
}

struct RelativeBoxAdjustment: Equatable {
    let dx: Double
    let dy: Double
    let dw: Double
    let dh: Double
}
