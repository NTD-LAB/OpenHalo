import AppKit

final class OverlayDrawingView: NSView {
    var highlights: [HighlightRegion] = [] {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.clear.setFill()
        dirtyRect.fill()

        for region in highlights {
            draw(region: region)
        }
    }

    private func draw(region: HighlightRegion) {
        let rect = region.screenRect
        let color = strokeColor(for: region.color)

        let fillPath = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        color.withAlphaComponent(0.16).setFill()
        fillPath.fill()

        color.setStroke()
        fillPath.lineWidth = 3
        fillPath.stroke()

        guard region.showsLabel, !region.label.isEmpty else { return }

        let label = region.stepNumber.map { "\($0). \(region.label)" } ?? region.label
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]

        let textSize = (label as NSString).size(withAttributes: attributes)
        let labelRect = CGRect(
            x: rect.minX,
            y: max(rect.minY - 28, 0),
            width: min(textSize.width + 16, 320),
            height: 24
        )

        let labelPath = NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4)
        color.withAlphaComponent(0.92).setFill()
        labelPath.fill()

        let textRect = labelRect.insetBy(dx: 8, dy: 4)
        (label as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private func strokeColor(for color: HighlightRegion.HighlightColor) -> NSColor {
        switch color {
        case .primary:
            return .systemBlue
        case .secondary:
            return .systemGreen
        case .warning:
            return .systemOrange
        }
    }
}
