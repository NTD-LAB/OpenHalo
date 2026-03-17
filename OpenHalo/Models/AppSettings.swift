import Foundation

struct AppSettings: Codable {
    struct ModelOption: Identifiable, Equatable {
        let id: String
        let displayName: String
        let provider: String
        let supportsReasoning: Bool

        var pickerLabel: String {
            let reasoningLabel = supportsReasoning ? "reasoning" : "standard"
            return "\(provider) · \(displayName) [\(reasoningLabel)]"
        }
    }

    var apiKey: String
    var selectedModel: String
    var compressionQuality: Double
    var reasoningEnabled: Bool
    var reasoningEffort: String

    static let legacyDefaultModel = "google/gemini-2.5-flash-lite"
    static let previousThinkingDefaultModel = "openai/o4-mini"
    static let previousThinkingDefaultReasoningEffort = "high"
    static let previousStandardDefaultModel = "openai/gpt-4o-mini"
    static let defaultModel = "openai/gpt-5.3-chat"
    static let defaultReasoningEnabled = false
    static let defaultReasoningEffort = "minimal"

    static let availableModelOptions = openAIModelOptions + anthropicModelOptions + googleModelOptions
    static let availableModels = availableModelOptions.map(\.id)

    static let availableReasoningEfforts = [
        "minimal",
        "low",
        "medium",
        "high",
        "xhigh",
    ]

    enum CodingKeys: String, CodingKey {
        case apiKey
        case selectedModel
        case compressionQuality
        case reasoningEnabled
        case reasoningEffort
    }

    init() {
        self.apiKey = ""
        self.selectedModel = Self.defaultModel
        self.compressionQuality = 0.7
        self.reasoningEnabled = Self.defaultReasoningEnabled
        self.reasoningEffort = Self.defaultReasoningEffort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedModel = try container.decodeIfPresent(String.self, forKey: .selectedModel)
            ?? Self.defaultModel
        let decodedCompressionQuality = try container.decodeIfPresent(Double.self, forKey: .compressionQuality)
            ?? 0.7
        let decodedReasoningEnabled = try container.decodeIfPresent(Bool.self, forKey: .reasoningEnabled)
        let decodedReasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)

        self.apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        self.selectedModel = Self.normalizedModel(decodedModel)
        self.compressionQuality = decodedCompressionQuality
        self.reasoningEnabled = decodedReasoningEnabled ?? Self.defaultReasoningEnabled
        self.reasoningEffort = Self.normalizedReasoningEffort(
            decodedReasoningEffort ?? Self.defaultReasoningEffort
        )

        if Self.shouldUpgradeToLowLatencyDefaults(
            decodedModel: decodedModel,
            decodedReasoningEnabled: decodedReasoningEnabled,
            decodedReasoningEffort: decodedReasoningEffort
        ) {
            self.selectedModel = Self.defaultModel
            self.reasoningEnabled = Self.defaultReasoningEnabled
            self.reasoningEffort = Self.defaultReasoningEffort
        }
    }

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: "appSettings"),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return AppSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "appSettings")
        }
    }

    var reasoningConfiguration: ReasoningConfiguration? {
        guard reasoningEnabled else { return nil }
        guard Self.supportsReasoning(for: selectedModel) else { return nil }
        return ReasoningConfiguration(
            enabled: true,
            effort: Self.normalizedReasoningEffort(reasoningEffort),
            exclude: true
        )
    }

    static func modelOption(for modelID: String) -> ModelOption? {
        availableModelOptions.first(where: { $0.id == modelID })
    }

    static func supportsReasoning(for modelID: String) -> Bool {
        modelOption(for: modelID)?.supportsReasoning ?? false
    }

    private static func normalizedModel(_ model: String) -> String {
        if availableModels.contains(model) {
            return model
        }
        return defaultModel
    }

    private static func normalizedReasoningEffort(_ effort: String) -> String {
        let lowered = effort.lowercased()
        if availableReasoningEfforts.contains(lowered) {
            return lowered
        }
        return defaultReasoningEffort
    }

    private static func shouldUpgradeToLowLatencyDefaults(
        decodedModel: String?,
        decodedReasoningEnabled: Bool?,
        decodedReasoningEffort: String?
    ) -> Bool {
        if decodedModel == Self.legacyDefaultModel &&
            decodedReasoningEnabled == nil &&
            decodedReasoningEffort == nil {
            return true
        }

        if decodedModel == Self.previousStandardDefaultModel &&
            decodedReasoningEnabled == nil &&
            decodedReasoningEffort == nil {
            return true
        }

        return decodedModel == Self.previousThinkingDefaultModel &&
            (decodedReasoningEnabled ?? true) &&
            normalizedReasoningEffort(decodedReasoningEffort ?? Self.previousThinkingDefaultReasoningEffort) == Self.previousThinkingDefaultReasoningEffort
    }

    private static let openAIModelOptions = [
        ModelOption(id: "openai/gpt-4o-mini", displayName: "GPT-4o Mini", provider: "OpenAI", supportsReasoning: false),
        ModelOption(id: "openai/gpt-4o", displayName: "GPT-4o", provider: "OpenAI", supportsReasoning: false),
        ModelOption(id: "openai/gpt-4.1-mini", displayName: "GPT-4.1 Mini", provider: "OpenAI", supportsReasoning: false),
        ModelOption(id: "openai/gpt-4.1-nano", displayName: "GPT-4.1 Nano", provider: "OpenAI", supportsReasoning: false),
        ModelOption(id: "openai/gpt-4.1", displayName: "GPT-4.1", provider: "OpenAI", supportsReasoning: false),
        ModelOption(id: "openai/gpt-4-turbo", displayName: "GPT-4 Turbo", provider: "OpenAI", supportsReasoning: false),
        ModelOption(id: "openai/gpt-5-chat", displayName: "GPT-5 Chat", provider: "OpenAI", supportsReasoning: false),
        ModelOption(id: "openai/gpt-5.1-chat", displayName: "GPT-5.1 Chat", provider: "OpenAI", supportsReasoning: false),
        ModelOption(id: "openai/gpt-5.2-chat", displayName: "GPT-5.2 Chat", provider: "OpenAI", supportsReasoning: false),
        ModelOption(id: "openai/gpt-5.3-chat", displayName: "GPT-5.3 Chat", provider: "OpenAI", supportsReasoning: false),
        ModelOption(id: "openai/o1", displayName: "o1", provider: "OpenAI", supportsReasoning: false),
        ModelOption(id: "openai/o4-mini", displayName: "o4 Mini", provider: "OpenAI", supportsReasoning: true),
        ModelOption(id: "openai/o4-mini-high", displayName: "o4 Mini High", provider: "OpenAI", supportsReasoning: true),
        ModelOption(id: "openai/o3", displayName: "o3", provider: "OpenAI", supportsReasoning: true),
        ModelOption(id: "openai/o3-pro", displayName: "o3 Pro", provider: "OpenAI", supportsReasoning: true),
        ModelOption(id: "openai/o1-pro", displayName: "o1 Pro", provider: "OpenAI", supportsReasoning: true),
        ModelOption(id: "openai/gpt-5", displayName: "GPT-5", provider: "OpenAI", supportsReasoning: true),
        ModelOption(id: "openai/gpt-5-mini", displayName: "GPT-5 Mini", provider: "OpenAI", supportsReasoning: true),
        ModelOption(id: "openai/gpt-5-nano", displayName: "GPT-5 Nano", provider: "OpenAI", supportsReasoning: true),
        ModelOption(id: "openai/gpt-5-pro", displayName: "GPT-5 Pro", provider: "OpenAI", supportsReasoning: true),
        ModelOption(id: "openai/gpt-5.1", displayName: "GPT-5.1", provider: "OpenAI", supportsReasoning: true),
        ModelOption(id: "openai/gpt-5.2", displayName: "GPT-5.2", provider: "OpenAI", supportsReasoning: true),
        ModelOption(id: "openai/gpt-5.2-pro", displayName: "GPT-5.2 Pro", provider: "OpenAI", supportsReasoning: true),
        ModelOption(id: "openai/gpt-5.4", displayName: "GPT-5.4", provider: "OpenAI", supportsReasoning: true),
        ModelOption(id: "openai/gpt-5.4-pro", displayName: "GPT-5.4 Pro", provider: "OpenAI", supportsReasoning: true),
    ]

    private static let anthropicModelOptions = [
        ModelOption(id: "anthropic/claude-sonnet-4.6", displayName: "Claude Sonnet 4.6", provider: "Anthropic", supportsReasoning: false),
        ModelOption(id: "anthropic/claude-opus-4.6", displayName: "Claude Opus 4.6", provider: "Anthropic", supportsReasoning: false),
    ]

    private static let googleModelOptions = [
        ModelOption(id: "google/gemini-2.0-flash-lite-001", displayName: "Gemini 2.0 Flash Lite", provider: "Google", supportsReasoning: false),
        ModelOption(id: "google/gemini-2.0-flash-001", displayName: "Gemini 2.0 Flash", provider: "Google", supportsReasoning: false),
        ModelOption(id: "google/gemini-2.5-flash", displayName: "Gemini 2.5 Flash", provider: "Google", supportsReasoning: true),
        ModelOption(id: "google/gemini-2.5-flash-lite", displayName: "Gemini 2.5 Flash Lite", provider: "Google", supportsReasoning: true),
        ModelOption(id: "google/gemini-2.5-flash-lite-preview-09-2025", displayName: "Gemini 2.5 Flash Lite Preview", provider: "Google", supportsReasoning: true),
        ModelOption(id: "google/gemini-2.5-pro", displayName: "Gemini 2.5 Pro", provider: "Google", supportsReasoning: true),
        ModelOption(id: "google/gemini-2.5-pro-preview", displayName: "Gemini 2.5 Pro Preview", provider: "Google", supportsReasoning: true),
        ModelOption(id: "google/gemini-2.5-pro-preview-05-06", displayName: "Gemini 2.5 Pro Preview 05-06", provider: "Google", supportsReasoning: true),
        ModelOption(id: "google/gemini-3-flash-preview", displayName: "Gemini 3 Flash Preview", provider: "Google", supportsReasoning: true),
        ModelOption(id: "google/gemini-3.1-flash-lite-preview", displayName: "Gemini 3.1 Flash Lite Preview", provider: "Google", supportsReasoning: true),
    ]
}
