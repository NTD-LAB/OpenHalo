import Foundation

actor OpenRouterClient {
    private let baseURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    func analyzeScreenshot(
        base64Image: String,
        userQuery: String,
        model: String,
        apiKey: String,
        systemPrompt: String,
        reasoning: ReasoningConfiguration?,
        rawContentHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> AIAnalysisResponse {
        try await sendStructuredJSONRequest(
            model: model,
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            userParts: [
                .text(userQuery),
                .imageURL("data:image/jpeg;base64,\(base64Image)"),
            ],
            maxTokens: 768,
            reasoning: reasoning,
            structuredResponseFormat: Self.analysisResponseFormat,
            responseType: AIAnalysisResponse.self,
            rawContentHandler: rawContentHandler
        )
    }

    func refineHighlight(
        base64Images: [String],
        userPrompt: String,
        model: String,
        apiKey: String,
        systemPrompt: String,
        reasoning: ReasoningConfiguration?,
        rawContentHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> AIHighlightRefinementResponse {
        try await sendStructuredJSONRequest(
            model: model,
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            userParts: [.text(userPrompt)] + base64Images.map { .imageURL("data:image/jpeg;base64,\($0)") },
            maxTokens: 384,
            reasoning: reasoning,
            structuredResponseFormat: Self.refinementResponseFormat,
            responseType: AIHighlightRefinementResponse.self,
            rawContentHandler: rawContentHandler
        )
    }

    private func sendStructuredJSONRequest<Response: Decodable>(
        model: String,
        apiKey: String,
        systemPrompt: String,
        userParts: [ContentPart],
        maxTokens: Int,
        reasoning: ReasoningConfiguration?,
        structuredResponseFormat: ResponseFormat,
        responseType: Response.Type,
        rawContentHandler: (@Sendable (String) -> Void)?
    ) async throws -> Response {
        do {
            return try await sendJSONRequest(
                model: model,
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                userParts: userParts,
                maxTokens: maxTokens,
                reasoning: reasoning,
                responseFormat: structuredResponseFormat,
                responseType: responseType,
                rawContentHandler: rawContentHandler
            )
        } catch {
            guard Self.shouldRetryWithJSONObject(error) else {
                throw error
            }

            return try await sendJSONRequest(
                model: model,
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                userParts: userParts,
                maxTokens: maxTokens,
                reasoning: reasoning,
                responseFormat: .jsonObject,
                responseType: responseType,
                rawContentHandler: rawContentHandler
            )
        }
    }

    private func sendJSONRequest<Response: Decodable>(
        model: String,
        apiKey: String,
        systemPrompt: String,
        userParts: [ContentPart],
        maxTokens: Int,
        reasoning: ReasoningConfiguration?,
        responseFormat: ResponseFormat,
        responseType: Response.Type,
        rawContentHandler: (@Sendable (String) -> Void)?
    ) async throws -> Response {
        let request = OpenRouterRequest(
            model: model,
            messages: [
                .system(content: systemPrompt),
                .user(content: userParts),
            ],
            temperature: 0.1,
            maxTokens: maxTokens,
            responseFormat: responseFormat,
            reasoning: reasoning,
            plugins: [.responseHealing]
        )

        var urlRequest = URLRequest(url: baseURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("OpenHalo/1.0", forHTTPHeaderField: "HTTP-Referer")
        urlRequest.setValue("OpenHalo", forHTTPHeaderField: "X-Title")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw OpenRouterError.apiError(statusCode: httpResponse.statusCode, body: body)
        }

        let apiResponse: OpenRouterAPIResponse
        do {
            apiResponse = try JSONDecoder().decode(OpenRouterAPIResponse.self, from: data)
        } catch {
            throw OpenRouterError.responseDecodingFailed(
                details: Self.responsePreview(from: data, fallback: error.localizedDescription)
            )
        }
        return try parseJSONResponse(
            apiResponse,
            as: responseType,
            rawContentHandler: rawContentHandler
        )
    }

    private func parseJSONResponse<Response: Decodable>(
        _ response: OpenRouterAPIResponse,
        as responseType: Response.Type,
        rawContentHandler: (@Sendable (String) -> Void)?
    ) throws -> Response {
        guard let content = response.choices.first?.message.content else {
            throw OpenRouterError.emptyResponse
        }
        rawContentHandler?(content)
        let jsonData: Data
        do {
            jsonData = try JSONSchemaParser.extractJSON(from: content)
        } catch {
            throw OpenRouterError.structuredOutputDecodingFailed(
                details: Self.contentPreview(content)
            )
        }

        do {
            return try JSONDecoder().decode(responseType, from: jsonData)
        } catch {
            let extractedJSON = String(data: jsonData, encoding: .utf8) ?? Self.contentPreview(content)
            throw OpenRouterError.structuredOutputDecodingFailed(
                details: """
                \(error.localizedDescription)

                Preview:
                \(Self.contentPreview(extractedJSON))
                """
            )
        }
    }

    private static func responsePreview(from data: Data, fallback: String) -> String {
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty {
            return String(raw.prefix(1200))
        }
        return fallback
    }

    private static func contentPreview(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "empty content"
        }
        return String(trimmed.prefix(1200))
    }

    private static func shouldRetryWithJSONObject(_ error: Error) -> Bool {
        guard case let OpenRouterError.apiError(_, body) = error else {
            return false
        }

        let normalizedBody = body.lowercased()
        return normalizedBody.contains("response_format") ||
            normalizedBody.contains("json_schema") ||
            normalizedBody.contains("structured output") ||
            normalizedBody.contains("structured outputs") ||
            normalizedBody.contains("schema is not supported")
    }

    private static let analysisResponseFormat = ResponseFormat.jsonSchema(
        name: "openhalo_analysis_response",
        schema: .object(
            description: "Structured response for initial OpenHalo screen analysis.",
            properties: [
                "message": .string(description: "User-facing reply shown in the chat UI."),
                "summary": .string(description: "Short factual summary of what was found."),
                "next_action": .object(
                    description: "The single immediate next action the user can take on the current screenshot.",
                    properties: [
                        "instruction": .string(description: "Human-readable immediate next action."),
                        "highlight_id": .string(description: "Optional ID of the related highlight.")
                    ],
                    required: ["instruction"]
                ),
                "highlights": .array(
                    description: "UI elements to highlight on screen.",
                    items: .object(
                        properties: [
                            "id": .string(description: "Stable highlight identifier."),
                            "label": .string(description: "Short label for the UI element."),
                            "bounding_box": .object(
                                properties: [
                                    "x": .number(description: "Normalized left edge in [0,1]."),
                                    "y": .number(description: "Normalized top edge in [0,1]."),
                                    "width": .number(description: "Normalized width in [0,1]."),
                                    "height": .number(description: "Normalized height in [0,1].")
                                ],
                                required: ["x", "y", "width", "height"]
                            ),
                            "element_type": .string(description: "Semantic UI element type.")
                        ],
                        required: ["id", "label", "bounding_box"]
                    )
                )
            ],
            required: ["message", "summary", "highlights"]
        )
    )

    private static let refinementResponseFormat = ResponseFormat.jsonSchema(
        name: "openhalo_refinement_response",
        schema: .object(
            description: "Structured response for iterative box refinement.",
            properties: [
                "status": .string(
                    description: "Whether to keep the current box or modify it.",
                    enumValues: ["accept", "move", "relocalize"]
                ),
                "active_candidate_description": .string(
                    description: "A very short phrase describing what is inside the currently active candidate box."
                ),
                "active_candidate_assessment": .string(
                    description: "A very short sentence saying why the active candidate is or is not the requested target."
                ),
                "best_candidate_id": .string(
                    description: "Which already-visible candidate is currently the best final presentation box. Use one of the provided candidate IDs only; do not name a new unseen proposal as best."
                ),
                "best_candidate_score": .integer(
                    description: "Integer quality score from 0 to 100 for the selected best candidate."
                ),
                "best_candidate_note": .string(
                    description: "Short explanation for why the selected best candidate is the most useful final box for a human click."
                ),
                "move_xy": .object(
                    description: "Relative center movement in current-box units when status is move.",
                    properties: [
                        "x": .number(description: "Horizontal move in current-box widths. 0 keeps the current center, positive moves right."),
                        "y": .number(description: "Vertical move in current-box heights. 0 keeps the current center, positive moves down.")
                    ],
                    required: ["x", "y"]
                ),
                "reason": .string(description: "Short explanation of the refinement decision."),
                "confidence": .number(description: "Confidence score between 0 and 1.")
            ],
            required: ["status", "active_candidate_description", "active_candidate_assessment", "best_candidate_id", "best_candidate_score", "best_candidate_note", "reason", "confidence"]
        )
    )
}

enum OpenRouterError: Error, LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, body: String)
    case emptyResponse
    case invalidJSON
    case responseDecodingFailed(details: String)
    case structuredOutputDecodingFailed(details: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .apiError(let code, let body):
            return Self.humanReadableAPIError(statusCode: code, body: body)
        case .emptyResponse:
            return "Empty response from AI model"
        case .invalidJSON:
            return "Failed to parse AI response as JSON"
        case .responseDecodingFailed(let details):
            return "Failed to decode OpenRouter response: \(details)"
        case .structuredOutputDecodingFailed(let details):
            return "Model did not return the expected JSON format: \(details)"
        }
    }

    private static func humanReadableAPIError(statusCode: Int, body: String) -> String {
        guard let envelope = parseAPIErrorBody(body) else {
            return "API error (\(statusCode)): \(body)"
        }
        let apiError = envelope.error

        if apiError.message == "No allowed providers are available for the selected model." {
            let available = apiError.metadata?.availableProviders.joined(separator: ", ") ?? "unknown"
            let requested = apiError.metadata?.requestedProviders.joined(separator: ", ") ?? "unknown"

            return """
            This model is not available with your current OpenRouter provider restrictions.

            Available providers for this model: \(available)
            Your allowed providers: \(requested)

            Switch to a non-Vertex model such as GPT-4o Mini, Gemini 2.0 Flash Lite, Gemini 2.0 Flash, or Gemini 2.5 Flash.
            """
        }

        return "API error (\(statusCode)): \(apiError.message)"
    }

    private static func parseAPIErrorBody(_ body: String) -> APIErrorEnvelope? {
        guard let data = body.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
    }
}

private struct APIErrorEnvelope: Decodable {
    let error: APIErrorPayload
}

private struct APIErrorPayload: Decodable {
    let message: String
    let code: Int?
    let metadata: APIErrorMetadata?
}

private struct APIErrorMetadata: Decodable {
    let availableProviders: [String]
    let requestedProviders: [String]

    enum CodingKeys: String, CodingKey {
        case availableProviders = "available_providers"
        case requestedProviders = "requested_providers"
    }
}
