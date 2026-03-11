import Foundation

struct OpenRouterRequest: Encodable, Sendable {
    let model: String
    let messages: [RequestMessage]
    let temperature: Double
    let maxTokens: Int
    let responseFormat: ResponseFormat?
    let reasoning: ReasoningConfiguration?
    let plugins: [OpenRouterPlugin]?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
        case reasoning
        case plugins
    }
}

struct ResponseFormat: Encodable, Sendable {
    let type: String
    let jsonSchema: StructuredOutputSchema?

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }

    init(type: String, jsonSchema: StructuredOutputSchema? = nil) {
        self.type = type
        self.jsonSchema = jsonSchema
    }

    static let jsonObject = ResponseFormat(type: "json_object")

    static func jsonSchema(
        name: String,
        schema: StructuredOutputSchema.SchemaObject,
        strict: Bool = true
    ) -> ResponseFormat {
        ResponseFormat(
            type: "json_schema",
            jsonSchema: StructuredOutputSchema(
                name: name,
                strict: strict,
                schema: schema
            )
        )
    }
}

struct ReasoningConfiguration: Encodable, Equatable, Sendable {
    let enabled: Bool?
    let effort: String?
    let exclude: Bool?
}

struct OpenRouterPlugin: Encodable, Equatable, Sendable {
    let id: String

    static let responseHealing = OpenRouterPlugin(id: "response-healing")
}

struct StructuredOutputSchema: Encodable, Equatable, Sendable {
    let name: String
    let strict: Bool
    let schema: SchemaObject

    final class SchemaObject: Encodable, Equatable, @unchecked Sendable {
        let type: String
        let description: String?
        let properties: [String: SchemaObject]?
        let items: SchemaObject?
        let required: [String]?
        let additionalProperties: Bool?
        let enumValues: [String]?

        enum CodingKeys: String, CodingKey {
            case type
            case description
            case properties
            case items
            case required
            case additionalProperties = "additionalProperties"
            case enumValues = "enum"
        }

        init(
            type: String,
            description: String? = nil,
            properties: [String: SchemaObject]? = nil,
            items: SchemaObject? = nil,
            required: [String]? = nil,
            additionalProperties: Bool? = nil,
            enumValues: [String]? = nil
        ) {
            self.type = type
            self.description = description
            self.properties = properties
            self.items = items
            self.required = required
            self.additionalProperties = additionalProperties
            self.enumValues = enumValues
        }

        static func object(
            description: String? = nil,
            properties: [String: SchemaObject],
            required: [String],
            additionalProperties: Bool = false
        ) -> SchemaObject {
            SchemaObject(
                type: "object",
                description: description,
                properties: properties,
                required: required,
                additionalProperties: additionalProperties
            )
        }

        static func array(
            description: String? = nil,
            items: SchemaObject
        ) -> SchemaObject {
            SchemaObject(
                type: "array",
                description: description,
                items: items
            )
        }

        static func string(
            description: String? = nil,
            enumValues: [String]? = nil
        ) -> SchemaObject {
            SchemaObject(
                type: "string",
                description: description,
                enumValues: enumValues
            )
        }

        static func integer(description: String? = nil) -> SchemaObject {
            SchemaObject(type: "integer", description: description)
        }

        static func number(description: String? = nil) -> SchemaObject {
            SchemaObject(type: "number", description: description)
        }

        static func == (lhs: SchemaObject, rhs: SchemaObject) -> Bool {
            lhs === rhs ||
            (
                lhs.type == rhs.type &&
                lhs.description == rhs.description &&
                lhs.properties == rhs.properties &&
                lhs.items == rhs.items &&
                lhs.required == rhs.required &&
                lhs.additionalProperties == rhs.additionalProperties &&
                lhs.enumValues == rhs.enumValues
            )
        }
    }
}

enum RequestMessage: Encodable, Sendable {
    case system(content: String)
    case user(content: [ContentPart])
    case assistant(content: String)

    private enum CodingKeys: String, CodingKey {
        case role, content
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .system(let content):
            try container.encode("system", forKey: .role)
            try container.encode(content, forKey: .content)
        case .user(let parts):
            try container.encode("user", forKey: .role)
            try container.encode(parts, forKey: .content)
        case .assistant(let content):
            try container.encode("assistant", forKey: .role)
            try container.encode(content, forKey: .content)
        }
    }
}

enum ContentPart: Encodable, Sendable {
    case text(String)
    case imageURL(String)

    private enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    private struct ImageURLWrapper: Encodable {
        let url: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURLWrapper(url: url), forKey: .imageURL)
        }
    }
}
