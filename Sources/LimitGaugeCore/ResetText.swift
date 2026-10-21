import Foundation

/// Text for reset and expiry times. Every function formats in its calendar's locale and time
/// zone; the default calendar carries the user's.
public enum ResetText {
    /// "Resets in 2h 14m (7:00 PM)" under a day, "Resets in 2d 5h (Sun 7:00 PM)" beyond,
    /// "Resets now" once passed.
    public static func resets(at reset: Date, now: Date, calendar: Calendar = .current) -> String {
        let remaining = reset.timeIntervalSince(now)
        guard remaining > 30 else { return "Resets now" }
        return "Resets in \(duration(remaining)) (\(clock(reset, now: now, calendar: calendar)))"
    }

    /// "Expires Nov 5 at 2:59 AM".
    public static func expires(at date: Date, calendar: Calendar = .current) -> String {
        "Expires \(date.formatted(style(calendar).month(.abbreviated).day().hour().minute()))"
    }

    /// "12 s ago", "3 min ago", "2 h ago".
    public static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "\(Int(s)) s ago" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        return "\(Int(s / 3600)) h ago"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let mins = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
        return "\(mins)m"
    }

    /// Clock time, with the weekday when the reset is not today.
    static func clock(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = date.formatted(style(calendar).hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return time }
        return "\(date.formatted(style(calendar).weekday(.abbreviated))) \(time)"
    }

    /// `.dateTime` reads the process's locale and time zone; this one reads the calendar's.
    private static func style(_ calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
    }
}
