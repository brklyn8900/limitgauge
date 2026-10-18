import AppKit
import LimitGaugeCore

/// The menu bar item and its dropdown. Rows are rebuilt from the service state whenever
/// the menu opens or the service changes while it is open.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let service: UsageService
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let warningDot = WarningDotView()
    private let openSettings: () -> Void
    private var isOpen = false

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
        update()
    }

    /// Refreshes the icon, and the rows if the menu is showing.
    func update() {
        updateIcon()
        if isOpen { rebuild() }
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        rebuild()
        // Cached rows are already on screen; a stale snapshot refreshes behind them (ADR-0002).
        service.refreshIfStale()
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
    }

    // MARK: Rows

    private func rebuild() {
        menu.removeAllItems()
        let now = Date()
        let thresholds = Settings.thresholds

        if let plan = service.plan {
            menu.addItem(MenuRows.keyValue("Plan", plan.displayName))
            menu.addItem(.separator())
        }

        if let problem = service.problem, service.snapshot == nil {
            menu.addItem(MenuRows.message(problem.message))
        }

        if let snapshot = service.snapshot {
            for limit in snapshot.limits {
                menu.addItem(MenuRows.limit(limit, now: now, past: thresholds.isPast(limit)))
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
                menu.addItem(.separator())
                extras.forEach(menu.addItem)
            }

            if let breakdown = snapshot.weeklyBreakdown, !breakdown.isEmpty {
                menu.addItem(.separator())
                menu.addItem(MenuRows.breakdown(breakdown))
            }

            if let problem = service.problem {
                menu.addItem(.separator())
                menu.addItem(MenuRows.message(problem.message))
            }
        }

        menu.addItem(.separator())
        let status: String
        if service.isRefreshing {
            status = "Updating\u{2026}"
        } else if let snapshot = service.snapshot {
            status = "Updated \(ResetText.ago(snapshot.fetchedAt, now: now))"
        } else {
            status = "No data yet"
        }
        let updated = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        updated.isEnabled = false
        menu.addItem(updated)

        menu.addItem(MenuRows.action("Refresh", enabled: !service.isRefreshing) { [weak self] in
            self?.service.refresh()
        })

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(withTitle: "Quit limitgauge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func showSettings() {
        openSettings()
    }

    // MARK: Icon

    private func updateIcon() {
        item.button?.image = StatusIcon.image(for: Settings.icon)
        let past = service.snapshot.map { Settings.thresholds.anyPast(in: $0) } ?? false
        warningDot.isHidden = !(past && Settings.showsWarningDot)
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
