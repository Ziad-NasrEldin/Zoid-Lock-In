import Foundation

/// Local civil-time rules: Friday rest, 22:00 curfew, noon cutoff, YYYY-MM-DD keys.
public struct LocalCivilClock: Sendable {
    public var calendar: Calendar

    public init(timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = calendar
    }

    public func dayKey(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    public func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    public func endOfDay(_ date: Date) -> Date {
        calendar.date(bySettingHour: 23, minute: 59, second: 59, of: date)
            ?? startOfDay(date).addingTimeInterval(24 * 3600 - 1)
    }

    public func previousDay(_ date: Date) -> Date {
        calendar.date(byAdding: .day, value: -1, to: startOfDay(date))
            ?? date.addingTimeInterval(-24 * 3600)
    }

    public func nextDay(_ date: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: startOfDay(date))
            ?? date.addingTimeInterval(24 * 3600)
    }

    public func date(fromDayKey dayKey: String, hour: Int = 12, minute: Int = 0, second: Int = 0) -> Date? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return date(year: parts[0], month: parts[1], day: parts[2], hour: hour, minute: minute, second: second)
    }

    public func nextDayKey(_ dayKey: String) -> String? {
        guard let date = date(fromDayKey: dayKey) else { return nil }
        return self.dayKey(nextDay(date))
    }

    public func isFriday(_ date: Date) -> Bool {
        calendar.component(.weekday, from: date) == 6
    }

    public func isBeforeNoon(_ date: Date) -> Bool {
        FocusMinting.isBeforeLocalNoon(date, calendar: calendar)
    }

    /// Entertainment and delivery purchases are blocked from 22:00 through 03:59.
    public func isCurfew(_ date: Date) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= 22 || hour < 4
    }

    /// Seconds remaining until the next 22:00:00. Zero while curfew is active.
    public func secondsUntilCurfew(_ date: Date) -> TimeInterval {
        if isCurfew(date) {
            return 0
        }
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = 22
        components.minute = 0
        components.second = 0
        components.nanosecond = 0
        guard let start = calendar.date(from: components) else {
            return 0
        }
        return max(0, start.timeIntervalSince(date))
    }

    public func weekdayCaption(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    public func date(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }
}
