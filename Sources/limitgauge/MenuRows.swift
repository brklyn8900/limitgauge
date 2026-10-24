import AppKit
import LimitGaugeCore

@MainActor
enum MenuRows {
    static let width: CGFloat = 300
    private static let inset: CGFloat = 14

    /// Title, percent, bar and reset time. A limit whose window has reset since the fetch
    /// shows a dash, an empty bar and no red: its value is unknown (ADR-0005 point 4).
    static func limit(_ limit: RateLimit, state: LimitState, now: Date, color: NSColor = .controlAccentColor) -> NSMenuItem {
        switch state {
        case .below, .past:
            gauge(title: limit.title, percent: limit.percent,
                  caption: ResetText.weeklyPacing(limit, now: now) ?? ResetText.resets(at: limit.resetsAt, now: now),
                  past: state == .past, color: color,
                  tooltip: ResetText.weeklyPacing(limit, now: now).map { _ in
                      "Remaining quota divided by time until reset, in 24-hour days. An estimate in quota percentage points, not messages.\n" + ResetText.resets(at: limit.resetsAt, now: now)
                  })
        case .reset:
            gauge(title: limit.title, percent: nil, caption: "Reset since the last update", past: false, color: color)
        }
    }

    static func idleSession() -> NSMenuItem {
        gauge(title: RateLimit.Kind.session.title, percent: 0, caption: nil, past: false)
    }

    static func unreadableSession() -> NSMenuItem {
        gauge(title: RateLimit.Kind.session.title, percent: nil, caption: "Couldn't read this limit", past: false)
    }

    /// `percent` nil: the value is unknown, so the label reads a dash and the bar is empty.
    private static func gauge(title: String, percent: Int?, caption: String?, past: Bool, color: NSColor = .controlAccentColor, tooltip: String? = nil) -> NSMenuItem {
        let titleLabel = label(title, font: .systemFont(ofSize: 13, weight: .medium))
        let percentLabel = label(percent.map { "\($0)%" } ?? "\u{2013}", font: .monospacedDigitSystemFont(ofSize: 13, weight: .medium))
        percentLabel.textColor = past ? .systemRed : .labelColor
        let header = NSStackView(views: [titleLabel, NSView(), percentLabel])
        header.orientation = .horizontal
        header.distribution = .fill
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        percentLabel.setContentHuggingPriority(.required, for: .horizontal)

        let bar = BarView(fraction: Double(percent ?? 0) / 100, warning: past, color: color)
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true

        var rows: [NSView] = [header, bar]
        if let caption {
            let captionLabel = label(caption, font: .systemFont(ofSize: 11))
            captionLabel.textColor = .secondaryLabelColor
            rows.append(captionLabel)
        }
        let view = stack(rows, spacing: 5)
        view.toolTip = tooltip
        return item(view)
    }

    static func keyValue(_ key: String, _ value: String, detail: String? = nil, quiet: Bool = false) -> NSMenuItem {
        let k = label(key, font: .systemFont(ofSize: 13))
        if quiet { k.textColor = .secondaryLabelColor }
        let v = label(value, font: .systemFont(ofSize: 13))
        v.textColor = .secondaryLabelColor
        v.alignment = .right
        v.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let row = NSStackView(views: [k, NSView(), v])
        row.orientation = .horizontal
        k.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        var rows: [NSView] = [row]
        if let detail {
            let d = label(detail, font: .systemFont(ofSize: 11))
            d.textColor = .tertiaryLabelColor
            rows.append(d)
        }
        return item(stack(rows, spacing: 2))
    }

    static func breakdown(_ rows: [BreakdownRow]) -> NSMenuItem {
        let heading = label("This week by surface", font: .systemFont(ofSize: 11, weight: .medium))
        heading.textColor = .secondaryLabelColor
        var views: [NSView] = [heading]
        for row in rows where row.percent > 0 {
            let name = label(row.name, font: .systemFont(ofSize: 12))
            let pct = label("\(row.percent)%", font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))
            pct.textColor = .secondaryLabelColor
            let line = NSStackView(views: [name, NSView(), pct])
            line.orientation = .horizontal
            name.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            views.append(line)
        }
        return item(stack(views, spacing: 3))
    }

    static func message(_ text: String) -> NSMenuItem {
        let l = label(text, font: .systemFont(ofSize: 12))
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 3
        l.preferredMaxLayoutWidth = width - 2 * inset
        return item(stack([l], spacing: 0))
    }

    /// The view for a clickable row that runs `handler` and keeps the menu open. Standard
    /// menu items always dismiss the menu when they fire; a custom view does not.
    static func action(_ title: String, enabled: Bool, handler: @escaping () -> Void) -> NSView {
        let view = ActionRowView(title: title, enabled: enabled, handler: handler)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 22)
        return view
    }

    private static func label(_ text: String, font: NSFont) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = font
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    private static func stack(_ views: [NSView], spacing: CGFloat) -> NSView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        s.edgeInsets = NSEdgeInsets(top: 5, left: inset, bottom: 5, right: inset)
        s.translatesAutoresizingMaskIntoConstraints = false
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: s.widthAnchor, constant: -2 * inset).isActive = true
        }
        let container = NSView()
        container.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            s.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            s.topAnchor.constraint(equalTo: container.topAnchor),
            s.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.frame = NSRect(x: 0, y: 0, width: width, height: 0)
        container.layoutSubtreeIfNeeded()
        container.frame.size = NSSize(width: width, height: container.fittingSize.height)
        return container
    }

    private static func item(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }
}

final class ActionRowView: NSView {
    private let handler: () -> Void
    private let enabled: Bool
    private let title: NSTextField
    private var hovered = false { didSet { needsDisplay = true } }

    init(title: String, enabled: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        self.enabled = enabled
        self.title = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        self.title.font = .menuFont(ofSize: 13)
        self.title.textColor = enabled ? .labelColor : .disabledControlTextColor
        self.title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(self.title)
        NSLayoutConstraint.activate([
            self.title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            self.title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = enabled }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseUp(with event: NSEvent) {
        guard enabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        handler()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
    }
}

final class BarView: NSView {
    private let fraction: Double
    private let warning: Bool
    private let color: NSColor

    init(fraction: Double, warning: Bool, color: NSColor) {
        self.fraction = min(max(fraction, 0), 1)
        self.warning = warning
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard fraction > 0 else { return }
        var fill = bounds
        fill.size.width = max(bounds.height, bounds.width * fraction)
        (warning ? NSColor.systemRed : color).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
