import Foundation
import AppKit

@MainActor
final class AppState: ObservableObject {
    private let plannerConfidenceThreshold = 0.8
    private let maximumPlannerClarificationRounds = 2

    @Published var messages: [ChatMessage] = []
    @Published var isProcessing: Bool = false
    @Published var highlights: [HighlightRegion] = []
    @Published var settings: AppSettings = AppSettings.load()
    @Published private(set) var pendingPlannerSession: PlannerSession?

    let screenCaptureService = ScreenCaptureService()
    let openRouterClient = OpenRouterClient()
    lazy var pipeline = AIAnalysisPipeline(
        capture: screenCaptureService,
        client: openRouterClient
    )

    // Callback to show overlay — set by AppDelegate
    var onShowHighlights: ((NSScreen, [HighlightRegion]) -> Void)?

    func submitQuery(_ text: String) async {
        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        isProcessing = true

        guard !settings.apiKey.isEmpty else {
            messages.append(ChatMessage(
                role: .assistant,
                content: "Please set your OpenRouter API key in Settings first."
            ))
            isProcessing = false
            return
        }
        defer { isProcessing = false }

        do {
            if let session = pendingPlannerSession {
                try await continuePlannerSession(session, with: text)
            } else {
                try await startPlannerFlow(for: text)
            }
        } catch let error as ScreenCaptureError {
            let content: String
            switch error {
            case .permissionDenied:
                content = "Screen capture failed: \(error.localizedDescription)\n\nGo to System Settings → Privacy & Security → Screen Recording → enable OpenHalo."
            default:
                content = "Screen capture failed: \(error.localizedDescription)"
            }

            messages.append(ChatMessage(
                role: .assistant,
                content: content
            ))
        } catch {
            messages.append(ChatMessage(
                role: .assistant,
                content: "Error: \(error.localizedDescription)"
            ))
        }
    }

    func clearHighlights() {
        highlights.removeAll()
    }

    private func startPlannerFlow(for text: String) async throws {
        let planning = try await pipeline.planIntent(
            query: text,
            settings: settings
        )
        try await handlePlannerResponse(
            planning,
            originalQuery: text,
            plannerQuery: text,
            clarificationRound: 0
        )
    }

    private func continuePlannerSession(
        _ session: PlannerSession,
        with text: String
    ) async throws {
        switch Self.parsePlannerReply(text) {
        case .option(let index) where (1...3).contains(index):
            let selectedIntent = session.options[index - 1]
            pendingPlannerSession = nil
            try await executeGuide(for: selectedIntent)
        case .option(4):
            messages.append(ChatMessage(
                role: .assistant,
                content: "请用一句话直接描述你真正想完成的目标。"
            ))
        case .option:
            messages.append(ChatMessage(
                role: .assistant,
                content: "请回复 1、2、3，或者选择 4 后自己描述你的目标。"
            ))
        case .freeform(let freeformText):
            let nextRound = session.clarificationRound + 1
            let planning = try await pipeline.planIntent(
                query: freeformText,
                settings: settings,
                context: PlannerConversationContext(
                    originalQuery: session.originalQuery,
                    clarificationRound: nextRound,
                    previousTentativeIntent: session.tentativeIntent,
                    previousAmbiguityReason: session.ambiguityReason,
                    previousOptions: session.options
                )
            )
            try await handlePlannerResponse(
                planning,
                originalQuery: session.originalQuery,
                plannerQuery: freeformText,
                clarificationRound: nextRound
            )
        case .none:
            let nextRound = session.clarificationRound + 1
            let planning = try await pipeline.planIntent(
                query: text,
                settings: settings,
                context: PlannerConversationContext(
                    originalQuery: session.originalQuery,
                    clarificationRound: nextRound,
                    previousTentativeIntent: session.tentativeIntent,
                    previousAmbiguityReason: session.ambiguityReason,
                    previousOptions: session.options
                )
            )
            try await handlePlannerResponse(
                planning,
                originalQuery: session.originalQuery,
                plannerQuery: text,
                clarificationRound: nextRound
            )
        }
    }

    private func handlePlannerResponse(
        _ response: AIIntentPlannerResponse,
        originalQuery: String,
        plannerQuery: String,
        clarificationRound: Int
    ) async throws {
        if response.status == .ready,
           response.confidence >= plannerConfidenceThreshold,
           let resolvedIntent = response.resolvedIntent,
           !resolvedIntent.isEmpty {
            pendingPlannerSession = nil
            try await executeGuide(for: resolvedIntent)
            return
        }

        let options = Array(response.options.prefix(3))
        guard options.count == 3 else {
            if let fallbackIntent = Self.plannerDirectExecutionFallbackIntent(
                plannerQuery: plannerQuery,
                originalQuery: originalQuery,
                response: response
            ) {
                pendingPlannerSession = nil
                try await executeGuide(for: fallbackIntent)
                return
            }
            pendingPlannerSession = nil
            messages.append(ChatMessage(
                role: .assistant,
                content: "我还不能稳定判断你的目标。请更具体地描述你想完成的事，例如“关闭当前标签页”或“打开 Chrome 设置”。"
            ))
            return
        }

        if clarificationRound >= maximumPlannerClarificationRounds {
            if let fallbackIntent = Self.plannerDirectExecutionFallbackIntent(
                plannerQuery: plannerQuery,
                originalQuery: originalQuery,
                response: response
            ) {
                pendingPlannerSession = nil
                try await executeGuide(for: fallbackIntent)
                return
            }
            pendingPlannerSession = nil
            messages.append(ChatMessage(
                role: .assistant,
                content: "我还是无法稳定收敛你的意图。请更具体地重述一次，例如明确说“关闭当前标签页”还是“关闭整个窗口”。"
            ))
            return
        }

        pendingPlannerSession = PlannerSession(
            originalQuery: originalQuery,
            tentativeIntent: response.tentativeIntent,
            ambiguityReason: response.ambiguityReason,
            options: options,
            clarificationRound: clarificationRound
        )

        messages.append(ChatMessage(
            role: .assistant,
            content: Self.plannerClarificationMessage(
                tentativeIntent: response.tentativeIntent,
                ambiguityReason: response.ambiguityReason,
                options: options
            )
        ))
    }

    private func executeGuide(for resolvedIntent: String) async throws {
        let result = try await pipeline.analyze(
            query: resolvedIntent,
            settings: settings,
            onIntermediateHighlights: { [weak self] screen, regions in
                guard let self else { return }
                self.highlights = regions
                self.onShowHighlights?(screen, regions)
            }
        )

        highlights = result.highlights
        messages.append(ChatMessage(
            role: .assistant,
            content: result.responseText,
            highlights: result.highlights
        ))

        print("[OpenHalo] === HIGHLIGHT CHAIN DEBUG ===")
        print("[OpenHalo] Got \(result.highlights.count) highlights from AI")
        for h in result.highlights {
            print("[OpenHalo]   id=\(h.id) label=\"\(h.label)\" rect=\(h.screenRect)")
        }
        print("[OpenHalo] onShowHighlights callback is \(onShowHighlights == nil ? "❌ NIL" : "✅ SET")")
        if !result.highlights.isEmpty {
            if let callback = onShowHighlights {
                print("[OpenHalo] ✅ Calling onShowHighlights with \(result.highlights.count) regions...")
                callback(result.targetScreen, result.highlights)
            } else {
                print("[OpenHalo] ❌ onShowHighlights is nil! Overlay will NOT appear.")
            }
        } else {
            print("[OpenHalo] ⚠️ No highlights returned by AI — nothing to show")
        }
    }

    static func plannerClarificationMessage(
        tentativeIntent: String?,
        ambiguityReason: String?,
        options: [String]
    ) -> String {
        var lines: [String] = ["我想先确认你的目标。"]

        if let tentativeIntent, !tentativeIntent.isEmpty {
            lines.append("当前最可能的理解：\(tentativeIntent)")
        }

        if let ambiguityReason, !ambiguityReason.isEmpty {
            lines.append(ambiguityReason)
        }

        lines.append("")
        for (index, option) in options.enumerated() {
            lines.append("\(index + 1). \(option)")
        }
        lines.append("4. 以上都不是，请你自己描述")
        return lines.joined(separator: "\n")
    }

    static func parsePlannerReply(_ text: String) -> PlannerReply? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = normalizePlannerReply(trimmed)
        if let match = normalized.wholeMatch(of: /^([1-4])(?:[\.\)\]、:：])?$/),
           let index = Int(match.1) {
            return .option(index)
        }

        if let match = normalized.wholeMatch(of: /^4(?:[\.\)\]、:：])?\s+(.+)$/) {
            let freeform = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
            return freeform.isEmpty ? .option(4) : .freeform(freeform)
        }

        return .freeform(trimmed)
    }

    private static func normalizePlannerReply(_ text: String) -> String {
        text
            .replacingOccurrences(of: "１", with: "1")
            .replacingOccurrences(of: "２", with: "2")
            .replacingOccurrences(of: "３", with: "3")
            .replacingOccurrences(of: "４", with: "4")
    }

    static func plannerDirectExecutionFallbackIntent(
        plannerQuery: String,
        originalQuery: String,
        response: AIIntentPlannerResponse
    ) -> String? {
        let preferredQuery = plannerQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackQuery = originalQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        if isLikelyVisibleTargetIntent(preferredQuery) {
            return preferredQuery
        }

        if isLikelyVisibleTargetIntent(fallbackQuery) {
            return fallbackQuery
        }

        guard response.status == .ready,
              let resolvedIntent = response.resolvedIntent?.trimmingCharacters(in: .whitespacesAndNewlines),
              !resolvedIntent.isEmpty,
              isLikelyVisibleTargetIntent(resolvedIntent) else {
            return nil
        }

        return resolvedIntent
    }

    private static func isLikelyVisibleTargetIntent(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return false }

        let actionTokens = [
            "open", "close", "find", "locate", "switch", "select", "focus", "show",
            "打开", "关闭", "找到", "找出", "定位", "切到", "切换", "选中", "进入", "显示"
        ]
        let targetTokens = [
            "tab", "page", "window", "button", "icon", "menu", "link", "sidebar",
            "field", "input", "box", "dialog", "toolbar",
            "标签页", "页签", "页面", "窗口", "按钮", "图标", "菜单", "链接",
            "侧边栏", "输入框", "搜索框", "对话框", "工具栏", "当前"
        ]

        let hasAction = actionTokens.contains { normalized.contains($0) }
        let hasTarget = targetTokens.contains { normalized.contains($0) }
        return hasAction && hasTarget
    }
}

struct PlannerSession {
    let originalQuery: String
    let tentativeIntent: String?
    let ambiguityReason: String?
    let options: [String]
    let clarificationRound: Int
}

enum PlannerReply: Equatable {
    case option(Int)
    case freeform(String)
}
