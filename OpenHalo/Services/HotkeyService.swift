import Carbon.HIToolbox
import AppKit

final class HotkeyService {
    private var hotKeyRef: EventHotKeyRef?
    private let onTrigger: () -> Void

    // Store the callback so it persists for the C function pointer
    // nonisolated(unsafe) because this is only accessed from main thread via DispatchQueue.main
    nonisolated(unsafe) private static var sharedCallback: (() -> Void)?

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    func register() {
        HotkeyService.sharedCallback = onTrigger

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x4F484C4F) // "OHLO"
        hotKeyID.id = 1

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                DispatchQueue.main.async {
                    HotkeyService.sharedCallback?()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )

        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        let keyCode: UInt32 = UInt32(kVK_ANSI_H)

        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    deinit {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }
}
