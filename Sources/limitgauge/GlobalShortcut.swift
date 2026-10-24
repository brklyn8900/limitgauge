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
    private var registrationID: UInt32 = 0
    private var keyIsDown = false
    private var isMenuTracking = false
    private var menuObserver: CFRunLoopObserver?
    private var localMonitor: Any?
    private let onPress: @MainActor () -> Void
    private(set) var problem: String?
    private static let signature: OSType = 0x4C474155 // LGAU

    init(onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard Thread.isMainThread, let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x4C474155 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            let id = identifier.id
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            // A Task can remain queued until NSMenu's nested tracking loop exits, then reopen
            // a menu just dismissed with Escape. Carbon delivers this callback on the main thread.
            return MainActor.assumeIsolated { owner.handleHotKey(id: id, pressed: pressed) }
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr { problem = "Could not enable keyboard shortcuts (\(status))." }
    }

    private func handleHotKey(id: UInt32, pressed: Bool) -> OSStatus {
        guard hotKey != nil, !isMenuTracking, id == registrationID else { return OSStatus(eventNotHandledErr) }
        if pressed {
            keyIsDown = true
        } else if keyIsDown {
            keyIsDown = false
            onPress()
        }
        return noErr
    }

    @discardableResult
    func apply(_ shortcut: KeyboardShortcut?) -> String? {
        guard handler != nil else { return problem ?? "Keyboard shortcuts are unavailable." }
        if let shortcut, let active, shortcut.keyCode == active.keyCode && shortcut.modifiers == active.modifiers,
           hotKey != nil || isMenuTracking {
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
        // Acquire the replacement first: a conflict must leave the current shortcut working.
        var replacement: EventHotKeyRef?
        let nextID = registrationID &+ 1
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                        EventHotKeyID(signature: Self.signature, id: nextID),
                                        GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &replacement)
        guard status == noErr else {
            problem = registrationProblem(status)
            return problem
        }
        suspend()
        hotKey = replacement
        registrationID = nextID
        active = shortcut
        if isMenuTracking { unregisterHotKey() }
        problem = nil
        return nil
    }

    /// Carbon reserves the chord even while NSMenu suppresses hotkey delivery. Temporarily
    /// release it and handle only that chord locally until our status menu closes.
    func setMenuTracking(_ tracking: Bool) {
        guard tracking != isMenuTracking else { return }
        isMenuTracking = tracking
        keyIsDown = false
        if tracking {
            unregisterHotKey()
            startMenuMonitor()
        } else {
            stopMenuMonitor()
            if let active { _ = apply(active) }
        }
    }

    private func matchesMenuEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp,
              isMenuTracking, let active, UInt32(event.keyCode) == active.keyCode else { return false }
        if event.type == .keyUp { return keyIsDown }
        guard event.type == .keyDown, let chord = KeyboardShortcut(event: event) else { return false }
        return chord.modifiers == active.modifiers
    }

    /// Returns whether the event belongs to the menu shortcut. Toggle on release so holding
    /// the chord never repeatedly opens/closes the menu, even across registration changes.
    func handleMenuEvent(_ event: NSEvent) -> Bool {
        guard matchesMenuEvent(event) else { return false }
        if event.type == .keyDown {
            if !event.isARepeat { keyIsDown = true }
        } else {
            keyIsDown = false
            onPress()
        }
        return true
    }

    private func startMenuMonitor() {
        // Menu tracking consumes ordinary keys before AppKit's local monitor sees them.
        // Inspect only the queue head: searching for keys past mouse events stalls tracking.
        menuObserver = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeSources.rawValue, true, 0) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                while self.isMenuTracking,
                      let event = NSApp.nextEvent(matching: .any, until: nil, inMode: .eventTracking, dequeue: false),
                      self.matchesMenuEvent(event),
                      let dequeued = NSApp.nextEvent(matching: .any, until: nil, inMode: .eventTracking, dequeue: true) {
                    _ = self.handleMenuEvent(dequeued)
                }
            }
        }
        if let menuObserver {
            CFRunLoopAddObserver(CFRunLoopGetMain(), menuObserver, CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        }
        // Function keys can instead reach NSApplication.sendEvent; cover that path too.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleMenuEvent(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func stopMenuMonitor() {
        if let menuObserver { CFRunLoopObserverInvalidate(menuObserver) }
        menuObserver = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
    }

    private func unregisterHotKey() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func registrationProblem(_ status: OSStatus) -> String {
        status == eventHotKeyExistsErr
            ? "That shortcut is already in use. Try another combination."
            : "macOS could not register that shortcut (\(status)). Try another combination."
    }

    /// Temporarily release the chord so the recorder can capture that same chord too.
    func suspend() {
        unregisterHotKey()
        active = nil
        keyIsDown = false
    }

    func stop() {
        suspend()
        stopMenuMonitor()
        isMenuTracking = false
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
