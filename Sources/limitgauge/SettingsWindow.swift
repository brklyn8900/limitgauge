import AppKit
import LimitGaugeCore
import ServiceManagement

/// The settings window: thresholds, notifications, icon, warning dot, launch at login.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let notifier: Notifier
    private let scopedLimitName: () -> String?
    private let onChange: () -> Void
    private var window: NSWindow?
    private var grid: NSGridView?

    private let scopedLabel = NSTextField(labelWithString: "Model this week")
    private let sessionField = NSTextField()
    private let weekField = NSTextField()
    private let scopedField = NSTextField()
    private let notifications = NSButton(checkboxWithTitle: "Notify when a limit passes its threshold", target: nil, action: nil)
    private let permissionNote = NSTextField(wrappingLabelWithString: "")
    private let openSystemSettings = NSButton(title: "Open Notification Settings", target: nil, action: nil)
    private let iconPopup = NSPopUpButton()
    private let dot = NSButton(checkboxWithTitle: "Show a red dot on the icon past a threshold", target: nil, action: nil)
    private let launch = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)

    /// `scopedLimitName` supplies the model name of the scoped weekly limit, e.g. "Fable",
    /// so the threshold row is labelled like the menu row.
    init(notifier: Notifier, scopedLimitName: @escaping () -> String?, onChange: @escaping () -> Void) {
        self.notifier = notifier
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

    // MARK: Layout

    private func makeWindow() -> NSWindow {
        let grid = NSGridView(views: [
            [label("Warning thresholds"), NSGridCell.emptyContentView],
            [label("Current session", secondary: true), percentRow(sessionField)],
            [label("This week", secondary: true), percentRow(weekField)],
            [scopedLabel, percentRow(scopedField)],
            [NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [label("Notifications"), notifications],
            [NSGridCell.emptyContentView, permissionNote],
            [NSGridCell.emptyContentView, openSystemSettings],
            [NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [label("Menu bar"), iconPopup],
            [NSGridCell.emptyContentView, dot],
            [NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [label("General"), launch],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 150
        grid.row(at: 4).height = 4
        grid.row(at: 8).height = 4
        grid.row(at: 11).height = 4
        scopedLabel.font = .systemFont(ofSize: 13)
        self.grid = grid

        for (field, selector) in [(sessionField, #selector(thresholdChanged)), (weekField, #selector(thresholdChanged)), (scopedField, #selector(thresholdChanged))] {
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
        iconPopup.target = self
        iconPopup.action = #selector(iconChanged)
        dot.target = self
        dot.action = #selector(dotChanged)
        launch.target = self
        launch.action = #selector(launchChanged)

        let content = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
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

    // MARK: State

    private func load() {
        let t = Settings.thresholds
        scopedLabel.stringValue = scopedLimitName().map { "\($0) this week" } ?? "Model this week"
        sessionField.integerValue = t.session
        weekField.integerValue = t.weeklyAll
        scopedField.integerValue = t.weeklyScoped
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
                : (status == .notDetermined ? "macOS will ask for permission on the first warning." : "")
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
        load()
        onChange()
    }

    private func clamp(_ v: Int) -> Int { min(max(v, 1), 100) }

    @objc private func notificationsChanged() {
        Settings.notificationsEnabled = notifications.state == .on
        if Settings.notificationsEnabled { notifier.requestAuthorizationIfEnabled() }
        refreshPermissionNote()
    }

    @objc private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
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

    func windowWillClose(_ notification: Notification) {
        // Commit a threshold that was typed but not confirmed with Return or Tab.
        window?.makeFirstResponder(nil)
    }
}
