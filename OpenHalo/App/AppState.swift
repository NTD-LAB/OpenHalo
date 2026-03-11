import Foundation
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isProcessing: Bool = false
    @Published var highlights: [HighlightRegion] = []
    @Published var settings: AppSettings = AppSettings.load()

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
            let result = try await pipeline.analyze(
                query: text,
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
        } catch let error as ScreenCaptureError {
            messages.append(ChatMessage(
                role: .assistant,
                content: "Screen capture failed: \(error.localizedDescription)\n\nGo to System Settings → Privacy & Security → Screen Recording → enable OpenHalo."
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
}
