import Foundation

struct FramePoolLabInterpretationResult: Sendable {
    let summary: String
    let latencyMilliseconds: Int
}

enum FramePoolLabError: Error, LocalizedError {
    case apiError(statusCode: Int, body: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .apiError(let statusCode, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().contains("<html") {
                return "OpenRouter returned HTTP \(statusCode) with an HTML error page."
            }
            return "OpenRouter returned HTTP \(statusCode): \(String(trimmed.prefix(300)))"
        case .emptyResponse:
            return "The model returned an empty response."
        }
    }
}

actor FramePoolLabVisionClient {
    private let baseURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: configuration)
    }

    func interpret(
        base64Image: String,
        prompt: String,
        previousSummary: String?,
        model: String,
        apiKey: String
    ) async throws -> FramePoolLabInterpretationResult {
        let userPrompt = Self.userPrompt(
            prompt: prompt,
            previousSummary: previousSummary
        )
        let requestBody = OpenRouterRequest(
            model: model,
            messages: [
                .system(content: Self.systemPrompt),
                .user(content: [
                    .text(userPrompt),
                    .imageURL("data:image/jpeg;base64,\(base64Image)")
                ]),
            ],
            temperature: 0.2,
            maxTokens: 300,
            responseFormat: nil,
            reasoning: nil,
            plugins: nil
        )

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("FramePoolLab/1.0", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("FramePoolLab", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let startedAt = Date()
        let (data, response) = try await session.data(for: request)
        let latencyMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000.0)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw FramePoolLabError.apiError(statusCode: httpResponse.statusCode, body: body)
        }

        let apiResponse = try JSONDecoder().decode(OpenRouterAPIResponse.self, from: data)
        guard let content = apiResponse.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw FramePoolLabError.emptyResponse
        }

        return FramePoolLabInterpretationResult(
            summary: content,
            latencyMilliseconds: latencyMilliseconds
        )
    }

    private static let systemPrompt = """
    You are a realtime desktop page interpreter.

    Describe what is visible on the current screen in concise plain text.
    Focus on:
    1. Which app, site, or page is visible.
    2. The main section or task the user is looking at.
    3. The most important visible controls or content.
    4. Whether it looks changed compared with the previous summary.

    Keep the answer short. Prefer 3 to 5 bullet lines. Do not output JSON.
    """

    private static func userPrompt(
        prompt: String,
        previousSummary: String?
    ) -> String {
        var lines = [
            "Task: \(prompt)"
        ]
        if let previousSummary, !previousSummary.isEmpty {
            lines.append("Previous summary: \(previousSummary)")
        }
        return lines.joined(separator: "\n")
    }
}
