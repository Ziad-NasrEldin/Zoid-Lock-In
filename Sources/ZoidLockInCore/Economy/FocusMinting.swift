import Foundation

/// Pure focus-credit arithmetic. 30 continuous minutes mint 0.5 credits;
/// a 90-minute block completed before local noon is the 2.0× morning block.
public enum FocusMinting: Sendable {
    public static let secondsPerHalfCredit: TimeInterval = 30 * 60
    public static let morningBlockSeconds: TimeInterval = 90 * 60
    public static let standardMultiplier: Double = 1.0
    public static let morningMomentumMultiplier: Double = 2.0
    public static let interruptionGraceSeconds: TimeInterval = 5 * 60
    public static let dailyTargetCredits: Double = 3.0
    public static let deficitStrikeCredits: Double = -1.0
    public static let halfCredit: Double = 0.5
    public static let creditPerHour: Double = 1.0

    public static func baseCredits(elapsedSeconds: TimeInterval) -> Double {
        guard elapsedSeconds >= secondsPerHalfCredit else { return 0 }
        let chunks = floor(elapsedSeconds / secondsPerHalfCredit)
        return CreditMath.normalize(chunks * halfCredit)
    }

    public static func qualifiesForMorningMomentum(
        elapsedSeconds: TimeInterval,
        startedAt: Date,
        endedAt: Date,
        calendar: Calendar,
        alreadyAwardedToday: Bool
    ) -> Bool {
        guard !alreadyAwardedToday else { return false }
        guard elapsedSeconds + 0.000_1 >= morningBlockSeconds else { return false }
        guard calendar.isDate(startedAt, inSameDayAs: endedAt) else { return false }
        return isBeforeLocalNoon(startedAt, calendar: calendar)
            && isBeforeLocalNoon(endedAt, calendar: calendar)
    }

    public static func multiplier(
        elapsedSeconds: TimeInterval,
        startedAt: Date,
        endedAt: Date,
        calendar: Calendar,
        alreadyAwardedToday: Bool
    ) -> Double {
        qualifiesForMorningMomentum(
            elapsedSeconds: elapsedSeconds,
            startedAt: startedAt,
            endedAt: endedAt,
            calendar: calendar,
            alreadyAwardedToday: alreadyAwardedToday
        ) ? morningMomentumMultiplier : standardMultiplier
    }

    public static func mintedCredits(
        elapsedSeconds: TimeInterval,
        startedAt: Date,
        endedAt: Date,
        calendar: Calendar,
        alreadyAwardedToday: Bool
    ) -> Double {
        let base = baseCredits(elapsedSeconds: elapsedSeconds)
        let rate = multiplier(
            elapsedSeconds: elapsedSeconds,
            startedAt: startedAt,
            endedAt: endedAt,
            calendar: calendar,
            alreadyAwardedToday: alreadyAwardedToday
        )
        return CreditMath.normalize(base * rate)
    }

    public static func isBeforeLocalNoon(_ date: Date, calendar: Calendar) -> Bool {
        calendar.component(.hour, from: date) < 12
    }
}
