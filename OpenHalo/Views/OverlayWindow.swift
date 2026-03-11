import AppKit

final class OverlayWindow: NSWindow {
    private let overlayView: OverlayDrawingView

    init(screen: NSScreen) {
        overlayView = OverlayDrawingView(
            frame: NSRect(origin: .zero, size: screen.frame.size)
        )

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
        ]
        self.isReleasedWhenClosed = false
        self.contentView = overlayView
        self.orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        displayIfNeeded()
    }

    func setHighlights(_ regions: [HighlightRegion]) {
        print("[OpenHalo] setHighlights: \(regions.count) regions, windowFrame=\(frame)")
        for r in regions {
            print("[OpenHalo]   rect=\(r.screenRect) label=\"\(r.label)\"")
        }

        overlayView.frame = NSRect(origin: .zero, size: frame.size)
        overlayView.highlights = regions
        overlayView.needsDisplay = true
        displayIfNeeded()

        print("[OpenHalo] setHighlights done: overlayView.frame=\(overlayView.frame)")
    }
}
