import Carbon.HIToolbox
import Foundation

/// Registers a system-wide keyboard shortcut via Carbon's hot-key API — the same
/// permission-free mechanism menu bar utilities have used for global shortcuts since
/// long before Accessibility-gated event taps existed. Works even when the app has no
/// windows and isn't the frontmost app.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().handler()
                return noErr
            },
            1, &eventType, selfPtr, &eventHandler
        )
        guard installStatus == noErr else {
            print("Track: failed to install hot key event handler (status \(installStatus))")
            return nil
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x54524B31), id: 1) // 'TRK1'
        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registerStatus == noErr else {
            print("Track: failed to register global hot key (status \(registerStatus)) — it may already be in use by another app")
            if let eventHandler { RemoveEventHandler(eventHandler) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
