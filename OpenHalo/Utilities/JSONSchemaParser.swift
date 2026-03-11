import Foundation

enum JSONSchemaParser {
    /// Extract JSON from a model response that may contain markdown fences or extra text.
    static func extractJSON(from text: String) throws -> Data {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences: ```json ... ``` or ``` ... ```
        if cleaned.hasPrefix("```") {
            // Find the end of the first line (after ```json or ```)
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            // Remove trailing ```
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let data = cleaned.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        if let extracted = extractJSONObject(from: cleaned),
           let data = extracted.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        guard let data = cleaned.data(using: .utf8) else {
            throw JSONParsingError.invalidUTF8
        }
        _ = try JSONSerialization.jsonObject(with: data)
        return data
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var isEscaped = false

        for index in text[start...].indices {
            let character = text[index]

            if inString {
                if isEscaped {
                    isEscaped = false
                    continue
                }
                if character == "\\" {
                    isEscaped = true
                    continue
                }
                if character == "\"" {
                    inString = false
                }
                continue
            }

            if character == "\"" {
                inString = true
                continue
            }

            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
        }

        return nil
    }
}

enum JSONParsingError: Error, LocalizedError {
    case invalidUTF8
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "Response contains invalid UTF-8"
        case .invalidJSON:
            return "Response is not valid JSON"
        }
    }
}
