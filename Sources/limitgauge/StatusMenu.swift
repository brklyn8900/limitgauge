import AppKit
import LimitGaugeCore

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let service: UsageService
    private let codexService: UsageService
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let warningDot = WarningDotView()
    private let openSettings: () -> Void
    var onTrackingChange: ((Bool) -> Void)?
    private var isOpen = false
    private var redrawAtPastReset: Timer?
    private var wakeObserver: NSObjectProtocol?

    // The footer is built once and kept. Removing and re-adding standard items while the
    // menu is open leaves AppKit's layout stale: a blank row under Quit, and Settings
    // shifted out of the icon column.
    private let footerSeparator = NSMenuItem.separator()
    private let refreshItem = NSMenuItem()

    init(service: UsageService, codexService: UsageService, openSettings: @escaping () -> Void) {
        self.service = service
        self.codexService = codexService
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
            MainActor.assumeIsolated { self?.updateIconAndOpenRows() }
        }
        updateIconAndOpenRows()
    }

    func toggleMenu() {
        if isOpen { menu.cancelTracking() }
        else { item.button?.performClick(nil) }
    }

    func updateIconAndOpenRows() {
        updateIcon()
        if isOpen { rebuild() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        onTrackingChange?(true)
        rebuild()
        // Cached rows are already on screen; a stale snapshot refreshes behind them (ADR-0002).
        service.refresh(.menuOpen)
        codexService.refresh(.menuOpen)
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        onTrackingChange?(false)
    }

    private func addFooter() {
        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let quit = NSMenuItem(title: "Quit limitgauge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        [footerSeparator, refreshItem, .separator(), settings, quit].forEach(menu.addItem)
    }

    private func rebuild() {
        let now = Date()
        replaceContent(with: contentItems(now: now))

        refreshItem.view = MenuRows.action("Refresh", enabled: !service.isRefreshing && !codexService.isRefreshing) { [weak self] in
            self?.service.refresh(.refreshRow)
            self?.codexService.refresh(.refreshRow)
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
        if Settings.compactView { return compactItems(now: now) }
        var items: [NSMenuItem] = []
        let thresholds = Settings.thresholds

        items.append(providerHeader("Claude", service: service, now: now))
        items.append(.separator())

        if let problem = service.problem, service.snapshot == nil {
            items.append(MenuRows.message(problem.message))
        }

        if let snapshot = service.snapshot {
            if snapshot.sessionIsIdle {
                items.append(MenuRows.idleSession())
            } else if snapshot.sessionIsUnreadable {
                items.append(MenuRows.unreadableSession())
            }
            for limit in snapshot.limits {
                items.append(MenuRows.limit(limit, state: thresholds.state(of: limit, at: now), now: now, color: limit.kind == .weeklyScoped ? Settings.fableColor.color : Settings.claudeColor.color))
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
        items.append(.separator())
        items.append(providerHeader("Codex", service: codexService, now: now))
        if let snapshot = codexService.snapshot {
            for limit in snapshot.limits {
                items.append(MenuRows.limit(limit, state: Settings.codexThresholds.state(of: limit, at: now), now: now,
                                            color: Settings.codexColor.color))
            }
        }
        if let problem = codexService.problem {
            items.append(MenuRows.message(problem.message))
        }
        return items
    }

    private func compactItems(now: Date) -> [NSMenuItem] {
        let aggregate = service.snapshot?.limit(.weeklyAll)
        let fable = service.snapshot?.limits.first {
            $0.kind == .weeklyScoped && $0.scopeName?.caseInsensitiveCompare("Fable") == .orderedSame
        }
        return [
            CompactUsageRow.item(title: "Claude", readings: [
                .init(name: "All", limit: aggregate, color: Settings.claudeColor.color),
                .init(name: "Fable", limit: fable, color: Settings.fableColor.color)
            ], thresholds: Settings.thresholds, service: service, now: now),
            CompactUsageRow.item(title: "Codex", readings: [
                .init(name: "Weekly", limit: codexService.snapshot?.codexWeeklyLimit,
                      color: Settings.codexColor.color)
            ], thresholds: Settings.codexThresholds, service: codexService, now: now)
        ]
    }

    private func providerHeader(_ name: String, service: UsageService, now: Date) -> NSMenuItem {
        var detail = service.snapshot.map { "Updated \(ResetText.ago($0.fetchedAt, now: now))" } ?? "No data yet"
        if service.isRefreshing { detail += " · Updating…" }
        return MenuRows.keyValue(name, service.plan?.displayName ?? "", detail: detail, quiet: true)
    }

    @objc private func showSettings() {
        openSettings()
    }

    private func updateIcon() {
        item.button?.image = StatusIcon.image(for: Settings.icon)
        let now = Date()
        let thresholds = Settings.thresholds
        let claudeReset = service.snapshot.flatMap { thresholds.earliestPastReset(in: $0, at: now) }
        let codexReset = codexService.snapshot.flatMap { Settings.codexThresholds.earliestPastReset(in: $0, at: now) }
        let reset = [claudeReset, codexReset].compactMap { $0 }.min()
        warningDot.isHidden = !(reset != nil && Settings.showsWarningDot)

        redrawAtPastReset?.invalidate()
        redrawAtPastReset = nil
        guard let reset else { return }
        let timer = Timer(fire: reset, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIconAndOpenRows() }
        }
        RunLoop.main.add(timer, forMode: .common)
        redrawAtPastReset = timer
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
