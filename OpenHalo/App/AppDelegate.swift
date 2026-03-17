import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var chatPanel: NSPanel?
    private var overlayWindows: [OverlayWindow] = []
    private var hotkeyService: HotkeyService?
    private var settingsWindow: NSWindow?

    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wire up the highlight callback so AppState can trigger overlays
        appState.onShowHighlights = { [weak self] screen, regions in
            self?.showOverlayHighlights(on: screen, regions: regions)
        }

        hotkeyService = HotkeyService { [weak self] in
            self?.toggleChatPanel()
        }
        hotkeyService?.register()

        // Auto-show chat panel on launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showChatPanel()
        }

        if let displayID = mainDisplayID() {
            let screenCaptureService = appState.screenCaptureService
            Task.detached(priority: .background) {
                guard await screenCaptureService.checkPermission() else {
                    return
                }

                do {
                    try await screenCaptureService.ensureRunning(for: displayID)
                } catch {
                    print("[OpenHalo] Failed to prewarm screen stream: \(error.localizedDescription)")
                }
            }
        }
    }

    func toggleChatPanel() {
        if let panel = chatPanel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            showChatPanel()
        }
    }

    func showChatPanel() {
        if chatPanel == nil {
            createChatPanel()
        }
        chatPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView(appState: appState)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 450, height: 350),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "OpenHalo Settings"
            window.contentView = NSHostingView(rootView: settingsView)
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Test overlay with a hardcoded rectangle — for debugging only
    func testOverlay() {
        print("[OpenHalo] === TEST OVERLAY ===")
        let testRegions = [
            HighlightRegion(
                id: "test1",
                label: "TEST HIGHLIGHT",
                screenRect: CGRect(x: 100, y: 100, width: 300, height: 200),
                stepNumber: 1,
                elementType: "button",
                color: .primary
            ),
            HighlightRegion(
                id: "test2",
                label: "Bottom-right test",
                screenRect: CGRect(x: 500, y: 400, width: 250, height: 150),
                stepNumber: 2,
                elementType: "button",
                color: .secondary
            ),
        ]
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            showOverlayHighlights(on: screen, regions: testRegions)
        }
    }

    func showOverlayHighlights(on screen: NSScreen, regions: [HighlightRegion]) {
        hideOverlayHighlights()

        print("[OpenHalo] ✅ showOverlayHighlights called with \(regions.count) regions")
        print("[OpenHalo]   Screen frame: \(screen.frame)")
        print("[OpenHalo]   Screen visibleFrame: \(screen.visibleFrame)")
        for region in regions {
            print("[OpenHalo]   - \"\(region.label)\": rect=\(region.screenRect)")
        }

        let overlay = OverlayWindow(screen: screen)
        overlay.setHighlights(regions)
        overlay.orderFrontRegardless()
        overlayWindows.append(overlay)

        print("[OpenHalo] ✅ Overlay window created: frame=\(overlay.frame), isVisible=\(overlay.isVisible), level=\(overlay.level.rawValue)")
        print("[OpenHalo]   contentView: \(String(describing: overlay.contentView))")
        print("[OpenHalo]   subviews count: \(overlay.contentView?.subviews.count ?? -1)")
    }

    func hideOverlayHighlights() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
    }

    private func createChatPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "OpenHalo"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 400)

        let chatView = ChatPanelView(appState: appState)
        panel.contentView = NSHostingView(rootView: chatView)

        // Position at right side of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelFrame = panel.frame
            let x = screenFrame.maxX - panelFrame.width - 20
            let y = screenFrame.maxY - panelFrame.height - 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        chatPanel = panel
    }

    private func mainDisplayID() -> CGDirectDisplayID? {
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        guard
            let screen = targetScreen,
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return nil
        }

        return CGDirectDisplayID(screenNumber.uint32Value)
    }
}
