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
          "active_candidate_description": "toolbar icon near the close controls",
          "active_candidate_assessment": "The active box is not the close button, but c1 already is.",
          "best_candidate_id": "c1",
          "best_candidate_score": 91,
          "best_candidate_note": "Candidate c1 already cleanly covers the target.",
          "reason": "already aligned",
          "confidence": 0.91
        }
        ```
        """

        let data = try JSONSchemaParser.extractJSON(from: input)
        let response = try JSONDecoder().decode(AIHighlightRefinementResponse.self, from: data)

        XCTAssertEqual(response.status, .accept)
        XCTAssertEqual(response.activeCandidateDescription, "toolbar icon near the close controls")
        XCTAssertEqual(response.activeCandidateAssessment, "The active box is not the close button, but c1 already is.")
        XCTAssertEqual(response.bestCandidateID, "c1")
        XCTAssertEqual(response.bestCandidateScore, 91)
        XCTAssertEqual(response.bestCandidateNote, "Candidate c1 already cleanly covers the target.")
        XCTAssertNil(response.action)
        XCTAssertNil(response.stepSize)
        XCTAssertEqual(response.confidence ?? -1, 0.91, accuracy: 0.0001)
    }

    func testJSONSchemaParserDecodesRefinementMoveResponse() throws {
        let input = """
        ```json
        {
          "status": "MOVE",
          "active_candidate_description": "browser tab title",
          "active_candidate_assessment": "The active box is on a tab, not on the new-tab button.",
          "best_candidate_id": "proposal",
          "best_candidate_score": 84,
          "best_candidate_note": "Moving right by one box-width lands on the target control.",
          "move_xy": {
            "x": 1.0,
            "y": -0.5
          },
          "reason": "The requested control is immediately to the right of the current box.",
          "confidence": 0.88
        }
        ```
        """

        let data = try JSONSchemaParser.extractJSON(from: input)
        let response = try JSONDecoder().decode(AIHighlightRefinementResponse.self, from: data)

        XCTAssertEqual(response.status, .move)
        XCTAssertEqual(response.activeCandidateDescription, "browser tab title")
        XCTAssertEqual(response.activeCandidateAssessment, "The active box is on a tab, not on the new-tab button.")
        XCTAssertEqual(response.bestCandidateID, "proposal")
        XCTAssertEqual(response.bestCandidateScore, 84)
        XCTAssertEqual(response.moveXY?.x ?? -999, 1.0, accuracy: 0.0001)
        XCTAssertEqual(response.moveXY?.y ?? -999, -0.5, accuracy: 0.0001)
        XCTAssertEqual(response.confidence ?? -1, 0.88, accuracy: 0.0001)
    }

    func testJSONSchemaParserDecodesMalformedLegacyRefinementAdjustWithoutThrowing() throws {
        let input = """
        {
          "status": "adjust",
          "active_candidate_description": "Chrome toolbar back navigation arrow",
          "active_candidate_assessment": "The active box highlights the back button, not the Chrome window close control.",
          "best_candidate_id": "proposal",
          "best_candidate_score": 80,
          "best_candidate_note": "Moving left to the macOS window control area will capture the Chrome close button.",
          "proposal": {
            "coordinate_space": "crop",
            "target_box": {
              "x": 0.02,
              "y": null
            }
          },
          "reason": "needs adjustment",
          "confidence": 0.8
        }
        """

        let response = try JSONDecoder().decode(
            AIHighlightRefinementResponse.self,
            from: Data(input.utf8)
        )

        XCTAssertEqual(response.status, .move)
        XCTAssertEqual(response.bestCandidateID, "proposal")
        XCTAssertEqual(response.coordinateSpace, .crop)
        XCTAssertNil(response.targetBox)
    }

    func testJSONSchemaParserDecodesRefinementRelocalizeResponse() throws {
        let input = """
        {
          "status": "relocalize",
          "active_candidate_description": "browser extension icon in the toolbar",
          "active_candidate_assessment": "The active box is in the wrong functional region.",
          "best_candidate_id": "c1",
          "best_candidate_score": 82,
          "best_candidate_note": "Candidate c1 remains the best fallback while we restart the search.",
          "reason": "Visible candidates are all in the wrong toolbar region.",
          "confidence": 0.74
        }
        """

        let response = try JSONDecoder().decode(
            AIHighlightRefinementResponse.self,
            from: Data(input.utf8)
        )

        XCTAssertEqual(response.status, .relocalize)
        XCTAssertEqual(response.bestCandidateID, "c1")
        XCTAssertEqual(response.bestCandidateScore, 82)
        XCTAssertNil(response.targetBox)
    }

    func testJSONSchemaParserTreatsLegacyActAsMoveFallback() throws {
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

        XCTAssertEqual(response.status, .move)
        XCTAssertEqual(response.action, .right)
        XCTAssertEqual(response.stepSize, .medium)
        XCTAssertEqual(response.confidence ?? -1, 0.73, accuracy: 0.0001)
    }

    func testApplyMoveKeepsSizeAndMovesByCurrentBoxUnits() {
        let box = AIAnalysisResponse.BoundingBox(x: 0.40, y: 0.30, width: 0.20, height: 0.10)
        let moved = AIAnalysisPipeline.applyMove(
            to: box,
            moveXY: .init(x: 1.0, y: -1.0)
        )

        XCTAssertEqual(moved.x, 0.60, accuracy: 0.0001)
        XCTAssertEqual(moved.y, 0.20, accuracy: 0.0001)
        XCTAssertEqual(moved.width, 0.20, accuracy: 0.0001)
        XCTAssertEqual(moved.height, 0.10, accuracy: 0.0001)
    }

    func testApplyMovePreservesFloatPrecisionWithinRange() {
        let box = AIAnalysisResponse.BoundingBox(x: 0.40, y: 0.30, width: 0.20, height: 0.10)
        let moved = AIAnalysisPipeline.applyMove(
            to: box,
            moveXY: .init(x: 1.26, y: -4.9)
        )

        XCTAssertEqual(moved.x, 0.652, accuracy: 0.0001)
        XCTAssertEqual(moved.y, 0.0, accuracy: 0.0001)
        XCTAssertEqual(moved.width, 0.20, accuracy: 0.0001)
        XCTAssertEqual(moved.height, 0.10, accuracy: 0.0001)
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
        let c0 = EpisodeCandidate(
            id: "c0",
            box: AIAnalysisResponse.BoundingBox(x: 0.70, y: 0.05, width: 0.02, height: 0.02),
            passIndex: 0,
            qualityScore: 62,
            candidateDescription: "Initial guess near the Wi-Fi icon.",
            evaluationNote: "Initial guess is near the target.",
            origin: "initial_detection"
        )
        let c1 = EpisodeCandidate(
            id: "c1",
            box: AIAnalysisResponse.BoundingBox(x: 0.76, y: 0.03, width: 0.02, height: 0.02),
            passIndex: 1,
            qualityScore: 84,
            candidateDescription: "Likely the true Wi-Fi icon.",
            evaluationNote: "Closer to the true Wi-Fi icon.",
            origin: "refinement_pass_1"
        )
        let c2 = EpisodeCandidate(
            id: "c2",
            box: AIAnalysisResponse.BoundingBox(x: 0.80, y: 0.00, width: 0.02, height: 0.02),
            passIndex: 2,
            qualityScore: 79,
            candidateDescription: "Status icon slightly right of Wi-Fi.",
            evaluationNote: "Slightly too far right.",
            origin: "refinement_pass_2"
        )
        let cropCandidates = [
            RenderedEpisodeCandidate(
                candidateID: "c0",
                box: AIAnalysisResponse.BoundingBox(x: 0.10, y: 0.20, width: 0.10, height: 0.15),
                qualityScore: 62,
                role: .history
            ),
            RenderedEpisodeCandidate(
                candidateID: "c1",
                box: AIAnalysisResponse.BoundingBox(x: 0.45, y: 0.22, width: 0.12, height: 0.18),
                qualityScore: 84,
                role: .best
            ),
            RenderedEpisodeCandidate(
                candidateID: "c2",
                box: AIAnalysisResponse.BoundingBox(x: 0.66, y: 0.0, width: 0.11, height: 0.17),
                qualityScore: 79,
                role: .active
            )
        ]

        let prompt = AIAnalysisPipeline.buildRefinementUserPrompt(
            query: "Find the Wi-Fi icon",
            highlight: highlight,
            activeCandidate: c2,
            bestCandidate: c1,
            visibleCandidates: [c0, c1, c2],
            cropBox: AIAnalysisResponse.BoundingBox(x: 0.68, y: 0.0, width: 0.18, height: 0.12),
            activeContentBox: AIAnalysisResponse.BoundingBox(x: 0.66, y: 0.0, width: 0.11, height: 0.17),
            cropCandidates: cropCandidates,
            iteration: 3
        )

        XCTAssertTrue(prompt.contains("Active candidate: c2"))
        XCTAssertTrue(prompt.contains("Best candidate so far: c1"))
        XCTAssertTrue(prompt.contains("Visible episode memory"))
        XCTAssertTrue(prompt.contains("Image guide"))
        XCTAssertTrue(prompt.contains("Image 3 is the raw contents of the active candidate box"))
        XCTAssertTrue(prompt.contains("enlarged only for readability"))
        XCTAssertTrue(prompt.contains("Exact active-candidate crop on full screen"))
        XCTAssertTrue(prompt.contains("c0 role=history"))
        XCTAssertTrue(prompt.contains("c1 role=best"))
        XCTAssertTrue(prompt.contains("c2 role=active"))
        XCTAssertTrue(prompt.contains("score=84"))
        XCTAssertTrue(prompt.contains("description=\"Likely the true Wi-Fi icon.\""))
        XCTAssertTrue(prompt.contains("assessment=\"Closer to the true Wi-Fi icon.\""))
        XCTAssertTrue(prompt.contains("crop_box=x=0.4500"))
        XCTAssertTrue(prompt.contains("best FINAL presentation box"))
        XCTAssertTrue(prompt.contains("best_candidate_id"))
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
        XCTAssertTrue(prompt.contains("Image 3"))
        XCTAssertTrue(prompt.contains("raw contents of the ACTIVE candidate box, cropped exactly to the current box and enlarged only for visibility"))
        XCTAssertTrue(prompt.contains("Use Image 3 to judge exactly what the ACTIVE candidate box contains"))
        XCTAssertTrue(prompt.contains("preserves the exact box contents even if it has been enlarged for readability"))
        XCTAssertTrue(prompt.contains("Best candidate so far"))
        XCTAssertTrue(prompt.contains("perfect click-precision is unnecessary"))
        XCTAssertTrue(prompt.contains("Slightly larger but stable is better than tiny and jittery"))
        XCTAssertTrue(prompt.contains("best_candidate_id"))
        XCTAssertTrue(prompt.contains("active_candidate_description"))
        XCTAssertTrue(prompt.contains("active_candidate_assessment"))
        XCTAssertTrue(prompt.contains("follow the provided schema exactly"))
        XCTAssertTrue(prompt.contains("Always set best_candidate_id on every response"))
        XCTAssertTrue(prompt.contains("move_xy"))
        XCTAssertTrue(prompt.contains("move_xy may use any finite decimal values within the range [-4, 4]"))
        XCTAssertTrue(prompt.contains("High-precision floating-point values are allowed"))
        XCTAssertTrue(prompt.contains("Ghost boxes show coarse reference positions"))
        XCTAssertTrue(prompt.contains("Do not return a freeform target_box unless falling back for legacy compatibility"))
        XCTAssertTrue(prompt.contains("For move, best_candidate_id must still name the best already-visible candidate from this round"))
        XCTAssertTrue(prompt.contains("If Image 3 disagrees with older candidate memory, trust Image 3"))
        XCTAssertTrue(prompt.contains("You, not the framework, decide which candidate is currently best"))
        XCTAssertTrue(prompt.contains("Example accept"))
        XCTAssertTrue(prompt.contains("Example move"))
        XCTAssertTrue(prompt.contains("Example relocalize"))
        XCTAssertTrue(prompt.contains("Do not output extra prose"))
    }

    @MainActor
    func testRelocalizationPromptAndUserPromptDescribeFreshGlobalSearch() {
        let systemPrompt = AIAnalysisPipeline.buildRelocalizationPrompt(
            imageWidth: 1920,
            imageHeight: 1243
        )
        XCTAssertTrue(systemPrompt.contains("fresh global UI search"))
        XCTAssertTrue(systemPrompt.contains("Search the full screenshot again from scratch"))
        XCTAssertTrue(systemPrompt.contains("Use normalized coordinates in the 0..1 range"))

        let active = EpisodeCandidate(
            id: "c2",
            box: .init(x: 0.77, y: 0.06, width: 0.02, height: 0.03),
            passIndex: 2,
            qualityScore: 78,
            candidateDescription: "browser extension icon",
            evaluationNote: "Wrong toolbar control.",
            origin: "refinement_pass_2"
        )
        let best = EpisodeCandidate(
            id: "c1",
            box: .init(x: 0.74, y: 0.06, width: 0.02, height: 0.03),
            passIndex: 1,
            qualityScore: 82,
            candidateDescription: "ambiguous toolbar icon",
            evaluationNote: "Still not the requested target.",
            origin: "refinement_pass_1"
        )
        let prompt = AIAnalysisPipeline.buildRelocalizationUserPrompt(
            query: "find where to open a new chrome tab",
            highlight: .init(
                id: "h1",
                label: "New tab (+) button",
                boundingBox: .init(x: 0.77, y: 0.06, width: 0.02, height: 0.03),
                elementType: "button"
            ),
            activeCandidate: active,
            bestCandidate: best,
            visibleCandidates: [best, active]
        )

        XCTAssertTrue(prompt.contains("Perform a fresh global search across the whole screenshot"))
        XCTAssertTrue(prompt.contains("Current active candidate: c2"))
        XCTAssertTrue(prompt.contains("Current best candidate: c1"))
        XCTAssertTrue(prompt.contains("description=\"browser extension icon\""))
        XCTAssertTrue(prompt.contains("Use the candidate descriptions and assessments as negative evidence"))
    }

    func testResolveBestCandidateIDAcceptsExistingCandidateID() {
        let memory = EpisodeMemory(
            seedBox: AIAnalysisResponse.BoundingBox(x: 0.005, y: 0.048, width: 0.010, height: 0.015),
            initialScore: 62,
            initialNote: "Initial",
            initialDescription: "Initial candidate",
            origin: "initial_detection"
        )

        let selected = AIAnalysisPipeline.resolveBestCandidateID(
            explicitCandidateID: "c0",
            legacyPreferredCandidate: nil,
            proposalCandidateID: nil,
            episodeMemory: memory,
            defaultCandidateID: memory.activeCandidateID
        )

        XCTAssertEqual(selected, "c0")
    }

    func testResolveBestCandidateIDUsesProposalToken() {
        var memory = EpisodeMemory(
            seedBox: AIAnalysisResponse.BoundingBox(x: 0.005, y: 0.048, width: 0.010, height: 0.015),
            initialScore: 62,
            initialNote: "Initial",
            initialDescription: "Initial candidate",
            origin: "initial_detection"
        )
        let proposal = memory.appendCandidate(
            box: AIAnalysisResponse.BoundingBox(x: 0.0022, y: 0.0203, width: 0.0109, height: 0.0237),
            passIndex: 1,
            qualityScore: 91,
            evaluationNote: "Proposal",
            candidateDescription: "Improved candidate",
            origin: "refinement_pass_1"
        )

        let selected = AIAnalysisPipeline.resolveBestCandidateID(
            explicitCandidateID: "proposal",
            legacyPreferredCandidate: nil,
            proposalCandidateID: proposal.id,
            episodeMemory: memory,
            defaultCandidateID: memory.activeCandidateID,
            allowProposalToken: true
        )

        XCTAssertEqual(selected, proposal.id)
    }

    func testResolveBestCandidateIDIgnoresProposalTokenWhenProposalIsUnverified() {
        var memory = EpisodeMemory(
            seedBox: AIAnalysisResponse.BoundingBox(x: 0.005, y: 0.048, width: 0.010, height: 0.015),
            initialScore: 62,
            initialNote: "Initial",
            initialDescription: "Initial candidate",
            origin: "initial_detection"
        )
        let proposal = memory.appendCandidate(
            box: AIAnalysisResponse.BoundingBox(x: 0.0022, y: 0.0203, width: 0.0109, height: 0.0237),
            passIndex: 1,
            qualityScore: 91,
            evaluationNote: "Proposal",
            candidateDescription: "Improved candidate",
            origin: "refinement_pass_1"
        )

        let selected = AIAnalysisPipeline.resolveBestCandidateID(
            explicitCandidateID: "proposal",
            legacyPreferredCandidate: nil,
            proposalCandidateID: proposal.id,
            episodeMemory: memory,
            defaultCandidateID: "c0",
            allowProposalToken: false
        )

        XCTAssertEqual(selected, "c0")
    }

    func testEpisodeMemoryVisibleCandidatesIncludesActiveBestAndRecentHistory() {
        var memory = EpisodeMemory(
            seedBox: AIAnalysisResponse.BoundingBox(x: 0.01, y: 0.01, width: 0.02, height: 0.02),
            initialScore: 60,
            initialNote: "Initial",
            initialDescription: "Initial candidate",
            origin: "initial_detection"
        )
        let c1 = memory.appendCandidate(
            box: AIAnalysisResponse.BoundingBox(x: 0.02, y: 0.02, width: 0.02, height: 0.02),
            passIndex: 1,
            qualityScore: 70,
            evaluationNote: "Refine 1",
            candidateDescription: "First refinement candidate",
            origin: "refinement_pass_1"
        )
        let c2 = memory.appendCandidate(
            box: AIAnalysisResponse.BoundingBox(x: 0.03, y: 0.03, width: 0.02, height: 0.02),
            passIndex: 2,
            qualityScore: 80,
            evaluationNote: "Refine 2",
            candidateDescription: "Second refinement candidate",
            origin: "refinement_pass_2"
        )
        let c3 = memory.appendCandidate(
            box: AIAnalysisResponse.BoundingBox(x: 0.04, y: 0.04, width: 0.02, height: 0.02),
            passIndex: 3,
            qualityScore: 90,
            evaluationNote: "Refine 3",
            candidateDescription: "Third refinement candidate",
            origin: "refinement_pass_3"
        )
        memory.activeCandidateID = c3.id
        memory.bestCandidateID = c1.id

        let visible = memory.visibleCandidates(maxAdditionalHistoryCandidates: 3).map(\.id)

        XCTAssertEqual(visible.first, c3.id)
        XCTAssertTrue(visible.contains(c1.id))
        XCTAssertTrue(visible.contains(c2.id))
        XCTAssertTrue(visible.contains("c0"))
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
