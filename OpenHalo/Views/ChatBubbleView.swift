import SwiftUI

struct ChatBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(backgroundColor)
                    .foregroundStyle(foregroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if !message.highlights.isEmpty {
                    Text("\(message.highlights.count) region(s) highlighted")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user:
            return .blue
        case .assistant:
            return Color(.controlBackgroundColor)
        case .system:
            return Color(.controlBackgroundColor).opacity(0.5)
        }
    }

    private var foregroundColor: Color {
        switch message.role {
        case .user:
            return .white
        case .assistant, .system:
            return .primary
        }
    }
}
