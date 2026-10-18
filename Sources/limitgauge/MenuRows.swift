import AppKit
import LimitGaugeCore

/// Custom menu rows. Each is a non-interactive view sized to a fixed menu width.
@MainActor
enum MenuRows {
    static let width: CGFloat = 300
    private static let inset: CGFloat = 14

    /// Title, percent, bar and reset time.
    static func limit(_ limit: RateLimit, now: Date, past: Bool) -> NSMenuItem {
        let title = label(limit.title, font: .systemFont(ofSize: 13, weight: .medium))
        let percent = label("\(limit.percent)%", font: .monospacedDigitSystemFont(ofSize: 13, weight: .medium))
        percent.textColor = past ? .systemRed : .labelColor
        let header = NSStackView(views: [title, NSView(), percent])
        header.orientation = .horizontal
        header.distribution = .fill
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        percent.setContentHuggingPriority(.required, for: .horizontal)

        let bar = BarView(fraction: Double(limit.percent) / 100, warning: past)
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let reset = label(ResetText.resets(at: limit.resetsAt, now: now), font: .systemFont(ofSize: 11))
        reset.textColor = .secondaryLabelColor

        return item(stack([header, bar, reset], spacing: 5))
    }

    /// Left label, right value, optional caption below.
    static func keyValue(_ key: String, _ value: String, detail: String? = nil) -> NSMenuItem {
        let k = label(key, font: .systemFont(ofSize: 13))
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

    /// Weekly usage by surface, one line each.
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

    /// A wrapped sentence, for problems.
    static func message(_ text: String) -> NSMenuItem {
        let l = label(text, font: .systemFont(ofSize: 12))
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 3
        l.preferredMaxLayoutWidth = width - 2 * inset
        return item(stack([l], spacing: 0))
    }

    // MARK: Building blocks

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

/// A thin rounded progress bar.
final class BarView: NSView {
    private let fraction: Double
    private let warning: Bool

    init(fraction: Double, warning: Bool) {
        self.fraction = min(max(fraction, 0), 1)
        self.warning = warning
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
        (warning ? NSColor.systemRed : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
