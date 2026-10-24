import AppKit
import LimitGaugeCore

/// User settings in UserDefaults. Keys are chosen so that the default is the zero value.
enum Settings {
    enum Icon: String, CaseIterable {
        case hourglassCircle = "hourglass.circle"
        case hourglass = "hourglass"
        case dropCircle = "drop.circle"
        case gaugeWithNeedle = "gauge.with.needle"
        case chartBarFill = "chart.bar.fill"
        case timer = "timer"

        var title: String {
            switch self {
            case .hourglassCircle: return "Hourglass in circle"
            case .hourglass: return "Hourglass"
            case .dropCircle: return "Drop in circle"
            case .gaugeWithNeedle: return "Gauge"
            case .chartBarFill: return "Bars"
            case .timer: return "Timer"
            }
        }
    }

    enum BarColor: String, CaseIterable {
        case blue, teal, green, amber, purple, pink, black, gray, lightGray

        var title: String { self == .lightGray ? "Light gray" : rawValue.capitalized }

        var color: NSColor {
            switch self {
            case .blue: return NSColor(srgbRed: 0.56, green: 0.71, blue: 0.96, alpha: 1)
            case .teal: return NSColor(srgbRed: 0.51, green: 0.79, blue: 0.76, alpha: 1)
            case .green: return NSColor(srgbRed: 0.60, green: 0.80, blue: 0.60, alpha: 1)
            case .amber: return NSColor(srgbRed: 0.95, green: 0.78, blue: 0.47, alpha: 1)
            case .purple: return NSColor(srgbRed: 0.75, green: 0.63, blue: 0.87, alpha: 1)
            case .pink: return NSColor(srgbRed: 0.91, green: 0.65, blue: 0.74, alpha: 1)
            case .black: return .black
            case .gray: return NSColor(srgbRed: 0.55, green: 0.57, blue: 0.60, alpha: 1)
            case .lightGray: return NSColor(srgbRed: 0.78, green: 0.80, blue: 0.83, alpha: 1)
            }
        }
    }

    static var claudeColor: BarColor {
        get { UserDefaults.standard.string(forKey: "claudeColor").flatMap(BarColor.init(rawValue:)) ?? .green }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "claudeColor") }
    }

    static var keyboardShortcut: KeyboardShortcut? {
        get {
            UserDefaults.standard.data(forKey: "keyboardShortcut").flatMap {
                try? JSONDecoder().decode(KeyboardShortcut.self, from: $0)
            }
        }
        set {
            if let newValue {
                UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "keyboardShortcut")
            } else {
                UserDefaults.standard.removeObject(forKey: "keyboardShortcut")
            }
        }
    }

    static var compactView: Bool {
        get { UserDefaults.standard.bool(forKey: "compactView") }
        set { UserDefaults.standard.set(newValue, forKey: "compactView") }
    }

    static var fableColor: BarColor {
        get { UserDefaults.standard.string(forKey: "fableColor").flatMap(BarColor.init(rawValue:)) ?? .purple }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "fableColor") }
    }

    static var codexColor: BarColor {
        get { UserDefaults.standard.string(forKey: "codexColor").flatMap(BarColor.init(rawValue:)) ?? .amber }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "codexColor") }
    }

    private static let iconKey = "icon"
    private static let hideWarningDotKey = "hideWarningDot"
    private static let notificationsDisabledKey = "notificationsDisabled"
    private static let thresholdsKey = "thresholds"

    static var icon: Icon {
        get { UserDefaults.standard.string(forKey: iconKey).flatMap(Icon.init(rawValue:)) ?? .hourglassCircle }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: iconKey) }
    }

    static var showsWarningDot: Bool {
        get { !UserDefaults.standard.bool(forKey: hideWarningDotKey) }
        set { UserDefaults.standard.set(!newValue, forKey: hideWarningDotKey) }
    }

    static var notificationsEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: notificationsDisabledKey) }
        set { UserDefaults.standard.set(!newValue, forKey: notificationsDisabledKey) }
    }

    static var thresholds: WarningThresholds {
        get {
            guard let data = UserDefaults.standard.data(forKey: thresholdsKey),
                  let t = try? JSONDecoder().decode(WarningThresholds.self, from: data) else { return .default }
            return t
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: thresholdsKey) }
    }
    /// Codex windows are returned dynamically; one threshold applies to each reported bucket.
    static var codexWarningThreshold: Int {
        get {
            let value = UserDefaults.standard.object(forKey: "codexWarningThreshold") as? Int ?? 80
            return min(max(value, 1), 100)
        }
        set { UserDefaults.standard.set(min(max(newValue, 1), 100), forKey: "codexWarningThreshold") }
    }

    static var codexThresholds: WarningThresholds {
        let value = codexWarningThreshold
        return WarningThresholds(session: value, weeklyAll: value, weeklyScoped: value)
    }

}
