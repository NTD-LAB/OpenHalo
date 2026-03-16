import CoreGraphics
import Foundation

private enum FlexibleDecoding {
    static func decodeString<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K,
        default defaultValue: String? = nil
    ) throws -> String {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let defaultValue {
            return defaultValue
        }
        throw DecodingError.keyNotFound(
            key,
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Missing required string value for key \(key.stringValue)"
            )
        )
    }

    static func decodeDouble<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K,
        default defaultValue: Double? = nil
    ) throws -> Double {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let doubleValue = Double(normalized) {
                return doubleValue
            }
        }
        if let defaultValue {
            return defaultValue
        }
        throw DecodingError.keyNotFound(
            key,
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Missing required numeric value for key \(key.stringValue)"
            )
        )
    }

    static func decodeInt<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K,
        default defaultValue: Int? = nil
    ) throws -> Int {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(normalized) {
                return intValue
            }
            if let doubleValue = Double(normalized) {
                return Int(doubleValue.rounded())
            }
        }
        if let defaultValue {
            return defaultValue
        }
        throw DecodingError.keyNotFound(
            key,
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Missing required integer value for key \(key.stringValue)"
            )
        )
    }
}

private indirect enum RawJSONValue: Decodable {
    case object([String: RawJSONValue])
    case array([RawJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode([String: RawJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([RawJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func compactJSONString() -> String? {
        guard JSONSerialization.isValidJSONObject(jsonObjectRepresentation) else {
            return nil
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: jsonObjectRepresentation,
            options: []
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private var jsonObjectRepresentation: Any {
        switch self {
        case .object(let dictionary):
            return dictionary.mapValues { $0.jsonObjectRepresentation }
        case .array(let values):
            return values.map(\.jsonObjectRepresentation)
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        }
    }
}

struct OpenRouterAPIResponse: Decodable {
    let id: String
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Decodable {
        let role: String
        let content: String?

        enum CodingKeys: String, CodingKey {
            case role
            case content
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.role = try container.decode(String.self, forKey: .role)

            if let rawText = try? container.decode(String.self, forKey: .content) {
                self.content = rawText
                return
            }

            if let blocks = try? container.decode([ContentBlock].self, forKey: .content) {
                let joinedText = blocks
                    .compactMap(\.bestText)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.content = joinedText.isEmpty ? nil : joinedText
                return
            }

            if let rawJSON = try? container.decode(RawJSONValue.self, forKey: .content),
               let jsonString = rawJSON.compactJSONString() {
                self.content = jsonString
                return
            }

            self.content = nil
        }
    }

    struct ContentBlock: Decodable {
        let type: String?
        let text: String?
        let reasoning: String?

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case reasoning
        }

        var bestText: String? {
            if let text, !text.isEmpty {
                return text
            }
            if let reasoning, !reasoning.isEmpty {
                return reasoning
            }
            return nil
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int
        let completionTokens: Int

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
}

struct AIAnalysisResponse: Decodable {
    let message: String?
    let summary: String
    let nextAction: NextAction?
    let steps: [Step]
    let highlights: [HighlightData]

    enum CodingKeys: String, CodingKey {
        case message
        case summary
        case nextAction = "next_action"
        case steps
        case highlights
        case element
        case bbox
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.message = try? FlexibleDecoding.decodeString(
            from: container,
            forKey: .message
        )
        let fallbackElement = try? FlexibleDecoding.decodeString(
            from: container,
            forKey: .element
        )
        let decodedNextAction = try container.decodeIfPresent(NextAction.self, forKey: .nextAction)
        let decodedSteps = try container.decodeIfPresent([Step].self, forKey: .steps) ?? []
        let fallbackNextAction = decodedNextAction ?? decodedSteps
            .sorted(by: { $0.stepNumber < $1.stepNumber })
            .first
            .map { NextAction(instruction: $0.instruction, highlightId: $0.highlightId) }
        self.summary = try FlexibleDecoding.decodeString(
            from: container,
            forKey: .summary,
            default: self.message ??
                fallbackElement ??
                fallbackNextAction?.instruction ??
                ""
        )

        self.nextAction = decodedNextAction ?? decodedSteps
            .sorted(by: { $0.stepNumber < $1.stepNumber })
            .first
            .map { NextAction(instruction: $0.instruction, highlightId: $0.highlightId) }
        self.steps = decodedSteps
        let decodedHighlights = try container.decodeIfPresent([HighlightData].self, forKey: .highlights) ?? []
        if !decodedHighlights.isEmpty {
            self.highlights = decodedHighlights
        } else if let fallbackBoundingBox = try container.decodeIfPresent(BoundingBox.self, forKey: .bbox) {
            let fallbackLabel = fallbackElement ?? "Target"
            let fallbackHighlightID = fallbackNextAction?.highlightId ?? "h1"
            self.highlights = [
                HighlightData(
                    id: fallbackHighlightID,
                    label: fallbackLabel,
                    boundingBox: fallbackBoundingBox,
                    elementType: nil
                )
            ]
        } else {
            self.highlights = []
        }
    }

    init(
        message: String? = nil,
        summary: String,
        nextAction: NextAction? = nil,
        steps: [Step],
        highlights: [HighlightData]
    ) {
        self.message = message
        self.summary = summary
        self.nextAction = nextAction ?? steps
            .sorted(by: { $0.stepNumber < $1.stepNumber })
            .first
            .map { NextAction(instruction: $0.instruction, highlightId: $0.highlightId) }
        self.steps = steps
        self.highlights = highlights
    }

    struct NextAction: Decodable {
        let instruction: String
        let highlightId: String?

        enum CodingKeys: String, CodingKey {
            case instruction
            case highlightId = "highlight_id"
        }

        init(from decoder: Decoder) throws {
            if let singleValueContainer = try? decoder.singleValueContainer(),
               let instruction = try? singleValueContainer.decode(String.self) {
                self.instruction = instruction
                self.highlightId = nil
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.instruction = try FlexibleDecoding.decodeString(
                from: container,
                forKey: .instruction,
                default: ""
            )
            self.highlightId = try? FlexibleDecoding.decodeString(
                from: container,
                forKey: .highlightId
            )
        }

        init(instruction: String, highlightId: String?) {
            self.instruction = instruction
            self.highlightId = highlightId
        }
    }

    struct Step: Decodable {
        let stepNumber: Int
        let instruction: String
        let highlightId: String?

        enum CodingKeys: String, CodingKey {
            case stepNumber = "step_number"
            case instruction
            case highlightId = "highlight_id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.stepNumber = try FlexibleDecoding.decodeInt(
                from: container,
                forKey: .stepNumber
            )
            self.instruction = try FlexibleDecoding.decodeString(
                from: container,
                forKey: .instruction,
                default: ""
            )
            self.highlightId = try? FlexibleDecoding.decodeString(
                from: container,
                forKey: .highlightId
            )
        }

        init(stepNumber: Int, instruction: String, highlightId: String?) {
            self.stepNumber = stepNumber
            self.instruction = instruction
            self.highlightId = highlightId
        }
    }

    struct HighlightData: Decodable {
        let id: String
        let label: String
        let boundingBox: BoundingBox
        let elementType: String?

        enum CodingKeys: String, CodingKey {
            case id, label
            case boundingBox = "bounding_box"
            case elementType = "element_type"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try FlexibleDecoding.decodeString(from: container, forKey: .id)
            self.label = try FlexibleDecoding.decodeString(
                from: container,
                forKey: .label,
                default: "Target"
            )
            self.boundingBox = try container.decode(BoundingBox.self, forKey: .boundingBox)
            self.elementType = try? FlexibleDecoding.decodeString(
                from: container,
                forKey: .elementType
            )
        }

        init(id: String, label: String, boundingBox: BoundingBox, elementType: String?) {
            self.id = id
            self.label = label
            self.boundingBox = boundingBox
            self.elementType = elementType
        }
    }

    struct BoundingBox: Decodable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        enum CodingKeys: String, CodingKey {
            case x
            case y
            case width
            case height
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.x = try FlexibleDecoding.decodeDouble(from: container, forKey: .x)
            self.y = try FlexibleDecoding.decodeDouble(from: container, forKey: .y)
            self.width = try FlexibleDecoding.decodeDouble(from: container, forKey: .width)
            self.height = try FlexibleDecoding.decodeDouble(from: container, forKey: .height)
        }

        init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        func normalizedForImageSize(_ imageSize: CGSize) -> BoundingBox {
            let imageWidth = max(imageSize.width, 1.0)
            let imageHeight = max(imageSize.height, 1.0)

            return BoundingBox(
                x: Self.normalizeComponent(x, dimension: imageWidth),
                y: Self.normalizeComponent(y, dimension: imageHeight),
                width: Self.normalizeExtent(width, dimension: imageWidth),
                height: Self.normalizeExtent(height, dimension: imageHeight)
            ).clampedToUnitSpace()
        }

        func expandedToMinimumPixelSize(
            imageSize: CGSize,
            minimumPixelSize: CGSize
        ) -> BoundingBox {
            let imageWidth = max(imageSize.width, 1.0)
            let imageHeight = max(imageSize.height, 1.0)
            let minimumWidth = min(max(minimumPixelSize.width / imageWidth, 0.0), 1.0)
            let minimumHeight = min(max(minimumPixelSize.height / imageHeight, 0.0), 1.0)
            let clamped = clampedToUnitSpace(minimumExtent: 0.0)

            let centerX = clamped.x + (clamped.width / 2)
            let centerY = clamped.y + (clamped.height / 2)
            let width = max(clamped.width, minimumWidth)
            let height = max(clamped.height, minimumHeight)

            return BoundingBox(
                x: centerX - (width / 2),
                y: centerY - (height / 2),
                width: width,
                height: height
            ).clampedToUnitSpace()
        }

        func clampedToUnitSpace(minimumExtent: Double = 0.001) -> BoundingBox {
            let clampedWidth = min(max(width, minimumExtent), 1.0)
            let clampedHeight = min(max(height, minimumExtent), 1.0)
            let clampedX = min(max(x, 0.0), max(1.0 - clampedWidth, 0.0))
            let clampedY = min(max(y, 0.0), max(1.0 - clampedHeight, 0.0))

            return BoundingBox(
                x: clampedX,
                y: clampedY,
                width: clampedWidth,
                height: clampedHeight
            )
        }

        func isClose(to other: BoundingBox, threshold: Double = 0.002) -> Bool {
            abs(x - other.x) <= threshold &&
            abs(y - other.y) <= threshold &&
            abs(width - other.width) <= threshold &&
            abs(height - other.height) <= threshold
        }

        private static func normalizeComponent(
            _ value: Double,
            dimension: Double
        ) -> Double {
            guard value.isFinite else { return 0.0 }
            if value >= 0.0 && value <= 1.0 {
                return value
            }
            if value >= 0.0 && value <= dimension {
                return value / dimension
            }
            return value
        }

        private static func normalizeExtent(
            _ value: Double,
            dimension: Double
        ) -> Double {
            guard value.isFinite else { return 0.0 }
            if value >= 0.0 && value <= 1.0 {
                return value
            }
            if value >= 0.0 && value <= dimension {
                return value / dimension
            }
            return value
        }
    }
}

struct AIHighlightRefinementResponse: Decodable {
    let status: Status
    let activeCandidateDescription: String?
    let activeCandidateAssessment: String?
    let bestCandidateID: String?
    let bestCandidateScore: Int?
    let bestCandidateNote: String?
    let moveXY: MoveXY?
    let proposal: Proposal?
    let legacyCoordinateSpace: CoordinateSpace?
    let legacyTargetBox: AIAnalysisResponse.BoundingBox?
    let legacyPreferredCandidate: PreferredCandidate?
    let dx: Double?
    let dy: Double?
    let dw: Double?
    let dh: Double?
    let action: Action?
    let stepSize: StepSize?
    let reason: String?
    let confidence: Double?

    enum CodingKeys: String, CodingKey {
        case status
        case activeCandidateDescription = "active_candidate_description"
        case activeCandidateAssessment = "active_candidate_assessment"
        case bestCandidateID = "best_candidate_id"
        case bestCandidateScore = "best_candidate_score"
        case bestCandidateNote = "best_candidate_note"
        case moveXY = "move_xy"
        case proposal
        case legacyCoordinateSpace = "coordinate_space"
        case legacyTargetBox = "target_box"
        case legacyPreferredCandidate = "preferred_candidate"
        case dx, dy, dw, dh
        case action
        case stepSize = "step"
        case reason
        case confidence
    }

    struct Proposal: Decodable {
        let coordinateSpace: CoordinateSpace?
        let targetBox: AIAnalysisResponse.BoundingBox?
        let score: Int?
        let note: String?
        let description: String?

        enum CodingKeys: String, CodingKey {
            case coordinateSpace = "coordinate_space"
            case targetBox = "target_box"
            case score = "proposal_score"
            case note = "proposal_note"
            case description = "proposal_description"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.coordinateSpace = try container.decodeIfPresent(CoordinateSpace.self, forKey: .coordinateSpace)
            self.targetBox = try? container.decodeIfPresent(AIAnalysisResponse.BoundingBox.self, forKey: .targetBox)
            self.score = try? FlexibleDecoding.decodeInt(from: container, forKey: .score)
            self.note = try? FlexibleDecoding.decodeString(from: container, forKey: .note)
            self.description = try? FlexibleDecoding.decodeString(from: container, forKey: .description)
        }

        init(
            coordinateSpace: CoordinateSpace?,
            targetBox: AIAnalysisResponse.BoundingBox?,
            score: Int?,
            note: String?,
            description: String?
        ) {
            self.coordinateSpace = coordinateSpace
            self.targetBox = targetBox
            self.score = score
            self.note = note
            self.description = description
        }
    }

    struct MoveXY: Decodable, Equatable {
        let x: Double
        let y: Double

        enum CodingKeys: String, CodingKey {
            case x
            case y
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.x = try FlexibleDecoding.decodeDouble(from: container, forKey: .x)
            self.y = try FlexibleDecoding.decodeDouble(from: container, forKey: .y)
        }

        init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    enum CoordinateSpace: String, Decodable {
        case crop
        case screen

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self).lowercased()

            guard let coordinateSpace = CoordinateSpace(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported coordinate space: \(rawValue)"
                )
            }

            self = coordinateSpace
        }
    }

    enum Status: String, Decodable {
        case accept
        case move
        case relocalize

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self).lowercased()

            if rawValue == "act" || rawValue == "adjust" {
                self = .move
                return
            }

            guard let status = Status(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported refinement status: \(rawValue)"
                )
            }

            self = status
        }
    }

    enum PreferredCandidate: String, Decodable {
        case current
        case bestSoFar = "best_so_far"

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")

            switch rawValue {
            case "current":
                self = .current
            case "best_so_far", "best":
                self = .bestSoFar
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported preferred candidate: \(rawValue)"
                )
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.status = try container.decode(Status.self, forKey: .status)
        self.activeCandidateDescription = try? FlexibleDecoding.decodeString(
            from: container,
            forKey: .activeCandidateDescription
        )
        self.activeCandidateAssessment = try? FlexibleDecoding.decodeString(
            from: container,
            forKey: .activeCandidateAssessment
        )
        self.bestCandidateID = try? FlexibleDecoding.decodeString(
            from: container,
            forKey: .bestCandidateID
        )
        self.bestCandidateScore = try? FlexibleDecoding.decodeInt(
            from: container,
            forKey: .bestCandidateScore
        )
        self.bestCandidateNote = try? FlexibleDecoding.decodeString(
            from: container,
            forKey: .bestCandidateNote
        )
        self.moveXY = try? container.decodeIfPresent(MoveXY.self, forKey: .moveXY)
        self.legacyCoordinateSpace = try container.decodeIfPresent(CoordinateSpace.self, forKey: .legacyCoordinateSpace)
        self.legacyTargetBox = try container.decodeIfPresent(AIAnalysisResponse.BoundingBox.self, forKey: .legacyTargetBox)
        self.legacyPreferredCandidate = try container.decodeIfPresent(
            PreferredCandidate.self,
            forKey: .legacyPreferredCandidate
        )
        self.dx = try? FlexibleDecoding.decodeDouble(from: container, forKey: .dx)
        self.dy = try? FlexibleDecoding.decodeDouble(from: container, forKey: .dy)
        self.dw = try? FlexibleDecoding.decodeDouble(from: container, forKey: .dw)
        self.dh = try? FlexibleDecoding.decodeDouble(from: container, forKey: .dh)
        self.action = try container.decodeIfPresent(Action.self, forKey: .action)
        self.stepSize = try container.decodeIfPresent(StepSize.self, forKey: .stepSize)
        self.reason = try? FlexibleDecoding.decodeString(from: container, forKey: .reason)
        self.confidence = try? FlexibleDecoding.decodeDouble(from: container, forKey: .confidence)

        if let proposal = try container.decodeIfPresent(Proposal.self, forKey: .proposal) {
            self.proposal = proposal
        } else if self.legacyCoordinateSpace != nil || self.legacyTargetBox != nil {
            self.proposal = Proposal(
                coordinateSpace: self.legacyCoordinateSpace,
                targetBox: self.legacyTargetBox,
                score: nil,
                note: nil,
                description: nil
            )
        } else {
            self.proposal = nil
        }
    }

    var coordinateSpace: CoordinateSpace? {
        proposal?.coordinateSpace ?? legacyCoordinateSpace
    }

    var targetBox: AIAnalysisResponse.BoundingBox? {
        proposal?.targetBox ?? legacyTargetBox
    }

    var preferredCandidate: PreferredCandidate? {
        legacyPreferredCandidate
    }

    var proposalScore: Int? {
        proposal?.score
    }

    var proposalNote: String? {
        proposal?.note
    }

    var proposalDescription: String? {
        proposal?.description
    }

    var hasMoveXY: Bool {
        moveXY != nil
    }

    enum Action: String, Decodable {
        case left
        case right
        case up
        case down
        case wider
        case narrower
        case taller
        case shorter
        case grow
        case shrink

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self).lowercased()

            guard let action = Action(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported refinement action: \(rawValue)"
                )
            }

            self = action
        }
    }

    enum StepSize: String, Decodable {
        case small
        case medium
        case large

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self).lowercased()

            guard let stepSize = StepSize(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported refinement step: \(rawValue)"
                )
            }

            self = stepSize
        }
    }

    var hasRelativeAdjustment: Bool {
        dx != nil || dy != nil || dw != nil || dh != nil
    }

    var hasTargetBox: Bool {
        targetBox != nil
    }
}
