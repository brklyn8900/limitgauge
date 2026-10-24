import AppKit

@MainActor
final class ShortcutRecorder: NSStackView {
    private let shortcut: GlobalShortcut
    private let record = NSButton(title: "Record shortcut…", target: nil, action: nil)
    private let clear = NSButton(title: "Clear", target: nil, action: nil)
    private let note = NSTextField(wrappingLabelWithString: "")
    private var monitor: Any?

    init(shortcut: GlobalShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        let buttons = NSStackView(views: [record, clear])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        record.target = self
        record.action = #selector(startRecording)
        record.setAccessibilityLabel("Record shortcut to toggle the usage menu")
        clear.target = self
        clear.action = #selector(clearShortcut)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 280
        addArrangedSubview(buttons)
        addArrangedSubview(note)
        load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func load() {
        guard monitor == nil else { return }
        record.title = Settings.keyboardShortcut?.title ?? "Record shortcut…"
        clear.isEnabled = Settings.keyboardShortcut != nil
        setNote(shortcut.problem ?? "Toggles the menu from any app. Click to record.")
    }

    @objc private func startRecording() {
        if monitor != nil { cancelRecording(); return }
        shortcut.suspend()
        record.title = "Press your shortcut…"
        setNote("Use ⌘, ⌃, or ⌥ with a key. Esc cancels; Delete clears.")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return false }
                return self.capture(event) == nil
            }
            return consumed ? nil : event
        }
    }

    private func capture(_ event: NSEvent) -> NSEvent? {
        guard !event.isARepeat else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty && event.keyCode == 53 { cancelRecording(); return nil }
        if modifiers.isEmpty && (event.keyCode == 51 || event.keyCode == 117) { clearShortcut(); return nil }
        guard let value = KeyboardShortcut(event: event) else {
            setNote("Include ⌘, ⌃, or ⌥ with the key. Esc cancels.")
            return nil
        }
        if let problem = shortcut.apply(value) {
            // A rejected replacement ends recording and immediately restores the saved chord.
            finishRecording()
            let restoreProblem = shortcut.apply(Settings.keyboardShortcut)
            load()
            setNote(restoreProblem.map { "\(problem) Previous shortcut could not be restored: \($0)" } ?? problem)
            return nil
        }
        Settings.keyboardShortcut = value
        finishRecording()
        load()
        return nil
    }

    @objc private func clearShortcut() {
        finishRecording()
        shortcut.apply(nil)
        Settings.keyboardShortcut = nil
        load()
    }

    func cancelRecording() {
        guard monitor != nil else { return }
        finishRecording()
        shortcut.apply(Settings.keyboardShortcut)
        load()
    }

    private func setNote(_ text: String) {
        note.stringValue = text
        if let window, let content = window.contentView {
            window.setContentSize(content.fittingSize)
        }
    }

    private func finishRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
