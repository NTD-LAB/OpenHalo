import Foundation

struct ChatMessage: Identifiable {
    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date
    let highlights: [HighlightRegion]

    enum Role {
        case user
        case assistant
        case system
    }

    init(role: Role, content: String, highlights: [HighlightRegion] = []) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.highlights = highlights
    }
}
