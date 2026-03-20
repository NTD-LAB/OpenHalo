import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("API Configuration") {
                SecureField("OpenRouter API Key", text: $appState.settings.apiKey)
                    .onChange(of: appState.settings.apiKey) { _, _ in saveSettings() }

                Picker("Model", selection: $appState.settings.selectedModel) {
                    ForEach(AppSettings.availableModelOptions) { option in
                        Text(option.pickerLabel).tag(option.id)
                    }
                }
                .onChange(of: appState.settings.selectedModel) { _, _ in saveSettings() }

                Text("Default model: GPT-5.3 Chat. Fast alternatives: GPT-4o Mini, Claude Sonnet 4.6, Llama 4 Maverick, Gemini 2.0 Flash Lite, and Gemini 2.0 Flash. Claude Opus 4.6 is also available when you want a heavier Anthropic option. Reasoning is off by default to reduce interactive delay. OpenHalo still prefers strict JSON schema output and falls back to plain JSON mode if a model/provider rejects structured outputs. Vertex-only preview models are intentionally excluded from this picker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Reasoning (Optional)") {
                Toggle("Enable model reasoning", isOn: $appState.settings.reasoningEnabled)
                    .onChange(of: appState.settings.reasoningEnabled) { _, _ in saveSettings() }

                Picker("Reasoning Effort", selection: $appState.settings.reasoningEffort) {
                    ForEach(AppSettings.availableReasoningEfforts, id: \.self) { effort in
                        Text(effort.capitalized).tag(effort)
                    }
                }
                .disabled(!appState.settings.reasoningEnabled)
                .onChange(of: appState.settings.reasoningEffort) { _, _ in saveSettings() }

                Text(reasoningHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Capture") {
                HStack {
                    Text("JPEG Quality: \(Int(appState.settings.compressionQuality * 100))%")
                    Slider(
                        value: $appState.settings.compressionQuality,
                        in: 0.3...1.0,
                        step: 0.1
                    )
                    .onChange(of: appState.settings.compressionQuality) { _, _ in saveSettings() }
                }
            }

            Section("Permissions") {
                HStack {
                    Text("Screen Recording")
                    Spacer()
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            }

            Section("Shortcuts") {
                HStack {
                    Text("Toggle Chat Panel")
                    Spacer()
                    Text("Cmd + Shift + H")
                        .foregroundStyle(.secondary)
                        .font(.callout.monospaced())
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 470)
    }

    private func saveSettings() {
        appState.settings.save()
    }

    private var reasoningHelpText: String {
        if AppSettings.supportsReasoning(for: appState.settings.selectedModel) {
            return "This model supports OpenRouter reasoning controls, but OpenHalo keeps reasoning off by default to minimize latency. Turn it on only when you need slower, deeper analysis."
        }
        return "This model is already a standard low-latency model, so OpenHalo skips the reasoning parameter."
    }
}
