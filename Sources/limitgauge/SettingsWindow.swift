import AppKit
import LimitGaugeCore
import ServiceManagement

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let notifier: Notifier
    private let shortcutRecorder: ShortcutRecorder
    private let scopedLimitName: () -> String?
    private let onChange: () -> Void
    private var window: NSWindow?
    private var grid: NSGridView?

    private let scopedLabel = NSTextField(labelWithString: "Model this week")
    private let sessionField = NSTextField()
    private let weekField = NSTextField()
    private let scopedField = NSTextField()
    private let codexField = NSTextField()
    private let notifications = NSButton(checkboxWithTitle: "Notify when a limit passes its threshold", target: nil, action: nil)
    private let permissionNote = NSTextField(wrappingLabelWithString: "")
    private let openSystemSettings = NSButton(title: "Open Notification Settings", target: nil, action: nil)
    private let iconPopup = NSPopUpButton()
    private let viewMode = NSPopUpButton()
    private let dot = NSButton(checkboxWithTitle: "Show a red dot on the icon past a threshold", target: nil, action: nil)
    private lazy var claudeColors = ColorPicker(label: "Claude color", selection: Settings.claudeColor) { [weak self] color in
        Settings.claudeColor = color
        self?.onChange()
    }
    private lazy var fableColors = ColorPicker(label: "Fable color", selection: Settings.fableColor) { [weak self] color in
        Settings.fableColor = color
        self?.onChange()
    }
    private lazy var codexColors = ColorPicker(label: "Codex color", selection: Settings.codexColor) { [weak self] color in
        Settings.codexColor = color
        self?.onChange()
    }
    private let launch = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)

    init(notifier: Notifier, shortcut: GlobalShortcut, scopedLimitName: @escaping () -> String?, onChange: @escaping () -> Void) {
        self.notifier = notifier
        self.shortcutRecorder = ShortcutRecorder(shortcut: shortcut)
        self.scopedLimitName = scopedLimitName
        self.onChange = onChange
        super.init()
    }

    func show() {
        if window == nil { window = makeWindow() }
        load()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let grid = NSGridView(views: [
            [label("View"), viewMode],
            [NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [label("Claude thresholds"), NSGridCell.emptyContentView],
            [label("Current session", secondary: true), percentRow(sessionField)],
            [label("This week", secondary: true), percentRow(weekField)],
            [scopedLabel, percentRow(scopedField)],
            [label("Codex limits"), percentRow(codexField)],
            [NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [label("Notifications"), notifications],
            [NSGridCell.emptyContentView, permissionNote],
            [NSGridCell.emptyContentView, openSystemSettings],
            [NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [label("Menu bar"), iconPopup],
            [NSGridCell.emptyContentView, dot],
            [NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [label("Claude color"), claudeColors],
            [label("Fable color"), fableColors],
            [label("Codex color"), codexColors],
            [NSGridCell.emptyContentView, label("Warnings always turn red.", secondary: true)],
            [NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [label("Menu shortcut"), shortcutRecorder],
            [label("General"), launch],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 150
        for row in [1, 7, 11, 14, 19] { grid.row(at: row).height = 4 }
        scopedLabel.font = .systemFont(ofSize: 13)
        self.grid = grid

        for (field, selector) in [(sessionField, #selector(thresholdChanged)), (weekField, #selector(thresholdChanged)), (scopedField, #selector(thresholdChanged)), (codexField, #selector(thresholdChanged))] {
            field.target = self
            field.action = selector
        }
        notifications.target = self
        notifications.action = #selector(notificationsChanged)
        openSystemSettings.target = self
        openSystemSettings.action = #selector(openNotificationSettings)
        openSystemSettings.bezelStyle = .accessoryBarAction
        permissionNote.font = .systemFont(ofSize: 11)
        permissionNote.textColor = .secondaryLabelColor
        permissionNote.preferredMaxLayoutWidth = 300
        for icon in Settings.Icon.allCases {
            iconPopup.addItem(withTitle: icon.title)
            iconPopup.lastItem?.representedObject = icon.rawValue
            iconPopup.lastItem?.image = NSImage(systemSymbolName: icon.rawValue, accessibilityDescription: nil)
        }
        viewMode.addItems(withTitles: ["Detailed", "Compact"])
        viewMode.target = self
        viewMode.action = #selector(viewModeChanged)
        iconPopup.target = self
        iconPopup.action = #selector(iconChanged)
        dot.target = self
        dot.action = #selector(dotChanged)
        launch.target = self
        launch.action = #selector(launchChanged)

        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let version = NSTextField(labelWithString: "limitgauge \(shortVersion ?? "dev")")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .tertiaryLabelColor
        version.alignment = .right

        let content = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        version.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        content.addSubview(version)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            version.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            version.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            version.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "limitgauge Settings"
        w.contentView = content
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(content.fittingSize)
        return w
    }

    private func label(_ text: String, secondary: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = secondary ? .systemFont(ofSize: 13) : .systemFont(ofSize: 13, weight: .semibold)
        return l
    }

    private func percentRow(_ field: NSTextField) -> NSView {
        field.formatter = {
            let f = NumberFormatter()
            f.minimum = 1
            f.maximum = 100
            f.allowsFloats = false
            return f
        }()
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let row = NSStackView(views: [field, NSTextField(labelWithString: "%")])
        row.orientation = .horizontal
        row.spacing = 4
        return row
    }

    private func load() {
        let t = Settings.thresholds
        shortcutRecorder.load()
        scopedLabel.stringValue = scopedLimitName().map { "\($0) this week" } ?? "Model this week"
        sessionField.integerValue = t.session
        weekField.integerValue = t.weeklyAll
        scopedField.integerValue = t.weeklyScoped
        codexField.integerValue = Settings.codexWarningThreshold
        viewMode.selectItem(at: Settings.compactView ? 1 : 0)
        claudeColors.selection = Settings.claudeColor
        fableColors.selection = Settings.fableColor
        codexColors.selection = Settings.codexColor
        notifications.state = Settings.notificationsEnabled ? .on : .off
        iconPopup.selectItem(at: Settings.Icon.allCases.firstIndex(of: Settings.icon) ?? 0)
        dot.state = Settings.showsWarningDot ? .on : .off
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        refreshPermissionNote()
    }

    private func refreshPermissionNote() {
        Task { [weak self] in
            guard let self else { return }
            let status = await notifier.authorizationStatus()
            let denied = status == .denied
            permissionNote.stringValue = denied
                ? "Notifications are turned off for limitgauge in System Settings."
                : (status == .notDetermined
                    ? (Settings.notificationsEnabled
                        ? "macOS asks for permission when limitgauge launches."
                        : "macOS asks for permission when you turn notifications on.")
                    : "")
            // Hide the rows, not just the views, so the grid gives their space back.
            grid?.cell(for: permissionNote)?.row?.isHidden = permissionNote.stringValue.isEmpty
            grid?.cell(for: openSystemSettings)?.row?.isHidden = !denied
            window?.setContentSize(window?.contentView?.fittingSize ?? .zero)
        }
    }

    @objc private func thresholdChanged() {
        Settings.thresholds = WarningThresholds(
            session: clamp(sessionField.integerValue),
            weeklyAll: clamp(weekField.integerValue),
            weeklyScoped: clamp(scopedField.integerValue)
        )
        Settings.codexWarningThreshold = clamp(codexField.integerValue)
        load()
        onChange()
    }

    private func clamp(_ v: Int) -> Int { min(max(v, 1), 100) }

    @objc private func notificationsChanged() {
        Settings.notificationsEnabled = notifications.state == .on
        Task {
            if Settings.notificationsEnabled { await notifier.requestAuthorizationIfEnabled() }
            // A warning that was due while notifications were off goes out now (ADR-0005).
            onChange()
            refreshPermissionNote()
        }
    }

    @objc private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func viewModeChanged() {
        Settings.compactView = viewMode.indexOfSelectedItem == 1
        onChange()
    }

    @objc private func iconChanged() {
        if let raw = iconPopup.selectedItem?.representedObject as? String, let icon = Settings.Icon(rawValue: raw) {
            Settings.icon = icon
        }
        onChange()
    }

    @objc private func dotChanged() {
        Settings.showsWarningDot = dot.state == .on
        onChange()
    }

    @objc private func launchChanged() {
        do {
            if launch.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("launch at login: \(error.localizedDescription, privacy: .public)")
            launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        shortcutRecorder.cancelRecording()
    }

    func windowWillClose(_ notification: Notification) {
        shortcutRecorder.cancelRecording()
        // Commit a threshold that was typed but not confirmed with Return or Tab.
        window?.makeFirstResponder(nil)
    }
}
