import Foundation

struct HighlightRegion: Identifiable {
    let id: String
    let label: String
    let screenRect: CGRect
    let stepNumber: Int?
    let elementType: String?
    let color: HighlightColor
    let showsLabel: Bool

    enum HighlightColor {
        case primary
        case secondary
        case warning
    }

    init(
        id: String,
        label: String,
        screenRect: CGRect,
        stepNumber: Int?,
        elementType: String?,
        color: HighlightColor,
        showsLabel: Bool = true
    ) {
        self.id = id
        self.label = label
        self.screenRect = screenRect
        self.stepNumber = stepNumber
        self.elementType = elementType
        self.color = color
        self.showsLabel = showsLabel
    }
}
