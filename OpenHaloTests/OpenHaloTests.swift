import XCTest
@testable import OpenHalo

final class OpenHaloTests: XCTestCase {
    func testJSONSchemaParserStripsMarkdownFences() throws {
        let input = """
        ```json
        {"summary": "test", "steps": [], "highlights": []}
        ```
        """
        let data = try JSONSchemaParser.extractJSON(from: input)
        let response = try JSONDecoder().decode(AIAnalysisResponse.self, from: data)
        XCTAssertEqual(response.summary, "test")
        XCTAssertTrue(response.steps.isEmpty)
        XCTAssertTrue(response.highlights.isEmpty)
    }

    func testJSONSchemaParserHandlesPlainJSON() throws {
        let input = """
        {"summary": "Found it", "steps": [{"step_number": 1, "instruction": "Click here", "highlight_id": "h1"}], "highlights": [{"id": "h1", "label": "Button", "bounding_box": {"x": 0.5, "y": 0.5, "width": 0.1, "height": 0.05}, "element_type": "button"}]}
        """
        let data = try JSONSchemaParser.extractJSON(from: input)
        let response = try JSONDecoder().decode(AIAnalysisResponse.self, from: data)
        XCTAssertEqual(response.summary, "Found it")
        XCTAssertEqual(response.steps.count, 1)
        XCTAssertEqual(response.nextAction?.instruction, "Click here")
        XCTAssertEqual(response.nextAction?.highlightId, "h1")
        XCTAssertEqual(response.highlights.count, 1)
        XCTAssertEqual(response.highlights.first?.boundingBox.x, 0.5)
    }

    func testAIAnalysisResponseDecodesNextAction() throws {
        let input = """
        {
          "message": "I found the Wi-Fi icon.",
          "summary": "Found the Wi-Fi icon.",
          "next_action": {
            "instruction": "Click the Wi-Fi icon in the menu bar.",
            "highlight_id": "h1"
          },
          "highlights": [
            {
              "id": "h1",
              "label": "Wi-Fi icon",
              "bounding_box": {
                "x": 0.9,
                "y": 0.0,
                "width": 0.02,
                "height": 0.02
              },
              "element_type": "icon"
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(
            AIAnalysisResponse.self,
            from: Data(input.utf8)
        )

        XCTAssertEqual(response.nextAction?.instruction, "Click the Wi-Fi icon in the menu bar.")
        XCTAssertEqual(response.nextAction?.highlightId, "h1")
        XCTAssertTrue(response.steps.isEmpty)
    }

    func testAIAnalysisResponseDecodesSimplifiedFallbackSchema() throws {
        let input = """
        {
          "element": "Chrome 关闭按钮（左上角红色圆点）",
          "bbox": {
            "x": 0.008,
            "y": 0.018,
            "width": 0.018,
            "height": 0.03
          },
          "next_action": "点击左上角红色圆点关闭 Chrome 窗口。"
        }
        """

        let response = try JSONDecoder().decode(
            AIAnalysisResponse.self,
            from: Data(input.utf8)
        )

        XCTAssertEqual(response.summary, "Chrome 关闭按钮（左上角红色圆点）")
        XCTAssertEqual(response.nextAction?.instruction, "点击左上角红色圆点关闭 Chrome 窗口。")
        XCTAssertEqual(response.highlights.count, 1)
        XCTAssertEqual(response.highlights.first?.id, "h1")
        XCTAssertEqual(response.highlights.first?.label, "Chrome 关闭按钮（左上角红色圆点）")
        XCTAssertEqual(response.highlights.first?.boundingBox.x, 0.008)
    }

    func testJSONSchemaParserExtractsJSONObjectFromSurroundingText() throws {
        let input = """
        Here is the result:
        {
          "summary": "Found it",
          "steps": [],
          "highlights": []
        }
        Thanks.
        """

        let data = try JSONSchemaParser.extractJSON(from: input)
        let response = try JSONDecoder().decode(AIAnalysisResponse.self, from: data)

        XCTAssertEqual(response.summary, "Found it")
        XCTAssertTrue(response.steps.isEmpty)
        XCTAssertTrue(response.highlights.isEmpty)
    }

    func testAIAnalysisResponseDecodesStringifiedNumbers() throws {
        let input = """
        {
          "message": "I found it. Click the moon icon.",
          "summary": "Found it",
          "steps": [
            {
              "step_number": "1",
              "instruction": "Click here",
              "highlight_id": "h1"
            }
          ],
          "highlights": [
            {
              "id": "h1",
              "label": "Moon icon",
              "bounding_box": {
                "x": "0.809375",
                "y": "0.006436",
                "width": "0.013542",
                "height": "0.019308"
              },
              "element_type": "icon"
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(
            AIAnalysisResponse.self,
            from: Data(input.utf8)
        )

        XCTAssertEqual(response.message, "I found it. Click the moon icon.")
        XCTAssertEqual(response.steps.first?.stepNumber, 1)
        let box = try XCTUnwrap(response.highlights.first?.boundingBox)
        XCTAssertEqual(box.x, 0.809375, accuracy: 0.000001)
        XCTAssertEqual(box.width, 0.013542, accuracy: 0.000001)
    }

    func testAIAnalysisResponseFallsBackToMessageWhenSummaryMissing() throws {
        let input = """
        {
          "message": "The moon icon is in the menu bar.",
          "steps": [],
          "highlights": []
        }
        """

        let response = try JSONDecoder().decode(
            AIAnalysisResponse.self,
            from: Data(input.utf8)
        )

        XCTAssertEqual(response.message, "The moon icon is in the menu bar.")
        XCTAssertEqual(response.summary, "The moon icon is in the menu bar.")
    }

    func testNormalizedResponseCollapsesRepeatedInstructionPhrases() {
        let repeatedInstruction = """
        点击屏幕左上角菜单栏中的 “Chrome” 选项。建议在弹出的下拉菜单中选择 “设置...” (Settings...)。也可以直接使用快捷键 Command + , (逗号) 打开。建议在弹出的下拉菜单中选择 “设置...” (Settings...)。也可以直接使用快捷键 Command + , (逗号) 打开。
        """

        let response = AIAnalysisResponse(
            message: nil,
            summary: "找到 Chrome 设置入口。",
            steps: [
                AIAnalysisResponse.Step(
                    stepNumber: 1,
                    instruction: repeatedInstruction,
                    highlightId: "h1"
                )
            ],
            highlights: [
                AIAnalysisResponse.HighlightData(
                    id: "h1",
                    label: "Chrome 菜单",
                    boundingBox: .init(x: 0.04, y: 0.0, width: 0.04, height: 0.02),
                    elementType: "menu"
                )
            ]
        )

        let normalized = AIAnalysisPipeline.normalizedResponse(
            response,
            imageSize: CGSize(width: 1920, height: 1243)
        )
        let instruction = normalized.steps.first?.instruction ?? ""

        XCTAssertEqual(normalized.nextAction?.instruction, instruction)
        XCTAssertEqual(
            instruction,
            "点击屏幕左上角菜单栏中的 “Chrome” 选项。 建议在弹出的下拉菜单中选择 “设置...” (Settings...)。 也可以直接使用快捷键 Command + , (逗号) 打开。"
        )
    }

    func testNormalizedResponseKeepsOnlyImmediateNextAction() {
        let response = AIAnalysisResponse(
            message: nil,
            summary: "Open Chrome settings.",
            nextAction: AIAnalysisResponse.NextAction(
                instruction: "Click Chrome in the menu bar.",
                highlightId: "h1"
            ),
            steps: [
                AIAnalysisResponse.Step(stepNumber: 1, instruction: "Click Chrome in the menu bar.", highlightId: "h1"),
                AIAnalysisResponse.Step(stepNumber: 2, instruction: "Then click Settings.", highlightId: "h2")
            ],
            highlights: [
                AIAnalysisResponse.HighlightData(
                    id: "h1",
                    label: "Chrome",
                    boundingBox: .init(x: 0.03, y: 0.0, width: 0.04, height: 0.02),
                    elementType: "menu"
                ),
                AIAnalysisResponse.HighlightData(
                    id: "h2",
                    label: "Settings",
                    boundingBox: .init(x: 0.05, y: 0.05, width: 0.08, height: 0.03),
                    elementType: "menu_item"
                )
            ]
        )

        let normalized = AIAnalysisPipeline.normalizedResponse(
            response,
            imageSize: CGSize(width: 1920, height: 1243)
        )

        XCTAssertEqual(normalized.nextAction?.instruction, "Click Chrome in the menu bar.")
        XCTAssertEqual(normalized.steps.count, 1)
        XCTAssertEqual(normalized.steps.first?.instruction, "Click Chrome in the menu bar.")
        XCTAssertEqual(normalized.steps.first?.highlightId, "h1")
    }

    func testScreenGeometryConversion() {
        let box = AIAnalysisResponse.BoundingBox(x: 0.5, y: 0.25, width: 0.1, height: 0.05)
        let screenSize = CGSize(width: 1920, height: 1080)
        let rect = ScreenGeometry.normalizedToOverlayRect(box: box, screenSize: screenSize)
        XCTAssertEqual(rect.origin.x, 960, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, 270, accuracy: 0.01)
        XCTAssertEqual(rect.width, 192, accuracy: 0.01)
        XCTAssertEqual(rect.height, 54, accuracy: 0.01)
    }

    func testScreenGeometryAppliesMinimumVisibleSize() {
        let box = AIAnalysisResponse.BoundingBox(x: 0.001, y: 0.001, width: 0.001, height: 0.001)
        let screenSize = CGSize(width: 1440, height: 900)
        let rect = ScreenGeometry.normalizedToOverlayRect(box: box, screenSize: screenSize)
        XCTAssertEqual(rect.width, 24, accuracy: 0.01)
        XCTAssertEqual(rect.height, 24, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(rect.origin.x, 0)
        XCTAssertGreaterThanOrEqual(rect.origin.y, 0)
    }

    func testBoundingBoxClampsToUnitSpace() {
        let box = AIAnalysisResponse.BoundingBox(x: -0.2, y: 0.95, width: 1.4, height: 0.2)
        let clamped = box.clampedToUnitSpace()

        XCTAssertEqual(clamped.x, 0.0, accuracy: 0.0001)
        XCTAssertEqual(clamped.y, 0.8, accuracy: 0.0001)
        XCTAssertEqual(clamped.width, 1.0, accuracy: 0.0001)
        XCTAssertEqual(clamped.height, 0.2, accuracy: 0.0001)
    }

    func testBoundingBoxConvertsPixelCoordinatesToNormalizedSpace() {
        let box = AIAnalysisResponse.BoundingBox(x: 126, y: 961, width: 20, height: 20)
        let normalized = box.normalizedForImageSize(
            CGSize(width: 1728, height: 1117)
        )

        XCTAssertEqual(normalized.x, 126.0 / 1728.0, accuracy: 0.0001)
        XCTAssertEqual(normalized.y, 961.0 / 1117.0, accuracy: 0.0001)
        XCTAssertEqual(normalized.width, 20.0 / 1728.0, accuracy: 0.0001)
        XCTAssertEqual(normalized.height, 20.0 / 1117.0, accuracy: 0.0001)
    }

    func testBoundingBoxNormalizesMixedUnitsPerField() {
        let box = AIAnalysisResponse.BoundingBox(x: 0.004, y: 905, width: 0.065, height: 0.035)
        let normalized = box.normalizedForImageSize(
            CGSize(width: 1920, height: 1243)
        )

        XCTAssertEqual(normalized.x, 0.004, accuracy: 0.0001)
        XCTAssertEqual(normalized.y, 905.0 / 1243.0, accuracy: 0.0001)
        XCTAssertEqual(normalized.width, 0.065, accuracy: 0.0001)
        XCTAssertEqual(normalized.height, 0.035, accuracy: 0.0001)
    }

    func testBoundingBoxExpandsToMinimumPixelSizeAroundCenter() {
        let box = AIAnalysisResponse.BoundingBox(x: 0.10, y: 0.20, width: 0.001, height: 0.001)
        let expanded = box.expandedToMinimumPixelSize(
            imageSize: CGSize(width: 1920, height: 1243),
            minimumPixelSize: CGSize(width: 24, height: 24)
        )

        XCTAssertGreaterThanOrEqual(expanded.width, 24.0 / 1920.0)
        XCTAssertGreaterThanOrEqual(expanded.height, 24.0 / 1243.0)
        XCTAssertEqual(expanded.x + (expanded.width / 2), box.x + (box.width / 2), accuracy: 0.001)
        XCTAssertEqual(expanded.y + (expanded.height / 2), box.y + (box.height / 2), accuracy: 0.001)
    }

    func testJSONSchemaParserDecodesRefinementAcceptResponse() throws {
        let input = """
        ```json
        {
          "status": "ACCEPT",
          "preferred_candidate": "best_so_far",
          "reason": "already aligned",
          "confidence": 0.91
        }
        ```
        """

        let data = try JSONSchemaParser.extractJSON(from: input)
        let response = try JSONDecoder().decode(AIHighlightRefinementResponse.self, from: data)

        XCTAssertEqual(response.status, .accept)
        XCTAssertEqual(response.preferredCandidate, .bestSoFar)
        XCTAssertNil(response.action)
        XCTAssertNil(response.stepSize)
        XCTAssertEqual(response.confidence ?? -1, 0.91, accuracy: 0.0001)
    }

    func testJSONSchemaParserDecodesRefinementAdjustResponse() throws {
        let input = """
        ```json
        {
          "status": "ADJUST",
          "preferred_candidate": "current",
          "coordinate_space": "crop",
          "target_box": {
            "x": 0.42,
            "y": 0.31,
            "width": 0.18,
            "height": 0.12
          },
          "reason": "the target is visible in the crop and should be tightened",
          "confidence": 0.88
        }
        ```
        """

        let data = try JSONSchemaParser.extractJSON(from: input)
        let response = try JSONDecoder().decode(AIHighlightRefinementResponse.self, from: data)

        XCTAssertEqual(response.status, .adjust)
        XCTAssertEqual(response.preferredCandidate, .current)
        XCTAssertEqual(response.coordinateSpace, .crop)
        XCTAssertNotNil(response.targetBox)
        XCTAssertEqual(response.targetBox!.x, 0.42, accuracy: 0.0001)
        XCTAssertEqual(response.targetBox!.y, 0.31, accuracy: 0.0001)
        XCTAssertEqual(response.targetBox!.width, 0.18, accuracy: 0.0001)
        XCTAssertEqual(response.targetBox!.height, 0.12, accuracy: 0.0001)
        XCTAssertEqual(response.confidence ?? -1, 0.88, accuracy: 0.0001)
    }

    func testJSONSchemaParserTreatsLegacyActAsAdjustFallback() throws {
        let input = """
        ```json
        {
          "status": "ACT",
          "action": "RIGHT",
          "step": "MEDIUM",
          "reason": "legacy discrete response",
          "confidence": 0.73
        }
        ```
        """

        let data = try JSONSchemaParser.extractJSON(from: input)
        let response = try JSONDecoder().decode(AIHighlightRefinementResponse.self, from: data)

        XCTAssertEqual(response.status, .adjust)
        XCTAssertEqual(response.action, .right)
        XCTAssertEqual(response.stepSize, .medium)
        XCTAssertEqual(response.confidence ?? -1, 0.73, accuracy: 0.0001)
    }

    func testApplyActionMovesBoxRelativeToCurrentSize() {
        let box = AIAnalysisResponse.BoundingBox(x: 0.40, y: 0.30, width: 0.20, height: 0.10)
        let moved = AIAnalysisPipeline.applyAction(
            to: box,
            action: .left,
            stepSize: .small
        )

        XCTAssertEqual(moved.x, 0.35, accuracy: 0.0001)
        XCTAssertEqual(moved.y, 0.30, accuracy: 0.0001)
        XCTAssertEqual(moved.width, 0.20, accuracy: 0.0001)
        XCTAssertEqual(moved.height, 0.10, accuracy: 0.0001)
    }

    func testApplyActionUsesMinimumTravelForTinyBoxes() {
        let box = AIAnalysisResponse.BoundingBox(x: 0.10, y: 0.20, width: 0.005, height: 0.005)
        let moved = AIAnalysisPipeline.applyAction(
            to: box,
            action: .right,
            stepSize: .medium
        )

        XCTAssertEqual(moved.x, 0.16, accuracy: 0.0001)
        XCTAssertEqual(moved.y, 0.20, accuracy: 0.0001)
        XCTAssertEqual(moved.width, 0.005, accuracy: 0.0001)
        XCTAssertEqual(moved.height, 0.005, accuracy: 0.0001)
    }

    func testBuildRefinementUserPromptIncludesHistory() {
        let highlight = AIAnalysisResponse.HighlightData(
            id: "h1",
            label: "Wi-Fi",
            boundingBox: AIAnalysisResponse.BoundingBox(x: 0.8, y: 0.0, width: 0.02, height: 0.02),
            elementType: "icon"
        )
        let history = [
            AIAnalysisResponse.BoundingBox(x: 0.70, y: 0.05, width: 0.02, height: 0.02),
            AIAnalysisResponse.BoundingBox(x: 0.76, y: 0.03, width: 0.02, height: 0.02),
            AIAnalysisResponse.BoundingBox(x: 0.80, y: 0.00, width: 0.02, height: 0.02)
        ]

        let prompt = AIAnalysisPipeline.buildRefinementUserPrompt(
            query: "Find the Wi-Fi icon",
            highlight: highlight,
            currentBox: history.last!,
            bestPresentationBox: history[1],
            historyBoxes: history,
            cropBox: AIAnalysisResponse.BoundingBox(x: 0.68, y: 0.0, width: 0.18, height: 0.12),
            currentBoxInCrop: AIAnalysisResponse.BoundingBox(x: 0.66, y: 0.0, width: 0.11, height: 0.17),
            bestBoxInCrop: AIAnalysisResponse.BoundingBox(x: 0.45, y: 0.22, width: 0.12, height: 0.18),
            iteration: 3
        )

        XCTAssertTrue(prompt.contains("Recent history oldest->newest"))
        XCTAssertTrue(prompt.contains("1. x=0.7000"))
        XCTAssertTrue(prompt.contains("Full-screen current box"))
        XCTAssertTrue(prompt.contains("Full-screen best-so-far box"))
        XCTAssertTrue(prompt.contains("Crop-local current box"))
        XCTAssertTrue(prompt.contains("Crop-local best-so-far box"))
        XCTAssertTrue(prompt.contains("choose which candidate is currently the better FINAL presentation box"))
        XCTAssertTrue(prompt.contains("return accept with the better preferred_candidate"))
    }

    @MainActor
    func testDetectionPromptWarnsAboutAssistantWindowDecoys() {
        let prompt = AIAnalysisPipeline.buildDetectionPrompt(imageWidth: 1376, imageHeight: 1032)

        XCTAssertTrue(prompt.contains("Ignore the OpenHalo assistant window"))
        XCTAssertTrue(prompt.contains("literal text to match"))
        XCTAssertTrue(prompt.contains("control role, iconography, and app context"))
        XCTAssertTrue(prompt.contains("Return exactly one immediate next action"))
        XCTAssertTrue(prompt.contains("Do not fabricate later steps"))
        XCTAssertTrue(prompt.contains("Follow the provided schema exactly"))
        XCTAssertTrue(prompt.contains("Do not invent alternate keys such as element or bbox"))
        XCTAssertTrue(prompt.contains("next_action must be an object"))
        XCTAssertTrue(prompt.contains("Example valid response"))
        XCTAssertTrue(prompt.contains("Example invalid response shape"))
    }

    @MainActor
    func testRefinementPromptWarnsAboutAssistantWindowDecoys() {
        let prompt = AIAnalysisPipeline.buildRefinementPrompt()

        XCTAssertTrue(prompt.contains("Ignore the OpenHalo assistant window"))
        XCTAssertTrue(prompt.contains("Reason from UI semantics and app context"))
        XCTAssertTrue(prompt.contains("Best-so-far presentation candidate"))
        XCTAssertTrue(prompt.contains("perfect click-precision is unnecessary"))
        XCTAssertTrue(prompt.contains("Slightly larger but stable is better than tiny and jittery"))
        XCTAssertTrue(prompt.contains("preferred_candidate"))
        XCTAssertTrue(prompt.contains("follow the provided schema exactly"))
        XCTAssertTrue(prompt.contains("Always set preferred_candidate to current or best_so_far on every response"))
        XCTAssertTrue(prompt.contains("You, not the framework, decide which candidate is currently best"))
        XCTAssertTrue(prompt.contains("Example accept"))
        XCTAssertTrue(prompt.contains("Example adjust"))
        XCTAssertTrue(prompt.contains("Do not repeat explanations or output extra prose"))
    }

    func testResolveModelPreferredCandidateHonorsBestSoFarSelection() {
        let current = PresentationCandidate(
            box: AIAnalysisResponse.BoundingBox(x: 0.0022, y: 0.0203, width: 0.0109, height: 0.0237),
            confidence: 0.91,
            source: "accept_pass_3"
        )
        let best = PresentationCandidate(
            box: AIAnalysisResponse.BoundingBox(x: 0.005, y: 0.048, width: 0.010, height: 0.015),
            confidence: 0.62,
            source: "initial_detection"
        )

        let selected = AIAnalysisPipeline.resolveModelPreferredCandidate(
            preferredCandidate: .bestSoFar,
            current: current,
            bestSoFar: best
        )

        XCTAssertEqual(selected, best)
    }

    func testResolveModelPreferredCandidateDefaultsToCurrentWithoutModelSelection() {
        let current = PresentationCandidate(
            box: AIAnalysisResponse.BoundingBox(x: 0.0022, y: 0.0203, width: 0.0109, height: 0.0237),
            confidence: 0.93,
            source: "pass_2"
        )
        let best = PresentationCandidate(
            box: AIAnalysisResponse.BoundingBox(x: 0.0208, y: 0.0439, width: 0.0131, height: 0.0220),
            confidence: 0.94,
            source: "pass_1"
        )

        let selected = AIAnalysisPipeline.resolveModelPreferredCandidate(
            preferredCandidate: nil,
            current: current,
            bestSoFar: best
        )

        XCTAssertEqual(selected, current)
    }

    func testMapCropBoxToImageMapsLocalCoordinatesBackToGlobal() {
        let cropBox = AIAnalysisResponse.BoundingBox(x: 0.25, y: 0.40, width: 0.10, height: 0.20)
        let localBox = AIAnalysisResponse.BoundingBox(x: 0.50, y: 0.25, width: 0.20, height: 0.30)
        let mapped = AIAnalysisPipeline.mapCropBoxToImage(
            localBox,
            cropBoxInImage: cropBox
        )

        XCTAssertEqual(mapped.x, 0.30, accuracy: 0.0001)
        XCTAssertEqual(mapped.y, 0.45, accuracy: 0.0001)
        XCTAssertEqual(mapped.width, 0.02, accuracy: 0.0001)
        XCTAssertEqual(mapped.height, 0.06, accuracy: 0.0001)
    }

    func testOscillationMergeBoxCombinesNeighboringBoxesIntoStableRegion() {
        let history = [
            AIAnalysisResponse.BoundingBox(x: 0.7656, y: 0.0056, width: 0.0125, height: 0.0193),
            AIAnalysisResponse.BoundingBox(x: 0.7812, y: 0.0056, width: 0.0125, height: 0.0193),
            AIAnalysisResponse.BoundingBox(x: 0.7654, y: 0.0056, width: 0.0125, height: 0.0193),
        ]

        let merged = AIAnalysisPipeline.oscillationMergeBox(
            from: history,
            imageSize: CGSize(width: 1920, height: 1243),
            marginPixels: CGSize(width: 8, height: 6),
            maximumPixelSize: CGSize(width: 96, height: 72)
        )

        XCTAssertNotNil(merged)
        XCTAssertLessThanOrEqual(merged!.width * 1920.0, 96.0)
        XCTAssertLessThanOrEqual(merged!.height * 1243.0, 72.0)
        XCTAssertLessThanOrEqual(merged!.x, 0.7654)
        XCTAssertGreaterThanOrEqual(merged!.x + merged!.width, 0.7937)
    }

    func testStableClusterMergeBoxCombinesTinyNearbyRefinements() {
        let history = [
            AIAnalysisResponse.BoundingBox(x: 0.0022, y: 0.0203, width: 0.0153, height: 0.0405),
            AIAnalysisResponse.BoundingBox(x: 0.0175, y: 0.0243, width: 0.0175, height: 0.0487),
            AIAnalysisResponse.BoundingBox(x: 0.0044, y: 0.0243, width: 0.0131, height: 0.0487),
        ]

        let merged = AIAnalysisPipeline.stableClusterMergeBox(
            from: history,
            imageSize: CGSize(width: 1512, height: 982),
            recentCount: 3,
            marginPixels: CGSize(width: 8, height: 6),
            maximumPixelSize: CGSize(width: 88, height: 72),
            maximumAverageBoxSize: CGSize(width: 48, height: 64),
            maximumCenterSpreadPixels: CGSize(width: 36, height: 32)
        )

        XCTAssertNotNil(merged)
        XCTAssertLessThanOrEqual(merged!.width * 1512.0, 88.0)
        XCTAssertLessThanOrEqual(merged!.height * 982.0, 72.0)
        XCTAssertLessThanOrEqual(merged!.x, 0.0022)
        XCTAssertGreaterThanOrEqual(merged!.x + merged!.width, 0.0350)
    }

    func testApplyActionScalesBoxAroundCenter() {
        let box = AIAnalysisResponse.BoundingBox(x: 0.40, y: 0.30, width: 0.20, height: 0.10)
        let grown = AIAnalysisPipeline.applyAction(
            to: box,
            action: .grow,
            stepSize: .medium
        )

        XCTAssertEqual(grown.x, 0.38, accuracy: 0.0001)
        XCTAssertEqual(grown.y, 0.29, accuracy: 0.0001)
        XCTAssertEqual(grown.width, 0.24, accuracy: 0.0001)
        XCTAssertEqual(grown.height, 0.12, accuracy: 0.0001)
    }

    func testApplyAdjustmentMovesAndResizesFreely() {
        let box = AIAnalysisResponse.BoundingBox(x: 0.40, y: 0.30, width: 0.20, height: 0.10)
        let adjusted = AIAnalysisPipeline.applyAdjustment(
            to: box,
            adjustment: RelativeBoxAdjustment(dx: 1.5, dy: -0.5, dw: 0.25, dh: -0.20)
        )

        XCTAssertEqual(adjusted.x, 0.675, accuracy: 0.0001)
        XCTAssertEqual(adjusted.y, 0.26, accuracy: 0.0001)
        XCTAssertEqual(adjusted.width, 0.25, accuracy: 0.0001)
        XCTAssertEqual(adjusted.height, 0.08, accuracy: 0.0001)
    }

    func testApplyActionClampsToUnitSpace() {
        let box = AIAnalysisResponse.BoundingBox(x: 0.02, y: 0.03, width: 0.30, height: 0.20)
        let moved = AIAnalysisPipeline.applyAction(
            to: box,
            action: .left,
            stepSize: .large
        )

        XCTAssertEqual(moved.x, 0.0, accuracy: 0.0001)
        XCTAssertEqual(moved.y, 0.03, accuracy: 0.0001)
        XCTAssertEqual(moved.width, 0.30, accuracy: 0.0001)
        XCTAssertEqual(moved.height, 0.20, accuracy: 0.0001)
    }

    func testIsOppositeDetectsOscillationPairs() {
        XCTAssertTrue(AIAnalysisPipeline.isOpposite(.left, .right))
        XCTAssertTrue(AIAnalysisPipeline.isOpposite(.grow, .shrink))
        XCTAssertFalse(AIAnalysisPipeline.isOpposite(.left, .left))
        XCTAssertFalse(AIAnalysisPipeline.isOpposite(.up, .grow))
    }

    func testAppSettingsDecodesLegacyPayloadAndUpgradesDefaultModel() throws {
        let data = """
        {
          "apiKey": "test-key",
          "selectedModel": "google/gemini-2.5-flash-lite",
          "compressionQuality": 0.8
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.apiKey, "test-key")
        XCTAssertEqual(settings.selectedModel, AppSettings.defaultModel)
        XCTAssertEqual(settings.compressionQuality, 0.8, accuracy: 0.0001)
        XCTAssertEqual(settings.reasoningEnabled, AppSettings.defaultReasoningEnabled)
        XCTAssertEqual(settings.reasoningEffort, AppSettings.defaultReasoningEffort)
    }

    func testAppSettingsUpgradesPreviousThinkingDefaultsToLowLatencyDefaults() throws {
        let data = """
        {
          "apiKey": "test-key",
          "selectedModel": "openai/o4-mini",
          "compressionQuality": 0.7,
          "reasoningEnabled": true,
          "reasoningEffort": "high"
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.selectedModel, AppSettings.defaultModel)
        XCTAssertEqual(settings.reasoningEnabled, AppSettings.defaultReasoningEnabled)
        XCTAssertEqual(settings.reasoningEffort, AppSettings.defaultReasoningEffort)
    }

    func testAppSettingsUpgradesPreviousStandardDefaultToCurrentDefaultModel() throws {
        let data = """
        {
          "apiKey": "test-key",
          "selectedModel": "openai/gpt-4o-mini",
          "compressionQuality": 0.7
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.selectedModel, AppSettings.defaultModel)
        XCTAssertEqual(settings.reasoningEnabled, AppSettings.defaultReasoningEnabled)
        XCTAssertEqual(settings.reasoningEffort, AppSettings.defaultReasoningEffort)
    }

    func testAppSettingsDefaultsToLowLatencyProfile() {
        let settings = AppSettings()

        XCTAssertEqual(settings.selectedModel, AppSettings.defaultModel)
        XCTAssertEqual(settings.reasoningEnabled, AppSettings.defaultReasoningEnabled)
        XCTAssertEqual(settings.reasoningEffort, AppSettings.defaultReasoningEffort)
    }

    func testOpenRouterRequestEncodesReasoningConfiguration() throws {
        let request = OpenRouterRequest(
            model: "openai/o4-mini",
            messages: [
                .system(content: "system"),
                .user(content: [.text("hello")]),
            ],
            temperature: 0.1,
            maxTokens: 256,
            responseFormat: .jsonSchema(
                name: "test_schema",
                schema: .object(
                    properties: [
                        "message": .string()
                    ],
                    required: ["message"]
                )
            ),
            reasoning: ReasoningConfiguration(
                enabled: true,
                effort: "high",
                exclude: true
            ),
            plugins: [.responseHealing]
        )

        let data = try JSONEncoder().encode(request)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let reasoning = try XCTUnwrap(payload["reasoning"] as? [String: Any])
        let responseFormat = try XCTUnwrap(payload["response_format"] as? [String: Any])
        let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        let plugins = try XCTUnwrap(payload["plugins"] as? [[String: Any]])

        XCTAssertEqual(payload["model"] as? String, "openai/o4-mini")
        XCTAssertEqual(reasoning["enabled"] as? Bool, true)
        XCTAssertEqual(reasoning["effort"] as? String, "high")
        XCTAssertEqual(reasoning["exclude"] as? Bool, true)
        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        XCTAssertEqual(jsonSchema["name"] as? String, "test_schema")
        XCTAssertEqual(jsonSchema["strict"] as? Bool, true)
        XCTAssertEqual(plugins.first?["id"] as? String, "response-healing")
    }

    func testOpenRouterAPIResponseDecodesContentBlockArrays() throws {
        let data = """
        {
          "id": "resp_123",
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": [
                  { "type": "text", "text": "{\\"summary\\":\\"ok\\",\\"steps\\":[],\\"highlights\\":[]}" }
                ]
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OpenRouterAPIResponse.self, from: data)

        XCTAssertEqual(response.choices.first?.message.role, "assistant")
        XCTAssertEqual(
            response.choices.first?.message.content,
            "{\"summary\":\"ok\",\"steps\":[],\"highlights\":[]}"
        )
    }

    func testOpenRouterAPIResponseDecodesObjectContentAsJSONString() throws {
        let data = """
        {
          "id": "resp_456",
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": {
                  "message": "I found it.",
                  "summary": "Found it",
                  "steps": [],
                  "highlights": []
                }
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OpenRouterAPIResponse.self, from: data)
        let content = try XCTUnwrap(response.choices.first?.message.content)

        XCTAssertTrue(content.contains("\"message\":\"I found it.\""))
        XCTAssertTrue(content.contains("\"summary\":\"Found it\""))
    }

    func testAppSettingsSkipsReasoningForNonReasoningModel() {
        var settings = AppSettings()
        settings.selectedModel = "openai/gpt-4o"
        settings.reasoningEnabled = true
        settings.reasoningEffort = "xhigh"

        XCTAssertNil(settings.reasoningConfiguration)
    }

    func testAvailableModelOptionsIncludeOpenAIAndGeminiFamilies() {
        XCTAssertEqual(AppSettings.defaultModel, "openai/gpt-5.3-chat")
        XCTAssertTrue(AppSettings.availableModels.contains("openai/o4-mini"))
        XCTAssertTrue(AppSettings.availableModels.contains("openai/gpt-5.3-chat"))
        XCTAssertTrue(AppSettings.availableModels.contains("openai/gpt-5"))
        XCTAssertTrue(AppSettings.availableModels.contains("google/gemini-2.5-flash"))
        XCTAssertTrue(AppSettings.availableModels.contains("google/gemini-2.5-pro"))
        XCTAssertTrue(AppSettings.availableModels.contains("google/gemini-3-flash-preview"))
        XCTAssertFalse(AppSettings.availableModels.contains("google/gemini-3-pro-preview"))
    }

    func testOpenRouterErrorFormatsProviderRestrictionHelpfully() {
        let error = OpenRouterError.apiError(
            statusCode: 404,
            body: #"{"error":{"message":"No allowed providers are available for the selected model.","code":404,"metadata":{"available_providers":["google-vertex"],"requested_providers":["xai","venice","cerebras","anthropic","google-ai-studio"]}}}"#
        )

        let description = error.errorDescription ?? ""

        XCTAssertTrue(description.contains("not available with your current OpenRouter provider restrictions"))
        XCTAssertTrue(description.contains("google-vertex"))
        XCTAssertTrue(description.contains("google-ai-studio"))
        XCTAssertTrue(description.contains("GPT-4o Mini"))
    }
}
