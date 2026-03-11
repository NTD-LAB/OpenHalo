import SwiftUI

struct ChatPanelView: View {
    @ObservedObject var appState: AppState
    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Message history
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if appState.messages.isEmpty {
                            Text("Ask me about anything on your screen.\nFor example: \"Where is the Wi-Fi toggle?\"")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                                .padding()
                                .frame(maxWidth: .infinity)
                        }

                        ForEach(appState.messages) { message in
                            ChatBubbleView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: appState.messages.count) { _, _ in
                    if let lastMessage = appState.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input area
            HStack(spacing: 8) {
                TextField("Ask about your screen...", text: $inputText)
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .onSubmit { submitQuery() }
                    .disabled(appState.isProcessing)
                    .font(.body)

                if appState.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: submitQuery) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 340, minHeight: 400)
        .onAppear { isInputFocused = true }
    }

    private func submitQuery() {
        let query = inputText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !appState.isProcessing else { return }
        inputText = ""
        Task {
            await appState.submitQuery(query)
        }
    }
}
