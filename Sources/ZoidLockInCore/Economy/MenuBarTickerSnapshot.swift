import Foundation

/// Immutable view model for the menu-bar companion.
public struct MenuBarTickerSnapshot: Sendable, Equatable {
    public var walletBalance: Double
    public var spendableBalance: Double
    public var focusState: FocusSessionState?
    public var focusElapsedSeconds: Int
    public var focusRemainingToNextMintSeconds: Int
    public var focusCreditsEarned: Double
    public var multiplierApplied: Double
    public var currentStreak: Int
    public var highestStreak: Int
    public var lifetimeSurplus: Double
    public var isFridayRest: Bool
    public var isCurfew: Bool
    public var isClockTampered: Bool
    public var localDayKey: String
    public var weekdayCaption: String
    public var dayStateCaption: String

    public init(
        walletBalance: Double,
        spendableBalance: Double,
        focusState: FocusSessionState?,
        focusElapsedSeconds: Int,
        focusRemainingToNextMintSeconds: Int,
        focusCreditsEarned: Double,
        multiplierApplied: Double,
        currentStreak: Int,
        highestStreak: Int,
        lifetimeSurplus: Double,
        isFridayRest: Bool,
        isCurfew: Bool,
        isClockTampered: Bool,
        localDayKey: String,
        weekdayCaption: String,
        dayStateCaption: String
    ) {
        self.walletBalance = walletBalance
        self.spendableBalance = spendableBalance
        self.focusState = focusState
        self.focusElapsedSeconds = focusElapsedSeconds
        self.focusRemainingToNextMintSeconds = focusRemainingToNextMintSeconds
        self.focusCreditsEarned = focusCreditsEarned
        self.multiplierApplied = multiplierApplied
        self.currentStreak = currentStreak
        self.highestStreak = highestStreak
        self.lifetimeSurplus = lifetimeSurplus
        self.isFridayRest = isFridayRest
        self.isCurfew = isCurfew
        self.isClockTampered = isClockTampered
        self.localDayKey = localDayKey
        self.weekdayCaption = weekdayCaption
        self.dayStateCaption = dayStateCaption
    }

    public var formattedBalance: String {
        String(format: "%0.1f", walletBalance)
    }

    public var formattedElapsed: String {
        let hours = focusElapsedSeconds / 3600
        let minutes = (focusElapsedSeconds % 3600) / 60
        let seconds = focusElapsedSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    public var focusStatusCaption: String {
        switch focusState {
        case .active:
            return "Active · \(formattedElapsed)"
        case .pausedGrace:
            return "Grace · \(formattedElapsed)"
        case .completed:
            return "Completed"
        case .abandoned:
            return "Abandoned"
        case nil:
            return "Idle"
        }
    }

    /// Representative ticker used by the high-resolution proof PNG.
    public static let proof = MenuBarTickerSnapshot(
        walletBalance: 3.0,
        spendableBalance: 3.0,
        focusState: .active,
        focusElapsedSeconds: 1 * 3600 + 12 * 60 + 40,
        focusRemainingToNextMintSeconds: 1040,
        focusCreditsEarned: 1.0,
        multiplierApplied: 2.0,
        currentStreak: 7,
        highestStreak: 12,
        lifetimeSurplus: 42.5,
        isFridayRest: false,
        isCurfew: false,
        isClockTampered: false,
        localDayKey: "2026-09-12",
        weekdayCaption: "Saturday",
        dayStateCaption: "Morning Focus"
    )
}
