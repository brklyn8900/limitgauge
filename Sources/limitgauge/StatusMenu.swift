import AppKit
import LimitGaugeCore

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let service: UsageService
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let warningDot = WarningDotView()
    private let openSettings: () -> Void
    private var isOpen = false
    /// Redraws the icon when a past limit resets, which turns the dot off without a fetch.
    private var dotTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    // The footer is built once and kept. Removing and re-adding standard items while the
    // menu is open leaves AppKit's layout stale: a blank row under Quit, and Settings
    // shifted out of the icon column.
    private let footerSeparator = NSMenuItem.separator()
    private let updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let refreshItem = NSMenuItem()

    init(service: UsageService, openSettings: @escaping () -> Void) {
        self.service = service
        self.openSettings = openSettings
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        if let button = item.button {
            button.addSubview(warningDot)
            warningDot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                warningDot.widthAnchor.constraint(equalToConstant: 6),
                warningDot.heightAnchor.constraint(equalToConstant: 6),
                warningDot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
                warningDot.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -3),
            ])
        }
        addFooter()
        // A timer's clock pauses during sleep, so a reset that passed during sleep is redrawn
        // on wake rather than a sleep's length late.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    func update() {
        updateIcon()
        if isOpen { rebuild() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        rebuild()
        // Cached rows are already on screen; a stale snapshot refreshes behind them (ADR-0002).
        service.refresh(.menuOpen)
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
    }

    private func addFooter() {
        updatedItem.isEnabled = false
        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let quit = NSMenuItem(title: "Quit limitgauge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        [footerSeparator, updatedItem, refreshItem, .separator(), settings, quit].forEach(menu.addItem)
    }

    private func rebuild() {
        let now = Date()
        replaceContent(with: contentItems(now: now))

        if service.isRefreshing {
            updatedItem.title = "Updating\u{2026}"
        } else if let snapshot = service.snapshot {
            updatedItem.title = "Updated \(ResetText.ago(snapshot.fetchedAt, now: now))"
        } else {
            updatedItem.title = "No data yet"
        }
        refreshItem.view = MenuRows.action("Refresh", enabled: !service.isRefreshing) { [weak self] in
            self?.service.refresh(.refreshRow)
        }
    }

    /// Swaps the rows above the footer. When the new rows have the same shape as the old,
    /// each item stays in place and only its view changes, so an open menu keeps its items.
    private func replaceContent(with items: [NSMenuItem]) {
        let current = Array(menu.items.prefix { $0 !== footerSeparator })
        let sameShape = current.count == items.count
            && zip(current, items).allSatisfy { $0.isSeparatorItem == $1.isSeparatorItem }
        if sameShape {
            for (old, new) in zip(current, items) where !old.isSeparatorItem {
                let view = new.view
                new.view = nil
                old.view = view
            }
            return
        }
        current.forEach(menu.removeItem)
        for (index, item) in items.enumerated() {
            menu.insertItem(item, at: index)
        }
    }

    private func contentItems(now: Date) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let thresholds = Settings.thresholds

        if let plan = service.plan {
            items.append(MenuRows.keyValue("Plan", plan.displayName, quiet: true))
            items.append(.separator())
        }

        if let problem = service.problem, service.snapshot == nil {
            items.append(MenuRows.message(problem.message))
        }

        if let snapshot = service.snapshot {
            if snapshot.sessionIsIdle {
                items.append(MenuRows.idleSession())
            }
            for limit in snapshot.limits {
                items.append(MenuRows.limit(limit, state: thresholds.state(of: limit, at: now), now: now))
            }

            var extras: [NSMenuItem] = []
            if let cloud = snapshot.cloudCredits {
                let value = "\(Money.format(cloud.remainingDollars)) of \(Money.format(cloud.limitDollars)) left"
                let detail = cloud.resetsAt.map { ResetText.expires(at: $0) }
                extras.append(MenuRows.keyValue("Cloud session credits", value, detail: detail))
            }
            if let credits = snapshot.usageCredits {
                var value = "\(Money.format(credits.used, currency: credits.currency)) used"
                if let balance = credits.balance {
                    value += ", \(Money.format(balance, currency: credits.currency)) balance"
                }
                extras.append(MenuRows.keyValue("Usage credits", value))
            }
            if let resets = snapshot.limitResets {
                let value = resets.grants.isEmpty ? "No resets right now" : resets.grants.joined(separator: ", ")
                extras.append(MenuRows.keyValue("Limit resets", value))
            }
            if !extras.isEmpty {
                items.append(.separator())
                items.append(contentsOf: extras)
            }

            if let breakdown = snapshot.weeklyBreakdown, !breakdown.isEmpty {
                items.append(.separator())
                items.append(MenuRows.breakdown(breakdown))
            }

            if let problem = service.problem {
                items.append(.separator())
                items.append(MenuRows.message(problem.message))
            }
        }
        return items
    }

    @objc private func showSettings() {
        openSettings()
    }

    private func updateIcon() {
        item.button?.image = StatusIcon.image(for: Settings.icon)
        let now = Date()
        let thresholds = Settings.thresholds
        let reset = service.snapshot.flatMap { thresholds.earliestPastReset(in: $0, at: now) }
        warningDot.isHidden = !(reset != nil && Settings.showsWarningDot)

        dotTimer?.invalidate()
        dotTimer = nil
        guard let reset else { return }
        // update(), not updateIcon(): an open menu must stop showing the limit red with the dot.
        let timer = Timer(fire: reset, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dotTimer = timer
    }
}

/// The red dot drawn over the status item while a limit is past its threshold. A separate
/// view keeps the icon itself a template image, so it follows the menu bar appearance.
final class WarningDotView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

enum Money {
    static func format(_ amount: Decimal, currency: String = "USD") -> String {
        amount.formatted(.currency(code: currency).precision(.fractionLength(0...2)))
    }
}
