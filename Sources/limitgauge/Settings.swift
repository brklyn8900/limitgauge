import Foundation
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

    private static let iconKey = "icon"
    private static let hideWarningDotKey = "hideWarningDot"
    private static let notificationsDisabledKey = "notificationsDisabled"
    private static let thresholdsKey = "thresholds"
    private static let firedWarningsKey = "firedWarnings"

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

    /// Warnings already posted, so a relaunch does not repeat them within the same window.
    static var firedWarnings: Set<WarningKey> {
        get {
            guard let data = UserDefaults.standard.data(forKey: firedWarningsKey),
                  let keys = try? JSONDecoder().decode(Set<WarningKey>.self, from: data) else { return [] }
            return keys
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: firedWarningsKey) }
    }
}
