import AppKit
import Carbon

struct KeyboardShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    var isValid: Bool {
        let required = UInt32(cmdKey | controlKey | optionKey)
        let allowed = required | UInt32(shiftKey)
        return keyCode <= 127 && modifiers & required != 0 && modifiers & ~allowed == 0 && !keyLabel.isEmpty
    }

    var title: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Plain typing keys should never become global shortcuts.
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        let special: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
            115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
            100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
            107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
        guard let label = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased(),
              !label.isEmpty else { return nil }
        keyCode = UInt32(event.keyCode)
        keyLabel = label
        var bits: UInt32 = 0
        if flags.contains(.command) { bits |= UInt32(cmdKey) }
        if flags.contains(.control) { bits |= UInt32(controlKey) }
        if flags.contains(.option) { bits |= UInt32(optionKey) }
        if flags.contains(.shift) { bits |= UInt32(shiftKey) }
        modifiers = bits
    }
}

/// Registers only the chosen chord, without a global keyboard monitor or Accessibility access.
/// AppDelegate owns this for the app lifetime and stops it before termination.
@MainActor
final class GlobalShortcut {
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var active: KeyboardShortcut?
    private let onPress: @MainActor () -> Void
    private(set) var problem: String?
    private static let signature: OSType = 0x4C474155 // LGAU

    init(onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x4C474155, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak owner] in
                guard let owner, owner.hotKey != nil else { return }
                owner.onPress()
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr { problem = "Could not enable keyboard shortcuts (\(status))." }
    }

    @discardableResult
    func apply(_ shortcut: KeyboardShortcut?) -> String? {
        guard handler != nil else { return problem ?? "Keyboard shortcuts are unavailable." }
        if let shortcut, let active, shortcut.keyCode == active.keyCode && shortcut.modifiers == active.modifiers {
            problem = nil
            return nil
        }
        guard let shortcut else {
            suspend()
            problem = nil
            return nil
        }
        guard shortcut.isValid else {
            problem = "Choose a key with Command, Control, or Option."
            return problem
        }
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                        EventHotKeyID(signature: Self.signature, id: 1),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &replacement)
        guard status == noErr else {
            problem = status == eventHotKeyExistsErr
                ? "That shortcut is already in use. Try another combination."
                : "macOS could not register that shortcut (\(status)). Try another combination."
            return problem
        }
        suspend()
        hotKey = replacement
        active = shortcut
        problem = nil
        return nil
    }

    /// Temporarily release the chord so the recorder can capture that same chord too.
    func suspend() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        active = nil
    }

    func stop() {
        suspend()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
