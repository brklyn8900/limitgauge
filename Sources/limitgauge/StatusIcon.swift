import AppKit

enum StatusIcon {
    static func image(for icon: Settings.Icon) -> NSImage? {
        let image = symbol(icon.rawValue)
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: "limitgauge")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
    }
}
