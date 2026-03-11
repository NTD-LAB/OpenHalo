import SwiftUI

@main
struct OpenHaloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("OpenHalo", systemImage: "eye.circle") {
            Button("Show Chat (Cmd+Shift+H)") {
                appDelegate.toggleChatPanel()
            }

#if DEBUG
            Button("Test Overlay") {
                appDelegate.testOverlay()
            }
#endif

            Divider()

            Button("Settings...") {
                appDelegate.showSettings()
            }

            Button("Clear Highlights") {
                appDelegate.appState.clearHighlights()
                appDelegate.hideOverlayHighlights()
            }

            Divider()

            Button("Quit OpenHalo") {
                NSApplication.shared.terminate(nil)
            }
        }

        Settings {
            SettingsView(appState: appDelegate.appState)
        }
    }
}
