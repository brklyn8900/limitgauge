import AppKit

/// A fixed palette, with native buttons for keyboard and VoiceOver access.
@MainActor
final class ColorPicker: NSStackView {
    var selection: Settings.BarColor {
        didSet { updateSelection() }
    }
    private let onSelect: (Settings.BarColor) -> Void
    private var buttons: [NSButton] = []

    init(label: String, selection: Settings.BarColor, onSelect: @escaping (Settings.BarColor) -> Void) {
        self.selection = selection
        self.onSelect = onSelect
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        alignment = .centerY
        setAccessibilityLabel(label)
        for (index, color) in Settings.BarColor.allCases.enumerated() {
            let button = NSButton(image: Self.image(color, selected: false), target: self, action: #selector(choose(_:)))
            button.tag = index
            button.isBordered = false
            button.setButtonType(.toggle)
            button.imagePosition = .imageOnly
            button.toolTip = color.title
            button.setAccessibilityLabel("\(label): \(color.title)")
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            buttons.append(button)
            addArrangedSubview(button)
        }
        updateSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func choose(_ sender: NSButton) {
        selection = Settings.BarColor.allCases[sender.tag]
        onSelect(selection)
    }

    private func updateSelection() {
        for (button, color) in zip(buttons, Settings.BarColor.allCases) {
            let selected = color == selection
            button.state = selected ? .on : .off
            button.image = Self.image(color, selected: selected)
            button.alternateImage = button.image
            button.setAccessibilityValue(selected ? "Selected" : "Not selected")
        }
    }

    private static func image(_ color: Settings.BarColor, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: 28, height: 28), flipped: false) { rect in
            color.color.setFill()
            let swatch = NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5))
            swatch.fill()
            // Keep black and light gray swatches visible against either appearance.
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            swatch.lineWidth = 0.5
            swatch.stroke()
            if selected {
                NSColor.labelColor.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
                ring.lineWidth = 2
                ring.stroke()
            }
            return true
        }
    }
}
