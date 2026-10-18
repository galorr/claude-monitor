import AppKit
import Carbon.HIToolbox
import ClaudeMonitorCore

/// One global shortcut via Carbon's RegisterEventHotKey: works from any app and needs no
/// Accessibility permission (unlike a global NSEvent monitor).
@MainActor
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: @MainActor () -> Void

    init(onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
    }

    /// nil turns it off. Returns false if the shortcut could not be registered (taken).
    @discardableResult
    func register(_ hotkey: Hotkey?) -> Bool {
        unregister()
        guard let hotkey, hotkey.isValid else { return hotkey == nil }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x434D_4E54), id: 1)  // "CMNT"
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers application events on the main thread.
            MainActor.assumeIsolated { manager.onPress() }
            return noErr
        }, 1, &spec, me, &handlerRef)
    }

    /// Builds a Hotkey from a key press (for the recorder in Settings).
    static func hotkey(from event: NSEvent) -> Hotkey {
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers |= Hotkey.command }
        if flags.contains(.shift) { modifiers |= Hotkey.shift }
        if flags.contains(.option) { modifiers |= Hotkey.option }
        if flags.contains(.control) { modifiers |= Hotkey.control }
        return Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: label(for: event))
    }

    private static func label(for event: NSEvent) -> String {
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = named[Int(event.keyCode)] { return name }
        // The character the key types without modifiers, on the current layout.
        let chars = event.charactersIgnoringModifiers ?? ""
        return chars.isEmpty ? "#\(event.keyCode)" : chars.uppercased()
    }
}
