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
        case blue, teal, green, amber, purple, pink

        var title: String { rawValue.capitalized }

        var color: NSColor {
            switch self {
            case .blue: return .systemBlue
            case .teal: return .systemTeal
            case .green: return .systemGreen
            case .amber: return NSColor(srgbRed: 1, green: 0.68, blue: 0.12, alpha: 1)
            case .purple: return .systemPurple
            case .pink: return .systemPink
            }
        }
    }

    static var claudeColor: BarColor {
        get { UserDefaults.standard.string(forKey: "claudeColor").flatMap(BarColor.init(rawValue:)) ?? .blue }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "claudeColor") }
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
