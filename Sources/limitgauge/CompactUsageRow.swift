import AppKit
import LimitGaugeCore

/// One shared 0–100% track. Overlaid fills are independent quotas, never added together.
@MainActor
enum CompactUsageRow {
    struct Reading {
        let name: String
        let limit: RateLimit?
        let color: NSColor
    }

    static func item(title: String, readings: [Reading], thresholds: WarningThresholds,
                     service: UsageService, now: Date) -> NSMenuItem {
        let heading = NSTextField(labelWithString: title + (service.problem == nil ? "" : " ⚠︎"))
        heading.font = .systemFont(ofSize: 13, weight: .medium)
        heading.setContentCompressionResistancePriority(.required, for: .horizontal)
        var legendViews: [NSView] = []
        var layers: [OverlayUsageBar.Layer] = []
        var details = ["\(title) weekly usage"]
        for reading in readings {
            let state = reading.limit.map { thresholds.state(of: $0, at: now) }
            let percent = state == .reset ? nil : reading.limit?.percent
            let color: NSColor = state == .past ? .systemRed : reading.color
            let dot = NSTextField(labelWithString: "●")
            dot.font = .systemFont(ofSize: 9)
            dot.textColor = color
            let value = NSTextField(labelWithString: "\(reading.name) \(percent.map { "\($0)%" } ?? "–")")
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            value.textColor = state == .past ? .systemRed : .labelColor
            if state != .reset, let limit = reading.limit,
               let pacing = ResetText.weeklyPacing(limit, now: now, includeReset: false) {
                let amount = pacing.replacingOccurrences(of: "~", with: "")
                    .replacingOccurrences(of: "/day", with: "")
                    .replacingOccurrences(of: " left", with: "")
                let text = NSMutableAttributedString(string: value.stringValue, attributes: [
                    .font: value.font!, .foregroundColor: value.textColor!
                ])
                text.append(NSAttributedString(string: "/\(amount)", attributes: [
                    .font: value.font!, .foregroundColor: NSColor.secondaryLabelColor
                ]))
                value.attributedStringValue = text
                value.widthAnchor.constraint(equalToConstant: ceil(text.size().width) + 4).isActive = true
                details.append("\(reading.name) budget: \(pacing)")
            }
            let entry = NSStackView(views: [dot, value])
            entry.orientation = .horizontal
            entry.spacing = 3
            legendViews.append(entry)
            layers.append(.init(percent: percent, color: color))
            let detail: String
            if let limit = reading.limit {
                detail = state == .reset ? "Reset since the last update" : "\(limit.percent)% · \(ResetText.resets(at: limit.resetsAt, now: now))"
            } else {
                detail = "Unavailable in the latest reading"
            }
            details.append("\(reading.name): \(detail)")
        }
        details.append("Used % / estimated daily budget %. Under 24 hours, the second number is quota left until reset. Daily pacing uses 24-hour days; quotas are independent, not additive.")
        if let snapshot = service.snapshot { details.append("Updated \(ResetText.ago(snapshot.fetchedAt, now: now))") }
        if service.isRefreshing { details.append("Updating…") }
        if let problem = service.problem { details.append(problem.message) }
        let tooltip = details.joined(separator: "\n")
        let legend = NSStackView(views: legendViews)
        legend.orientation = .horizontal
        legend.spacing = 8
        legend.setContentHuggingPriority(.required, for: .horizontal)
        let header = NSStackView(views: [heading, NSView(), legend])
        header.orientation = .horizontal
        header.spacing = 4
        let bar = OverlayUsageBar(layers: layers)
        bar.setAccessibilityElement(true)
        bar.setAccessibilityRole(.image)
        bar.setAccessibilityLabel(tooltip)
        bar.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let rows: [NSView] = [header, bar]
        let content = NSStackView(views: rows)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 3
        content.edgeInsets = NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
        for child in rows {
            child.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28).isActive = true
        }
        content.widthAnchor.constraint(equalToConstant: MenuRows.width).isActive = true
        content.layoutSubtreeIfNeeded()
        content.frame.size = content.fittingSize
        content.toolTip = tooltip
        header.toolTip = tooltip
        bar.toolTip = tooltip
        let item = NSMenuItem()
        item.view = content
        item.isEnabled = false
        return item
    }
}

@MainActor
final class OverlayUsageBar: NSView {
    struct Layer {
        let percent: Int?
        let color: NSColor
    }
    private let layers: [Layer]

    init(layers: [Layer]) {
        self.layers = layers
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 2, dy: 4)
        let outline = NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4)
        NSColor.quaternaryLabelColor.setFill()
        outline.fill()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        // Longer quotas go underneath shorter ones, so both solid colors remain visible.
        for layer in layers.sorted(by: { ($0.percent ?? -1) > ($1.percent ?? -1) }) {
            guard let percent = layer.percent else { continue }
            var fill = track
            fill.size.width *= CGFloat(min(max(percent, 0), 100)) / 100
            layer.color.setFill()
            NSBezierPath(rect: fill).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

    }
}
