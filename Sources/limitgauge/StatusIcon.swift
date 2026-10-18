import AppKit

enum StatusIcon {
    /// Template image for the status item. The Anthropic mark is an SVG in the bundle;
    /// without a bundle, or if the file is missing, it falls back to the drop.
    static func image(for icon: Settings.Icon) -> NSImage? {
        let image: NSImage?
        switch icon {
        case .anthropic:
            image = Bundle.main.url(forResource: "anthropic", withExtension: "svg").flatMap(NSImage.init(contentsOf:))
                ?? symbol(Settings.Icon.dropCircle.rawValue)
        default:
            image = symbol(icon.rawValue)
        }
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: "limitgauge")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
    }
}
