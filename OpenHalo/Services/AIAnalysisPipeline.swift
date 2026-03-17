import CoreGraphics
import Foundation
import AppKit

@MainActor
final class AIAnalysisPipeline {
    private let capture: any ScreenFrameProviding
    private let client: OpenRouterClient
    private let maximumRefinementPasses = 30
    private let visibleRefinementDelayNanoseconds: UInt64 = 250_000_000
    private let minimumRefinementBoxPixelSize = CGSize(width: 24, height: 24)
    private let minimumCropPixelSize = CGSize(width: 420, height: 420)
    private let minimumActiveContentRenderSize = CGSize(width: 160, height: 160)
    private let cropExpansionFactor = 10.0
    private let actionCanvasMaximumOffset = 4.0
    private let actionCanvasGhostOffsetRange = -3...3
    private let oscillationMergeMarginPixels = CGSize(width: 8, height: 6)
    private let maximumOscillationMergePixelSize = CGSize(width: 96, height: 72)
    private let stableClusterMergeMarginPixels = CGSize(width: 8, height: 6)
    private let stableClusterWindowSize = 3
    private let stableClusterMaximumPixelSize = CGSize(width: 88, height: 72)
    private let stableClusterMaximumAverageBoxSize = CGSize(width: 48, height: 64)
    private let stableClusterMaximumCenterSpreadPixels = CGSize(width: 36, height: 32)
    private let actionChangeThreshold = 0.000_01
    private let defaultInitialPresentationConfidence = 0.62

    init(capture: any ScreenFrameProviding, client: OpenRouterClient) {
        self.capture = capture
        self.client = client
    }

    func planIntent(
        query: String,
        settings: AppSettings,
        context: PlannerConversationContext? = nil
    ) async throws -> AIIntentPlannerResponse {
        let captureTarget = try resolveCaptureTarget()
        try await capture.ensureRunning(for: captureTarget.displayID)
        let frame = try await capture.latestFrame(
            for: captureTarget.displayID,
            maxAge: 0.5,
            waitUpTo: 1.0
        )
        let screenshotSize = CGSize(width: frame.image.width, height: frame.image.height)
        let base64 = try frame.image.toBase64JPEG(quality: settings.compressionQuality)
        let systemPrompt = Self.buildPlannerPrompt(
            imageWidth: Int(screenshotSize.width),
            imageHeight: Int(screenshotSize.height)
        )
        let userPrompt = Self.buildPlannerUserPrompt(
            query: query,
            context: context
        )

        let rawResponse = try await client.planIntent(
            base64Image: base64,
            userPrompt: userPrompt,
            model: settings.selectedModel,
            apiKey: settings.apiKey,
            systemPrompt: systemPrompt,
            reasoning: settings.reasoningConfiguration
        )

        return Self.normalizedPlannerResponse(rawResponse)
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

        try await capture.ensureRunning(for: captureTarget.displayID)
        let initialFrame = try await capture.latestFrame(
            for: captureTarget.displayID,
            maxAge: 0.5,
            waitUpTo: 1.0
        )
        let frameTimestamp = ISO8601DateFormatter().string(from: initialFrame.capturedAt)

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
                Initial frame sequence: \(initialFrame.sequence)
                Initial frame capturedAt: \(frameTimestamp)
                """,
                named: "00_run_context.txt"
            )
        }

        // 1. Capture screenshot from the same display we will later overlay on
        let screenshot = initialFrame.image
        debugSession?.appendLine("Initial frame sequence=\(initialFrame.sequence) capturedAt=\(frameTimestamp)")
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
            initialFrame: initialFrame,
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
        initialFrame: CapturedFrame,
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

        let initialScore = Self.scoreFromConfidence(defaultInitialPresentationConfidence) ?? 62
        let initialNote = "Initial unverified detection candidate."
        let initialDescription = Self.sanitizedCandidateDescription(
            currentHighlights[activeHighlightIndex].label,
            fallback: "Initial target candidate."
        )
        var episodeMemory = EpisodeMemory(
            seedBox: currentHighlights[activeHighlightIndex].boundingBox,
            initialScore: initialScore,
            initialNote: initialNote,
            initialDescription: initialDescription,
            origin: "initial_detection"
        )
        debugSession?.writeText(
            Self.describe(episodeMemory),
            named: "00_episode_memory.txt"
        )

        let screenSize = captureTarget.screen.frame.size
        currentHighlights[activeHighlightIndex] = AIAnalysisResponse.HighlightData(
            id: currentHighlights[activeHighlightIndex].id,
            label: currentHighlights[activeHighlightIndex].label,
            boundingBox: episodeMemory.activeCandidate.box,
            elementType: currentHighlights[activeHighlightIndex].elementType
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

        var currentFrame = initialFrame
        for pass in 1...maximumRefinementPasses {
            do {
                try await Task.sleep(nanoseconds: visibleRefinementDelayNanoseconds)
            } catch {
                print("[OpenHalo] Refinement sleep interrupted on pass \(pass)")
            }

            let nextFrame: CapturedFrame?
            do {
                nextFrame = try await capture.nextFrame(
                    for: captureTarget.displayID,
                    after: currentFrame.sequence,
                    waitUpTo: 0.5
                )
            } catch {
                print("[OpenHalo] Failed to read next frame for refinement pass \(pass): \(error.localizedDescription)")
                debugSession?.appendLine("Pass \(pass): next frame read failed - \(error.localizedDescription)")
                break
            }

            guard let nextFrame else {
                debugSession?.appendLine(
                    "Pass \(pass): no newer frame arrived within 0.5s after frame sequence \(currentFrame.sequence); stopping refinement."
                )
                break
            }

            currentFrame = nextFrame
            let currentScreenshot = currentFrame.image
            debugSession?.appendLine(
                "Pass \(pass): using frame sequence \(currentFrame.sequence) capturedAt=\(ISO8601DateFormatter().string(from: currentFrame.capturedAt))"
            )
            debugSession?.writeImage(
                currentScreenshot,
                named: String(format: "%02d_refinement_capture.png", pass)
            )

            let refinementResult = await refineHighlight(
                highlight: currentHighlights[activeHighlightIndex],
                activeCandidate: episodeMemory.activeCandidate,
                bestCandidate: episodeMemory.bestCandidate,
                visibleCandidates: episodeMemory.visibleCandidates(maxAdditionalHistoryCandidates: 3),
                screenshot: currentScreenshot,
                query: query,
                settings: settings,
                pass: pass,
                debugSession: debugSession
            )

            episodeMemory.updateCandidateMetadata(
                id: episodeMemory.activeCandidateID,
                qualityScore: nil,
                evaluationNote: Self.sanitizedEvaluationNote(
                    refinementResult.activeCandidateAssessment ?? refinementResult.reason,
                    fallback: episodeMemory.activeCandidate.evaluationNote
                ),
                candidateDescription: Self.sanitizedCandidateDescription(
                    refinementResult.activeCandidateDescription,
                    fallback: episodeMemory.activeCandidate.candidateDescription
                )
            )

            if refinementResult.relocalizeRequested {
                let resolvedBestCandidateID = Self.resolveBestCandidateID(
                    explicitCandidateID: refinementResult.bestCandidateID,
                    legacyPreferredCandidate: refinementResult.legacyPreferredCandidate,
                    proposalCandidateID: nil,
                    episodeMemory: episodeMemory,
                    defaultCandidateID: episodeMemory.bestCandidateID
                )
                episodeMemory.bestCandidateID = resolvedBestCandidateID
                episodeMemory.updateCandidateMetadata(
                    id: resolvedBestCandidateID,
                    qualityScore: refinementResult.bestCandidateScore ?? Self.scoreFromConfidence(refinementResult.confidence),
                    evaluationNote: Self.sanitizedEvaluationNote(
                        refinementResult.bestCandidateNote ?? refinementResult.reason,
                        fallback: episodeMemory.candidate(withID: resolvedBestCandidateID)?.evaluationNote ?? "Model requested global relocalization."
                    ),
                    candidateDescription: nil
                )

                if let relocalizedHighlight = await relocalizeHighlight(
                    screenshot: currentScreenshot,
                    screenshotSize: screenshotSize,
                    query: query,
                    highlight: currentHighlights[activeHighlightIndex],
                    activeCandidate: episodeMemory.activeCandidate,
                    bestCandidate: episodeMemory.bestCandidate,
                    visibleCandidates: episodeMemory.visibleCandidates(maxAdditionalHistoryCandidates: 3),
                    settings: settings,
                    pass: pass,
                    debugSession: debugSession
                ) {
                    let relocalizedCandidate = episodeMemory.appendCandidate(
                        box: relocalizedHighlight.boundingBox.clampedToUnitSpace(),
                        passIndex: pass,
                        qualityScore: Self.scoreFromConfidence(refinementResult.confidence) ?? 78,
                        evaluationNote: Self.sanitizedEvaluationNote(
                            refinementResult.reason,
                            fallback: "Fresh global search candidate from pass \(pass)."
                        ),
                        candidateDescription: Self.sanitizedCandidateDescription(
                            relocalizedHighlight.label,
                            fallback: currentHighlights[activeHighlightIndex].label
                        ),
                        origin: "relocalize_pass_\(pass)"
                    )
                    episodeMemory.activeCandidateID = relocalizedCandidate.id
                    currentHighlights[activeHighlightIndex] = AIAnalysisResponse.HighlightData(
                        id: currentHighlights[activeHighlightIndex].id,
                        label: currentHighlights[activeHighlightIndex].label,
                        boundingBox: relocalizedCandidate.box,
                        elementType: currentHighlights[activeHighlightIndex].elementType
                    )
                    debugSession?.writeText(
                        """
                        status=relocalize
                        pass=\(pass)
                        active_candidate_id=\(episodeMemory.activeCandidateID)
                        best_candidate_id=\(episodeMemory.bestCandidateID)
                        relocalized_candidate_id=\(relocalizedCandidate.id)
                        relocalized_description=\(relocalizedCandidate.candidateDescription)
                        relocalized_note=\(relocalizedCandidate.evaluationNote)
                        relocalized_box=\(Self.describe(relocalizedCandidate.box))
                        best_so_far_box=\(Self.describe(episodeMemory.bestCandidate.box))
                        best_so_far_source=\(episodeMemory.bestCandidate.origin)
                        """,
                        named: String(format: "%02d_refinement_decision.txt", pass)
                    )
                    debugSession?.writeText(
                        Self.describe(episodeMemory),
                        named: String(format: "%02d_episode_memory.txt", pass)
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
                    continue
                }

                debugSession?.appendLine("Pass \(pass): relocalize requested but no usable global candidate was returned.")
                break
            }

            if refinementResult.accepted {
                let resolvedBestCandidateID = Self.resolveBestCandidateID(
                    explicitCandidateID: refinementResult.bestCandidateID,
                    legacyPreferredCandidate: refinementResult.legacyPreferredCandidate,
                    proposalCandidateID: nil,
                    episodeMemory: episodeMemory,
                    defaultCandidateID: episodeMemory.activeCandidateID
                )
                episodeMemory.bestCandidateID = resolvedBestCandidateID
                episodeMemory.updateCandidateMetadata(
                    id: resolvedBestCandidateID,
                    qualityScore: refinementResult.bestCandidateScore ?? Self.scoreFromConfidence(refinementResult.confidence),
                    evaluationNote: Self.sanitizedEvaluationNote(
                        refinementResult.bestCandidateNote ?? refinementResult.reason,
                        fallback: episodeMemory.candidate(withID: resolvedBestCandidateID)?.evaluationNote ?? "Accepted candidate."
                    ),
                    candidateDescription: nil
                )
                let selectedCandidate = episodeMemory.bestCandidate
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
                    active_candidate_id=\(episodeMemory.activeCandidateID)
                    best_candidate_id=\(episodeMemory.bestCandidateID)
                    selected_candidate_id=\(selectedCandidate.id)
                    selected_score=\(selectedCandidate.qualityScore)
                    selected_description=\(selectedCandidate.candidateDescription)
                    selected_note=\(selectedCandidate.evaluationNote)
                    selected_box=\(Self.describe(selectedCandidate.box))
                    """,
                    named: String(format: "%02d_refinement_decision.txt", pass)
                )
                debugSession?.writeText(
                    Self.describe(episodeMemory),
                    named: String(format: "%02d_episode_memory.txt", pass)
                )
                break
            }

            guard refinementResult.moveXY != nil ||
                refinementResult.proposalBox != nil ||
                refinementResult.adjustment != nil ||
                (refinementResult.action != nil && refinementResult.stepSize != nil) else {
                print("[OpenHalo] Refinement returned move without usable compensation on pass \(pass); stopping")
                debugSession?.appendLine("Pass \(pass): received move without usable compensation.")
                break
            }

            let previousCandidate = episodeMemory.activeCandidate
            let previousBox = previousCandidate.box
            let updatedBox: AIAnalysisResponse.BoundingBox
            if let moveXY = refinementResult.moveXY {
                updatedBox = Self.applyMove(
                    to: previousBox,
                    moveXY: moveXY
                )
            } else if let proposalBox = refinementResult.proposalBox {
                updatedBox = proposalBox.clampedToUnitSpace()
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

            let previousBestCandidateID = episodeMemory.bestCandidateID
            let proposalCandidate = episodeMemory.appendCandidate(
                box: updatedBox,
                passIndex: pass,
                qualityScore: refinementResult.proposalScore ?? Self.scoreFromConfidence(refinementResult.confidence) ?? previousCandidate.qualityScore,
                evaluationNote: Self.sanitizedEvaluationNote(
                    refinementResult.proposalNote ?? refinementResult.reason,
                    fallback: "Unverified move candidate from pass \(pass); verify it on the next screenshot."
                ),
                candidateDescription: Self.sanitizedCandidateDescription(
                    refinementResult.proposalDescription,
                    fallback: "Unverified moved candidate."
                ),
                origin: "refinement_pass_\(pass)"
            )
            episodeMemory.activeCandidateID = proposalCandidate.id

            let resolvedBestCandidateID = Self.resolveBestCandidateID(
                explicitCandidateID: refinementResult.bestCandidateID,
                legacyPreferredCandidate: refinementResult.legacyPreferredCandidate,
                proposalCandidateID: proposalCandidate.id,
                episodeMemory: episodeMemory,
                defaultCandidateID: previousBestCandidateID,
                allowProposalToken: false
            )
            episodeMemory.bestCandidateID = resolvedBestCandidateID
            episodeMemory.updateCandidateMetadata(
                id: resolvedBestCandidateID,
                qualityScore: refinementResult.bestCandidateScore ?? Self.scoreFromConfidence(refinementResult.confidence),
                evaluationNote: Self.sanitizedEvaluationNote(
                    refinementResult.bestCandidateNote ?? refinementResult.reason,
                    fallback: episodeMemory.candidate(withID: resolvedBestCandidateID)?.evaluationNote ?? "Best candidate selected by model."
                ),
                candidateDescription: nil
            )
            if previousBestCandidateID != resolvedBestCandidateID,
               let previousBest = episodeMemory.candidate(withID: previousBestCandidateID),
               let newBest = episodeMemory.candidate(withID: resolvedBestCandidateID) {
                debugSession?.appendLine(
                    "Pass \(pass): promoted best presentation candidate from \(previousBest.id) \(Self.describe(previousBest.box)) to \(newBest.id) \(Self.describe(newBest.box))."
                )
            }

            if let moveXY = refinementResult.moveXY {
                debugSession?.writeText(
                    """
                    action_origin_box=\(Self.describe(previousBox))
                    chosen_move_xy=x=\(String(format: "%.4f", moveXY.x)) y=\(String(format: "%.4f", moveXY.y))
                    resulting_box=\(Self.describe(updatedBox))
                    active_candidate_id=\(episodeMemory.activeCandidateID)
                    best_candidate_id=\(episodeMemory.bestCandidateID)
                    """,
                    named: String(format: "%02d_refinement_action_space.txt", pass)
                )
            }

            currentHighlights[activeHighlightIndex] = AIAnalysisResponse.HighlightData(
                id: currentHighlights[activeHighlightIndex].id,
                label: currentHighlights[activeHighlightIndex].label,
                boundingBox: episodeMemory.activeCandidate.box,
                elementType: currentHighlights[activeHighlightIndex].elementType
            )

            debugSession?.writeText(
                """
                status=\(refinementResult.moveXY != nil ? "move" : "adjust")
                pass=\(pass)
                active_candidate_id=\(episodeMemory.activeCandidateID)
                best_candidate_id=\(episodeMemory.bestCandidateID)
                selected_best_score=\(episodeMemory.bestCandidate.qualityScore)
                selected_best_description=\(episodeMemory.bestCandidate.candidateDescription)
                selected_best_note=\(episodeMemory.bestCandidate.evaluationNote)
                active_candidate_description=\(episodeMemory.activeCandidate.candidateDescription)
                move_x=\(refinementResult.moveXY.map { String(format: "%.1f", $0.x) } ?? "nil")
                move_y=\(refinementResult.moveXY.map { String(format: "%.1f", $0.y) } ?? "nil")
                action_origin_box=\(Self.describe(previousBox))
                dx=\(refinementResult.adjustment?.dx ?? 0.0)
                dy=\(refinementResult.adjustment?.dy ?? 0.0)
                dw=\(refinementResult.adjustment?.dw ?? 0.0)
                dh=\(refinementResult.adjustment?.dh ?? 0.0)
                action=\(refinementResult.action?.rawValue ?? "nil")
                step=\(refinementResult.stepSize?.rawValue ?? "nil")
                proposal_box=\(refinementResult.proposalBox.map(Self.describe) ?? "nil")
                proposal_candidate_id=\(proposalCandidate.id)
                proposal_score=\(proposalCandidate.qualityScore)
                proposal_description=\(proposalCandidate.candidateDescription)
                proposal_note=\(proposalCandidate.evaluationNote)
                previous_box=\(Self.describe(previousBox))
                updated_box=\(Self.describe(updatedBox))
                best_so_far_box=\(Self.describe(episodeMemory.bestCandidate.box))
                best_so_far_source=\(episodeMemory.bestCandidate.origin)
                """,
                named: String(format: "%02d_refinement_decision.txt", pass)
            )
            debugSession?.writeText(
                Self.describe(episodeMemory),
                named: String(format: "%02d_episode_memory.txt", pass)
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

        let bestPresentationCandidate = episodeMemory.bestCandidate
        currentHighlights[activeHighlightIndex] = AIAnalysisResponse.HighlightData(
            id: currentHighlights[activeHighlightIndex].id,
            label: currentHighlights[activeHighlightIndex].label,
            boundingBox: bestPresentationCandidate.box,
            elementType: currentHighlights[activeHighlightIndex].elementType
        )
        debugSession?.appendLine(
            "Final selected presentation box: \(bestPresentationCandidate.id) \(Self.describe(bestPresentationCandidate.box)) [origin=\(bestPresentationCandidate.origin) score=\(bestPresentationCandidate.qualityScore)]."
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
        highlight: AIAnalysisResponse.HighlightData,
        activeCandidate: EpisodeCandidate,
        bestCandidate: EpisodeCandidate,
        visibleCandidates: [EpisodeCandidate],
        screenshot: CGImage,
        query: String,
        settings: AppSettings,
        pass: Int,
        debugSession: AnalysisDebugSession?
    ) async -> HighlightRefinementResult {
        let currentBox = activeCandidate.box.clampedToUnitSpace()

        print("[OpenHalo] Refining highlight \(highlight.id) label=\"\(highlight.label)\" pass=\(pass) activeCandidate=\(activeCandidate.id) startingBox=\(currentBox)")

        do {
            let displayedCandidates = Self.renderedCandidates(
                from: visibleCandidates,
                activeCandidateID: activeCandidate.id,
                bestCandidateID: bestCandidate.id
            )
            let renderings = try AnnotatedScreenshotRenderer.renderRefinementImages(
                image: screenshot,
                displayedCandidates: displayedCandidates,
                activeCandidateID: activeCandidate.id,
                minimumCropPixelSize: minimumCropPixelSize,
                cropExpansionFactor: cropExpansionFactor,
                minimumActiveContentRenderSize: minimumActiveContentRenderSize,
                actionCanvasGhostOffsetRange: actionCanvasGhostOffsetRange
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
            debugSession?.writeImage(
                renderings.activeContentImage,
                named: String(format: "%02d_refinement_active_content.png", pass)
            )
            let fullAnnotatedBase64 = try renderings.fullAnnotatedImage.toBase64JPEG(
                quality: settings.compressionQuality
            )
            let cropAnnotatedBase64 = try renderings.cropAnnotatedImage.toBase64JPEG(
                quality: settings.compressionQuality
            )
            let activeContentBase64 = try renderings.activeContentImage.toBase64JPEG(
                quality: settings.compressionQuality
            )
            let userPrompt = Self.buildRefinementUserPrompt(
                query: query,
                highlight: highlight,
                activeCandidate: activeCandidate,
                bestCandidate: bestCandidate,
                visibleCandidates: visibleCandidates,
                cropBox: renderings.cropBoxInImage,
                activeContentBox: renderings.activeContentBoxInImage,
                cropCandidates: renderings.candidatesInCrop,
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
                    activeContentBase64,
                ],
                userPrompt: userPrompt,
                model: settings.selectedModel,
                apiKey: settings.apiKey,
                systemPrompt: Self.buildRefinementPrompt(),
                reasoning: nil,
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
                    relocalizeRequested: false,
                    activeCandidateDescription: refinement.activeCandidateDescription,
                    activeCandidateAssessment: refinement.activeCandidateAssessment,
                    bestCandidateID: refinement.bestCandidateID,
                    legacyPreferredCandidate: refinement.legacyPreferredCandidate,
                    bestCandidateScore: refinement.bestCandidateScore ?? Self.scoreFromConfidence(refinement.confidence),
                    bestCandidateNote: refinement.bestCandidateNote ?? refinement.reason,
                    moveXY: nil,
                    proposalBox: nil,
                    proposalScore: nil,
                    proposalNote: nil,
                    proposalDescription: nil,
                    adjustment: nil,
                    action: nil,
                    stepSize: nil,
                    confidence: refinement.confidence,
                    reason: refinement.reason
                )

            case .move:
                if let moveXY = refinement.moveXY {
                    return HighlightRefinementResult(
                        accepted: false,
                        relocalizeRequested: false,
                        activeCandidateDescription: refinement.activeCandidateDescription,
                        activeCandidateAssessment: refinement.activeCandidateAssessment,
                        bestCandidateID: refinement.bestCandidateID,
                        legacyPreferredCandidate: refinement.legacyPreferredCandidate,
                        bestCandidateScore: refinement.bestCandidateScore ?? Self.scoreFromConfidence(refinement.confidence),
                        bestCandidateNote: refinement.bestCandidateNote ?? refinement.reason,
                        moveXY: Self.clampedMoveXY(moveXY),
                        proposalBox: nil,
                        proposalScore: Self.scoreFromConfidence(refinement.confidence),
                        proposalNote: refinement.reason ?? "Predicted move candidate; verify on the next screenshot.",
                        proposalDescription: nil,
                        adjustment: nil,
                        action: nil,
                        stepSize: nil,
                        confidence: refinement.confidence,
                        reason: refinement.reason
                    )
                }

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
                        relocalizeRequested: false,
                        activeCandidateDescription: refinement.activeCandidateDescription,
                        activeCandidateAssessment: refinement.activeCandidateAssessment,
                        bestCandidateID: refinement.bestCandidateID,
                        legacyPreferredCandidate: refinement.legacyPreferredCandidate,
                        bestCandidateScore: refinement.bestCandidateScore ?? Self.scoreFromConfidence(refinement.confidence),
                        bestCandidateNote: refinement.bestCandidateNote ?? refinement.reason,
                        moveXY: nil,
                        proposalBox: globalTargetBox,
                        proposalScore: refinement.proposalScore ?? Self.scoreFromConfidence(refinement.confidence),
                        proposalNote: refinement.proposalNote ?? refinement.reason,
                        proposalDescription: refinement.proposalDescription,
                        adjustment: nil,
                        action: nil,
                        stepSize: nil,
                        confidence: refinement.confidence,
                        reason: refinement.reason
                    )
                }

                if refinement.hasRelativeAdjustment {
                    return HighlightRefinementResult(
                        accepted: false,
                        relocalizeRequested: false,
                        activeCandidateDescription: refinement.activeCandidateDescription,
                        activeCandidateAssessment: refinement.activeCandidateAssessment,
                        bestCandidateID: refinement.bestCandidateID,
                        legacyPreferredCandidate: refinement.legacyPreferredCandidate,
                        bestCandidateScore: refinement.bestCandidateScore ?? Self.scoreFromConfidence(refinement.confidence),
                        bestCandidateNote: refinement.bestCandidateNote ?? refinement.reason,
                        moveXY: nil,
                        proposalBox: nil,
                        proposalScore: refinement.proposalScore,
                        proposalNote: refinement.proposalNote,
                        proposalDescription: refinement.proposalDescription,
                        adjustment: Self.normalizedAdjustment(from: refinement),
                        action: nil,
                        stepSize: nil,
                        confidence: refinement.confidence,
                        reason: refinement.reason
                    )
                }

                guard let action = refinement.action, let stepSize = refinement.stepSize else {
                    print("[OpenHalo] Refinement returned adjust without compensation for \(highlight.id); stopping")
                    return HighlightRefinementResult(
                        accepted: false,
                        relocalizeRequested: false,
                        activeCandidateDescription: refinement.activeCandidateDescription,
                        activeCandidateAssessment: refinement.activeCandidateAssessment,
                        bestCandidateID: refinement.bestCandidateID ?? bestCandidate.id,
                        legacyPreferredCandidate: refinement.legacyPreferredCandidate,
                        bestCandidateScore: refinement.bestCandidateScore ?? Self.scoreFromConfidence(refinement.confidence),
                        bestCandidateNote: refinement.bestCandidateNote ?? refinement.reason,
                        moveXY: nil,
                        proposalBox: nil,
                        proposalScore: nil,
                        proposalNote: nil,
                        proposalDescription: nil,
                        adjustment: nil,
                        action: nil,
                        stepSize: nil,
                        confidence: refinement.confidence,
                        reason: refinement.reason
                    )
                }

                return HighlightRefinementResult(
                    accepted: false,
                    relocalizeRequested: false,
                    activeCandidateDescription: refinement.activeCandidateDescription,
                    activeCandidateAssessment: refinement.activeCandidateAssessment,
                    bestCandidateID: refinement.bestCandidateID,
                    legacyPreferredCandidate: refinement.legacyPreferredCandidate,
                    bestCandidateScore: refinement.bestCandidateScore ?? Self.scoreFromConfidence(refinement.confidence),
                    bestCandidateNote: refinement.bestCandidateNote ?? refinement.reason,
                    moveXY: nil,
                    proposalBox: nil,
                    proposalScore: refinement.proposalScore,
                    proposalNote: refinement.proposalNote,
                    proposalDescription: refinement.proposalDescription,
                    adjustment: nil,
                    action: action,
                    stepSize: stepSize,
                    confidence: refinement.confidence,
                    reason: refinement.reason
                )

            case .relocalize:
                return HighlightRefinementResult(
                    accepted: false,
                    relocalizeRequested: true,
                    activeCandidateDescription: refinement.activeCandidateDescription,
                    activeCandidateAssessment: refinement.activeCandidateAssessment,
                    bestCandidateID: refinement.bestCandidateID,
                    legacyPreferredCandidate: refinement.legacyPreferredCandidate,
                    bestCandidateScore: refinement.bestCandidateScore ?? Self.scoreFromConfidence(refinement.confidence),
                    bestCandidateNote: refinement.bestCandidateNote ?? refinement.reason,
                    moveXY: nil,
                    proposalBox: nil,
                    proposalScore: nil,
                    proposalNote: nil,
                    proposalDescription: nil,
                    adjustment: nil,
                    action: nil,
                    stepSize: nil,
                    confidence: refinement.confidence,
                    reason: refinement.reason
                )
            }
        } catch {
            print("[OpenHalo] Refinement failed for \(highlight.id) on pass \(pass): \(error.localizedDescription)")
            debugSession?.writeText(
                "error=\(error.localizedDescription)",
                named: String(format: "%02d_refinement_error.txt", pass)
            )
            return HighlightRefinementResult(
                accepted: false,
                relocalizeRequested: false,
                activeCandidateDescription: bestCandidate.candidateDescription,
                activeCandidateAssessment: bestCandidate.evaluationNote,
                bestCandidateID: bestCandidate.id,
                legacyPreferredCandidate: .bestSoFar,
                bestCandidateScore: bestCandidate.qualityScore,
                bestCandidateNote: bestCandidate.evaluationNote,
                moveXY: nil,
                proposalBox: nil,
                proposalScore: nil,
                proposalNote: nil,
                proposalDescription: nil,
                adjustment: nil,
                action: nil,
                stepSize: nil,
                confidence: nil,
                reason: error.localizedDescription
            )
        }
    }

    private func relocalizeHighlight(
        screenshot: CGImage,
        screenshotSize: CGSize,
        query: String,
        highlight: AIAnalysisResponse.HighlightData,
        activeCandidate: EpisodeCandidate,
        bestCandidate: EpisodeCandidate,
        visibleCandidates: [EpisodeCandidate],
        settings: AppSettings,
        pass: Int,
        debugSession: AnalysisDebugSession?
    ) async -> AIAnalysisResponse.HighlightData? {
        let systemPrompt = Self.buildRelocalizationPrompt(
            imageWidth: Int(screenshotSize.width),
            imageHeight: Int(screenshotSize.height)
        )
        let userPrompt = Self.buildRelocalizationUserPrompt(
            query: query,
            highlight: highlight,
            activeCandidate: activeCandidate,
            bestCandidate: bestCandidate,
            visibleCandidates: visibleCandidates
        )
        debugSession?.writeText(
            """
            === SYSTEM PROMPT ===
            \(systemPrompt)

            === USER PROMPT ===
            \(userPrompt)
            """,
            named: String(format: "%02d_relocalize_request.txt", pass)
        )

        do {
            let base64 = try screenshot.toBase64JPEG(quality: settings.compressionQuality)
            let rawResponse = try await client.analyzeScreenshot(
                base64Image: base64,
                userQuery: userPrompt,
                model: settings.selectedModel,
                apiKey: settings.apiKey,
                systemPrompt: systemPrompt,
                reasoning: settings.reasoningConfiguration,
                rawContentHandler: { rawContent in
                    debugSession?.writeText(
                        rawContent,
                        named: String(format: "%02d_relocalize_response_content.txt", pass)
                    )
                }
            )
            debugSession?.writeText(
                Self.describe(rawResponse),
                named: String(format: "%02d_relocalize_response_raw.txt", pass)
            )
            let normalizedResponse = Self.normalizedResponse(
                rawResponse,
                imageSize: screenshotSize,
                debugSession: debugSession
            )
            debugSession?.writeText(
                Self.describe(normalizedResponse),
                named: String(format: "%02d_relocalize_response.txt", pass)
            )

            guard let relocalizedIndex = Self.activeHighlightIndex(
                highlights: normalizedResponse.highlights,
                primaryHighlightId: normalizedResponse.nextAction?.highlightId
            ) else {
                debugSession?.appendLine("Pass \(pass): relocalize returned no active highlight.")
                return nil
            }

            return normalizedResponse.highlights[relocalizedIndex]
        } catch {
            debugSession?.writeText(
                "error=\(error.localizedDescription)",
                named: String(format: "%02d_relocalize_error.txt", pass)
            )
            debugSession?.appendLine("Pass \(pass): relocalize failed - \(error.localizedDescription)")
            return nil
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

    nonisolated static func applyMove(
        to box: AIAnalysisResponse.BoundingBox,
        moveXY: AIHighlightRefinementResponse.MoveXY
    ) -> AIAnalysisResponse.BoundingBox {
        let clampedBox = box.clampedToUnitSpace()
        let clampedMove = clampedMoveXY(moveXY)

        return AIAnalysisResponse.BoundingBox(
            x: clampedBox.x + (clampedMove.x * clampedBox.width),
            y: clampedBox.y + (clampedMove.y * clampedBox.height),
            width: clampedBox.width,
            height: clampedBox.height
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

    nonisolated static func resolveBestCandidateID(
        explicitCandidateID: String?,
        legacyPreferredCandidate: AIHighlightRefinementResponse.PreferredCandidate?,
        proposalCandidateID: String?,
        episodeMemory: EpisodeMemory,
        defaultCandidateID: String
    ) -> String {
        resolveBestCandidateID(
            explicitCandidateID: explicitCandidateID,
            legacyPreferredCandidate: legacyPreferredCandidate,
            proposalCandidateID: proposalCandidateID,
            episodeMemory: episodeMemory,
            defaultCandidateID: defaultCandidateID,
            allowProposalToken: true
        )
    }

    nonisolated static func resolveBestCandidateID(
        explicitCandidateID: String?,
        legacyPreferredCandidate: AIHighlightRefinementResponse.PreferredCandidate?,
        proposalCandidateID: String?,
        episodeMemory: EpisodeMemory,
        defaultCandidateID: String,
        allowProposalToken: Bool = true
    ) -> String {
        if let explicitCandidateID {
            let normalizedID = explicitCandidateID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if allowProposalToken, normalizedID == "proposal", let proposalCandidateID {
                return proposalCandidateID
            }
            if let matchedCandidate = episodeMemory.candidate(matchingLooseID: explicitCandidateID) {
                return matchedCandidate.id
            }
        }

        switch legacyPreferredCandidate {
        case .current:
            if allowProposalToken {
                return proposalCandidateID ?? episodeMemory.activeCandidateID
            }
            return episodeMemory.activeCandidateID
        case .bestSoFar:
            return episodeMemory.bestCandidateID
        case nil:
            return defaultCandidateID
        }
    }

    nonisolated static func renderedCandidates(
        from visibleCandidates: [EpisodeCandidate],
        activeCandidateID: String,
        bestCandidateID: String
    ) -> [RenderedEpisodeCandidate] {
        visibleCandidates.map { candidate in
            let role: RenderedEpisodeCandidate.Role
            if candidate.id == activeCandidateID {
                role = .active
            } else if candidate.id == bestCandidateID {
                role = .best
            } else {
                role = .history
            }
            return RenderedEpisodeCandidate(
                candidateID: candidate.id,
                box: candidate.box,
                qualityScore: candidate.qualityScore,
                role: role
            )
        }
    }

    nonisolated static func scoreFromConfidence(_ confidence: Double?) -> Int? {
        guard let confidence, confidence.isFinite else { return nil }
        return max(0, min(100, Int((confidence * 100).rounded())))
    }

    nonisolated static func sanitizedEvaluationNote(
        _ note: String?,
        fallback: String
    ) -> String {
        let candidateText = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceText = (candidateText?.isEmpty == false ? candidateText : fallback) ?? fallback
        return sanitizeText(
            sourceText,
            maxSentences: 1,
            maxCharacters: 120
        )
    }

    nonisolated static func sanitizedCandidateDescription(
        _ description: String?,
        fallback: String
    ) -> String {
        let candidateText = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceText = (candidateText?.isEmpty == false ? candidateText : fallback) ?? fallback
        return sanitizeText(
            sourceText,
            maxSentences: 1,
            maxCharacters: 90
        )
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

    nonisolated private static func clampedMoveXY(
        _ moveXY: AIHighlightRefinementResponse.MoveXY
    ) -> AIHighlightRefinementResponse.MoveXY {
        AIHighlightRefinementResponse.MoveXY(
            x: clampMoveComponent(moveXY.x),
            y: clampMoveComponent(moveXY.y)
        )
    }

    nonisolated private static func clampMoveComponent(_ value: Double) -> Double {
        guard value.isFinite else { return 0.0 }
        return min(max(value, -4.0), 4.0)
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

    static func buildPlannerPrompt(imageWidth: Int, imageHeight: Int) -> String {
        """
        You are OpenHalo's intent planner for a macOS screen assistant.
        Screenshot size: \(imageWidth)x\(imageHeight).

        Your job is only to determine what the user is trying to accomplish.
        Do not produce guide steps, coordinates, or highlights.
        Use both the user's text and the current screen to reduce ambiguity.

        Output:
        - Return valid JSON only.
        - Follow the provided schema exactly.
        - Status must be either ready or need_clarification.
        - If the user intent is resolved and converged, return ready.
        - If multiple plausible goals remain, return need_clarification.

        When status is ready:
        - resolved_intent must be a single canonical user goal sentence.
        - reason must briefly explain why the goal is clear.

        When status is need_clarification:
        - tentative_intent must be your best current guess.
        - ambiguity_reason must briefly explain what is still unclear.
        - options must contain exactly three mutually exclusive goal options.
        - Phrase options as end-user goals, not implementation steps.

        Rules:
        - Never guess when the intent is not converged.
        - Do not output guide instructions such as click, press, open menu, or use shortcut steps.
        - Do not emit highlights, boxes, coordinates, or UI labels as the answer.
        - Prefer intent statements like "Open Chrome settings" or "Close the current browser tab".
        - Avoid implementation statements like "Click the top-left red button" or "Press Command-comma".
        - Treat the current screenshot as required evidence, not as optional decoration.
        - If the screenshot makes one interpretation clearly dominant, return ready instead of need_clarification.
        - Requests about a visible tab, page, window, button, or icon on the current screenshot should usually resolve to ready when only one reasonable goal fits what is on screen.
        - Use need_clarification only when at least two materially different end goals still remain plausible after using the screenshot.
        - Ignore the OpenHalo assistant window unless the user explicitly asks about OpenHalo itself.
        - Keep reason and ambiguity_reason short and factual.

        Example ready:
        {"status":"ready","resolved_intent":"Open Chrome settings","reason":"The request clearly asks for Chrome's settings page.","confidence":0.93}

        Example need_clarification:
        {"status":"need_clarification","tentative_intent":"Close something in Chrome","ambiguity_reason":"It is unclear whether the user wants to close the tab, the window, or the app.","options":["Close the current Chrome tab","Close the current Chrome window","Quit Chrome completely"],"confidence":0.46}
        """
    }

    static func buildRefinementPrompt() -> String {
        """
        You refine a UI highlight for OpenHalo.

        Inputs:
        - Image 1: full-screen context with candidate boxes and an action reticle centered on the ACTIVE candidate.
        - Image 2: zoomed crop around the ACTIVE candidate with the same action reticle.
        - Image 3: the raw contents of the ACTIVE candidate box, cropped exactly to the current box and enlarged only for visibility.

        Visual markers:
        - Active candidate: solid red box with a badge like #2 84.
        - Best candidate so far: green dashed box with a badge like #1 91.
        - Recent history candidates: yellow dashed boxes with badges.
        - The action reticle uses the ACTIVE candidate center as (0,0).
        - Positive x moves right. Positive y moves down.
        - A move of (1,0) shifts the next box by one current-box width to the right.
        - A move of (0,-1) shifts the next box by one current-box height upward.
        - Ghost boxes show coarse reference positions for integer move coordinates.

        Goal:
        - Choose the most useful FINAL presentation box for a human click, not just the newest box.
        - Evaluate every visible candidate explicitly.
        - If a NEW candidate would be better, choose the next move on the reticle, but treat that moved box as a prediction to verify on the next round.
        - If an older candidate is still better, keep it as best.
        - If the current local region is wrong, request a fresh relocalize instead of forcing a local adjustment.

        Output:
        - Return valid JSON only and follow the provided schema exactly.
        - Always set active_candidate_description as one short phrase describing what is inside the active candidate box.
        - Always set active_candidate_assessment as one short sentence saying why the active candidate is or is not the requested target.
        - Always set best_candidate_id on every response.
        - best_candidate_id must be one of the provided candidate IDs from the current visible episode memory.
        - Always set best_candidate_score as an integer from 0 to 100.
        - Always set best_candidate_note as one short sentence.
        - For accept, choose the best existing candidate and do not propose a new box.
        - For move, return move_xy with numeric x and y.
        - For move, best_candidate_id must still name the best already-visible candidate from this round. Do not name an unseen moved box as best yet.
        - move_xy may use any finite decimal values within the range [-4, 4].
        - High-precision floating-point values are allowed and preserved by the framework.
        - move_xy describes the NEXT box center in current-box units, not pixels and not normalized screen coordinates.
        - For relocalize, do not return a proposal box. Use relocalize only when the target likely sits outside the current local region and a fresh global search is needed.
        - Do not return a freeform target_box unless falling back for legacy compatibility.
        - Never return pixels.
        - Do not output extra prose.

        Rules:
        - Reason from UI semantics and app context, not literal text.
        - Ignore the OpenHalo assistant window and echoed user text unless the user explicitly asks about OpenHalo.
        - Use Image 3 to judge exactly what the ACTIVE candidate box contains.
        - Image 3 preserves the exact box contents even if it has been enlarged for readability.
        - If Image 3 disagrees with older candidate memory, trust Image 3.
        - If Image 3 clearly shows the wrong object, do not accept the active candidate.
        - If several rounds stay inside the same wrong functional area, or the active box has drifted out of the original functional cluster for the requested control, use relocalize instead of making another local adjustment.
        - The user clicks manually, so perfect click-precision is unnecessary.
        - Slightly larger but stable is better than tiny and jittery.
        - Best means: target clearly included, easy for a human to understand, stable, and not excessively large.
        - Width and height stay fixed during move in this version.
        - You, not the framework, decide which candidate is currently best for the final presentation box.
        - candidate descriptions should say what the box contains, not why it is good.
        - active_candidate_assessment should judge the current box against the user request.
        - Keep notes short and factual. Do not reveal hidden chain-of-thought.

        Example accept:
        {"status":"accept","active_candidate_description":"toolbar icon near the close controls","active_candidate_assessment":"The active box is not the close button, but c1 already is.","best_candidate_id":"c1","best_candidate_score":91,"best_candidate_note":"Candidate c1 already cleanly covers the target for a human click.","reason":"Candidate c1 is already the clearest final box.","confidence":0.91}

        Example move:
        {"status":"move","active_candidate_description":"browser tab title","active_candidate_assessment":"The active box is on a tab, not on the new-tab button.","best_candidate_id":"c1","best_candidate_score":84,"best_candidate_note":"Candidate c1 remains the best verified box while the next move is tested.","move_xy":{"x":0.85,"y":-0.10},"reason":"The requested control is slightly to the right of the current box and a touch higher.","confidence":0.78}

        Example relocalize:
        {"status":"relocalize","active_candidate_description":"browser extension icon in the toolbar","active_candidate_assessment":"The active box is in the wrong toolbar region and does not contain the requested target.","best_candidate_id":"c1","best_candidate_score":82,"best_candidate_note":"Candidate c1 is still the best current fallback, but a fresh global search is needed.","reason":"Current visible candidates are all in the wrong functional area; restart from the full screen.","confidence":0.74}
        """
    }

    nonisolated static func buildPlannerUserPrompt(
        query: String,
        context: PlannerConversationContext?
    ) -> String {
        var lines: [String] = [
            "Latest user input: \(query)"
        ]

        if let context {
            lines.append("Original request: \(context.originalQuery)")
            lines.append("Clarification round: \(context.clarificationRound)")
            if let tentativeIntent = context.previousTentativeIntent {
                lines.append("Previous tentative intent: \(tentativeIntent)")
            }
            if let ambiguityReason = context.previousAmbiguityReason {
                lines.append("Previous ambiguity: \(ambiguityReason)")
            }
            if !context.previousOptions.isEmpty {
                lines.append("Previous planner options:")
                for (index, option) in context.previousOptions.enumerated() {
                    lines.append("\(index + 1). \(option)")
                }
                lines.append("4. None of the above; user will describe the goal in their own words.")
            }
        }

        lines.append("Return only the user's intended goal, not guide steps.")
        return lines.joined(separator: "\n")
    }

    nonisolated static func buildRefinementUserPrompt(
        query: String,
        highlight: AIAnalysisResponse.HighlightData,
        activeCandidate: EpisodeCandidate,
        bestCandidate: EpisodeCandidate,
        visibleCandidates: [EpisodeCandidate],
        cropBox: AIAnalysisResponse.BoundingBox,
        activeContentBox: AIAnalysisResponse.BoundingBox,
        cropCandidates: [RenderedEpisodeCandidate],
        iteration: Int
    ) -> String {
        let cropLookup = Dictionary(uniqueKeysWithValues: cropCandidates.map { ($0.candidateID, $0) })
        let candidateSummary = visibleCandidates
            .map { candidate in
                let role: String
                if candidate.id == activeCandidate.id {
                    role = "active"
                } else if candidate.id == bestCandidate.id {
                    role = "best"
                } else {
                    role = "history"
                }
                let cropBoxDescription = cropLookup[candidate.id].map { describe($0.box) } ?? "not_visible"
                return "- \(candidate.id) role=\(role) pass=\(candidate.passIndex) origin=\(candidate.origin) score=\(candidate.qualityScore) screen_box=\(describe(candidate.box)) crop_box=\(cropBoxDescription) description=\"\(candidate.candidateDescription)\" assessment=\"\(candidate.evaluationNote)\""
            }
            .joined(separator: "\n")

        return """
        User request: \(query)
        Hypothesis label: \(highlight.label)
        Element type: \(highlight.elementType ?? "unknown")
        Pass: \(iteration)
        Active candidate: \(activeCandidate.id)
        Best candidate so far: \(bestCandidate.id)
        Crop window on full screen: \(describe(cropBox))
        Exact active-candidate crop on full screen: \(describe(activeContentBox))

        Visible episode memory:
        \(candidateSummary)

        Image guide:
        - Image 1 shows full-screen context with candidate roles and the action reticle.
        - Image 2 shows the local crop around the active candidate with the same action reticle.
        - Image 3 is the raw contents of the active candidate box, cropped exactly to the current box and enlarged only for readability.
        - The reticle origin (0,0) is the current active-box center.
        - Positive x moves right. Positive y moves down.
        - A move of (1,0) means one current-box width to the right.
        - A move of (0,-1) means one current-box height upward.
        - You may use any finite decimal move_xy values within [-4, 4].
        - Integer ghost boxes are only coarse references; you are not limited to integer coordinates.

        Choose the candidate that is currently the best FINAL presentation box for a human click.
        Use each candidate description as memory for what earlier boxes actually contained.
        You may keep any prior candidate as best if it is better than the next predicted move.
        If none of the visible candidates is good enough, return move with move_xy.
        If a visible candidate is already good enough, return accept and name that candidate in best_candidate_id.
        For move, keep best_candidate_id on the best already-visible candidate from this round. The moved box is a new unverified candidate for the next round.
        If Image 3 disagrees with older candidate memory, trust Image 3.
        If the current crop is clearly the wrong functional area, or has drifted out of the original functional cluster for the requested control, return relocalize instead of another local adjustment.
        If you return move, do not return a freeform target_box.
        """
    }

    static func buildRelocalizationPrompt(
        imageWidth: Int,
        imageHeight: Int
    ) -> String {
        """
        You are performing a fresh global UI search for OpenHalo.

        Search the full screenshot again from scratch. Do not stay anchored to the current local region if it appears wrong.

        Output:
        - Return valid JSON only and follow the provided schema exactly.
        - Return exactly one immediate next_action.
        - Use normalized coordinates in the 0..1 range for an image of size \(imageWidth)x\(imageHeight).
        - Return one or more highlights if the target is visible.

        Rules:
        - Previous candidates listed in the user prompt are likely wrong or ambiguous unless clearly marked as best.
        - Use them as negative evidence and search elsewhere when needed.
        - Focus on functional UI semantics, not literal echoed text.
        - Ignore the OpenHalo assistant window unless the user is explicitly asking about OpenHalo.
        - Do not fabricate later steps.
        - Do not invent alternate keys such as element or bbox.
        - next_action must be an object with instruction and highlight_id.

        Example valid response:
        {"message":"I found the requested control.","summary":"The requested control is visible.","next_action":{"instruction":"Click the highlighted control.","highlight_id":"h1"},"highlights":[{"id":"h1","label":"Requested control","bounding_box":{"x":0.42,"y":0.10,"width":0.06,"height":0.03},"element_type":"button"}]}
        """
    }

    nonisolated static func buildRelocalizationUserPrompt(
        query: String,
        highlight: AIAnalysisResponse.HighlightData,
        activeCandidate: EpisodeCandidate,
        bestCandidate: EpisodeCandidate,
        visibleCandidates: [EpisodeCandidate]
    ) -> String {
        let candidateSummary = visibleCandidates
            .map { candidate in
                let role: String
                if candidate.id == activeCandidate.id {
                    role = "active"
                } else if candidate.id == bestCandidate.id {
                    role = "best"
                } else {
                    role = "history"
                }
                return "- \(candidate.id) role=\(role) pass=\(candidate.passIndex) box=\(describe(candidate.box)) description=\"\(candidate.candidateDescription)\" assessment=\"\(candidate.evaluationNote)\""
            }
            .joined(separator: "\n")

        return """
        User request: \(query)
        Current hypothesis label: \(highlight.label)
        Current active candidate: \(activeCandidate.id)
        Current best candidate: \(bestCandidate.id)

        Candidate memory:
        \(candidateSummary)

        Perform a fresh global search across the whole screenshot.
        If the current local region appears wrong or ambiguous, ignore it and find a better region elsewhere on screen.
        Use the candidate descriptions and assessments as negative evidence when they describe the wrong object.
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

    nonisolated static func normalizedPlannerResponse(
        _ response: AIIntentPlannerResponse
    ) -> AIIntentPlannerResponse {
        let resolvedIntent = sanitizeOptionalText(
            response.resolvedIntent,
            maxSentences: 1,
            maxCharacters: 140
        )
        let reason = sanitizeOptionalText(
            response.reason,
            maxSentences: 2,
            maxCharacters: 160
        )
        let tentativeIntent = sanitizeOptionalText(
            response.tentativeIntent,
            maxSentences: 1,
            maxCharacters: 140
        )
        let ambiguityReason = sanitizeOptionalText(
            response.ambiguityReason,
            maxSentences: 2,
            maxCharacters: 180
        )
        var seen = Set<String>()
        let options = response.options
            .map {
                sanitizeText(
                    $0,
                    maxSentences: 1,
                    maxCharacters: 120
                )
            }
            .filter { !$0.isEmpty }
            .filter { option in
                let key = option.lowercased()
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
            .prefix(3)

        return AIIntentPlannerResponse(
            status: response.status,
            resolvedIntent: resolvedIntent,
            reason: reason,
            tentativeIntent: tentativeIntent,
            ambiguityReason: ambiguityReason,
            options: Array(options),
            confidence: min(max(response.confidence, 0.0), 1.0)
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
            "active_candidate_description: \(response.activeCandidateDescription ?? "nil")",
            "active_candidate_assessment: \(response.activeCandidateAssessment ?? "nil")",
            "best_candidate_id: \(response.bestCandidateID ?? "nil")",
            "best_candidate_score: \(response.bestCandidateScore.map(String.init) ?? "nil")",
            "best_candidate_note: \(response.bestCandidateNote ?? "nil")",
            "move_xy: \(response.moveXY.map { "x=\($0.x) y=\($0.y)" } ?? "nil")",
            "proposal_coordinate_space: \(response.proposal?.coordinateSpace?.rawValue ?? response.coordinateSpace?.rawValue ?? "nil")",
            "proposal_target_box: \(response.proposal?.targetBox.map(describe) ?? response.targetBox.map(describe) ?? "nil")",
            "proposal_score: \(response.proposalScore.map(String.init) ?? "nil")",
            "proposal_note: \(response.proposalNote ?? "nil")",
            "proposal_description: \(response.proposalDescription ?? "nil")",
            "legacy_preferred_candidate: \(response.legacyPreferredCandidate?.rawValue ?? "nil")",
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

    nonisolated private static func describe(_ memory: EpisodeMemory) -> String {
        var lines: [String] = [
            "active_candidate_id: \(memory.activeCandidateID)",
            "best_candidate_id: \(memory.bestCandidateID)",
            "candidates:"
        ]

        for candidate in memory.candidates.sorted(by: { $0.numericSortKey < $1.numericSortKey }) {
            lines.append(
                "  \(candidate.id) pass=\(candidate.passIndex) origin=\(candidate.origin) score=\(candidate.qualityScore) box=\(describe(candidate.box)) description=\"\(candidate.candidateDescription)\" assessment=\"\(candidate.evaluationNote)\""
            )
        }

        return lines.joined(separator: "\n")
    }
}

struct AnalysisResult {
    let responseText: String
    let highlights: [HighlightRegion]
    let targetScreen: NSScreen
}

struct PlannerConversationContext {
    let originalQuery: String
    let clarificationRound: Int
    let previousTentativeIntent: String?
    let previousAmbiguityReason: String?
    let previousOptions: [String]
}

private struct HighlightRefinementResult {
    let accepted: Bool
    let relocalizeRequested: Bool
    let activeCandidateDescription: String?
    let activeCandidateAssessment: String?
    let bestCandidateID: String?
    let legacyPreferredCandidate: AIHighlightRefinementResponse.PreferredCandidate?
    let bestCandidateScore: Int?
    let bestCandidateNote: String?
    let moveXY: AIHighlightRefinementResponse.MoveXY?
    let proposalBox: AIAnalysisResponse.BoundingBox?
    let proposalScore: Int?
    let proposalNote: String?
    let proposalDescription: String?
    let adjustment: RelativeBoxAdjustment?
    let action: AIHighlightRefinementResponse.Action?
    let stepSize: AIHighlightRefinementResponse.StepSize?
    let confidence: Double?
    let reason: String?
}

private struct CaptureTarget {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
}

struct EpisodeCandidate: Equatable {
    let id: String
    let box: AIAnalysisResponse.BoundingBox
    let passIndex: Int
    let qualityScore: Int
    let candidateDescription: String
    let evaluationNote: String
    let origin: String

    var numericSortKey: Int {
        Int(id.drop { !$0.isNumber }) ?? passIndex
    }
}

struct EpisodeMemory: Equatable {
    private(set) var candidates: [EpisodeCandidate]
    var activeCandidateID: String
    var bestCandidateID: String

    init(
        seedBox: AIAnalysisResponse.BoundingBox,
        initialScore: Int,
        initialNote: String,
        initialDescription: String,
        origin: String
    ) {
        let seed = EpisodeCandidate(
            id: "c0",
            box: seedBox.clampedToUnitSpace(),
            passIndex: 0,
            qualityScore: initialScore,
            candidateDescription: initialDescription,
            evaluationNote: initialNote,
            origin: origin
        )
        self.candidates = [seed]
        self.activeCandidateID = seed.id
        self.bestCandidateID = seed.id
    }

    var activeCandidate: EpisodeCandidate {
        candidate(withID: activeCandidateID) ?? candidates[0]
    }

    var bestCandidate: EpisodeCandidate {
        candidate(withID: bestCandidateID) ?? candidates[0]
    }

    func candidate(withID id: String) -> EpisodeCandidate? {
        candidates.first(where: { $0.id == id })
    }

    func candidate(matchingLooseID id: String) -> EpisodeCandidate? {
        let normalizedID = id
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return candidates.first {
            $0.id.lowercased() == normalizedID ||
            "#\($0.numericSortKey)" == normalizedID ||
            String($0.numericSortKey) == normalizedID
        }
    }

    func visibleCandidates(maxAdditionalHistoryCandidates: Int) -> [EpisodeCandidate] {
        var visibleIDs = [activeCandidateID]
        if bestCandidateID != activeCandidateID {
            visibleIDs.append(bestCandidateID)
        }

        let recentHistory = candidates
            .filter { candidate in
                candidate.id != activeCandidateID && candidate.id != bestCandidateID
            }
            .sorted(by: { $0.passIndex > $1.passIndex })
            .prefix(maxAdditionalHistoryCandidates)

        for candidate in recentHistory where !visibleIDs.contains(candidate.id) {
            visibleIDs.append(candidate.id)
        }

        return visibleIDs.compactMap { candidateID in
            candidate(withID: candidateID)
        }
    }

    mutating func appendCandidate(
        box: AIAnalysisResponse.BoundingBox,
        passIndex: Int,
        qualityScore: Int,
        evaluationNote: String,
        candidateDescription: String,
        origin: String
    ) -> EpisodeCandidate {
        let candidate = EpisodeCandidate(
            id: "c\(candidates.count)",
            box: box.clampedToUnitSpace(),
            passIndex: passIndex,
            qualityScore: qualityScore,
            candidateDescription: candidateDescription,
            evaluationNote: evaluationNote,
            origin: origin
        )
        candidates.append(candidate)
        return candidate
    }

    mutating func updateCandidateMetadata(
        id: String,
        qualityScore: Int?,
        evaluationNote: String?,
        candidateDescription: String?
    ) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        let existing = candidates[index]
        candidates[index] = EpisodeCandidate(
            id: existing.id,
            box: existing.box,
            passIndex: existing.passIndex,
            qualityScore: qualityScore ?? existing.qualityScore,
            candidateDescription: candidateDescription ?? existing.candidateDescription,
            evaluationNote: evaluationNote ?? existing.evaluationNote,
            origin: existing.origin
        )
    }
}

struct RelativeBoxAdjustment: Equatable {
    let dx: Double
    let dy: Double
    let dw: Double
    let dh: Double
}
