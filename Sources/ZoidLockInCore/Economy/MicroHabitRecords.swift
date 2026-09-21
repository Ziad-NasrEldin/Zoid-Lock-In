import Foundation

/// Customizable daily discipline task. Completions mint `EARNED_HABIT` credits.
public struct MicroHabit: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var rewardCredits: Double
    public var dailyFrequencyLimit: Int
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        rewardCredits: Double = HabitCreditMinting.defaultReward,
        dailyFrequencyLimit: Int = HabitCreditMinting.minDailyFrequency,
        isEnabled: Bool = true,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.rewardCredits = CreditMath.normalize(rewardCredits)
        self.dailyFrequencyLimit = dailyFrequencyLimit
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Default starter catalog representing baseline discipline per PRODUCT.md §2.4.
    public static func defaultCatalog(now: Date = Date()) -> [MicroHabit] {
        [
            MicroHabit(
                title: "Brushing Teeth / Dental Routine",
                rewardCredits: 0.25,
                dailyFrequencyLimit: 2,
                isEnabled: true,
                createdAt: now,
                updatedAt: now
            ),
            MicroHabit(
                title: "Making Bed / Room Reset",
                rewardCredits: 0.25,
                dailyFrequencyLimit: 1,
                isEnabled: true,
                createdAt: now.addingTimeInterval(1),
                updatedAt: now.addingTimeInterval(1)
            ),
            MicroHabit(
                title: "Daily Hydration Goal (2L Water)",
                rewardCredits: 0.25,
                dailyFrequencyLimit: 1,
                isEnabled: true,
                createdAt: now.addingTimeInterval(2),
                updatedAt: now.addingTimeInterval(2)
            ),
            MicroHabit(
                title: "Physical Movement / Stretching (15m)",
                rewardCredits: 0.50,
                dailyFrequencyLimit: 1,
                isEnabled: true,
                createdAt: now.addingTimeInterval(3),
                updatedAt: now.addingTimeInterval(3)
            ),
        ]
    }
}

/// One civil-day completion bound to the wallet via `habit:<completionID>`.
public struct MicroHabitCompletion: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var habitID: UUID
    public var civilDate: String
    public var creditsAwarded: Double
    public var createdAt: Date
    public var createdMonotonic: TimeInterval

    public init(
        id: UUID = UUID(),
        habitID: UUID,
        civilDate: String,
        creditsAwarded: Double,
        createdAt: Date,
        createdMonotonic: TimeInterval = 0
    ) {
        self.id = id
        self.habitID = habitID
        self.civilDate = civilDate
        self.creditsAwarded = CreditMath.normalize(creditsAwarded)
        self.createdAt = createdAt
        self.createdMonotonic = max(0, createdMonotonic)
    }
}

public enum MicroHabitError: Error, Equatable, Sendable {
    case habitNotFound
    case habitDisabled
    case dailyFrequencyReached
    case dailyCreditCeilingReached
    case invalidTitle
    case invalidReward
    case invalidFrequency
    case duplicateCompletion
    case clockTampered(skewSeconds: TimeInterval)
}

extension MicroHabitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .habitNotFound:
            return "That micro-habit does not exist."
        case .habitDisabled:
            return "That micro-habit is disabled."
        case .dailyFrequencyReached:
            return "This habit has already reached its daily frequency limit."
        case .dailyCreditCeilingReached:
            return "Daily micro-habit credit ceiling of \(CreditMath.displayString(HabitCreditMinting.dailyCreditCap)) already reached."
        case .invalidTitle:
            return "Habit title must be between 1 and \(HabitCreditMinting.maxTitleLength) characters."
        case .invalidReward:
            return "Habit reward must be between \(CreditMath.displayString(HabitCreditMinting.minReward)) and \(CreditMath.displayString(HabitCreditMinting.maxReward))."
        case .invalidFrequency:
            return "Daily frequency must be between \(HabitCreditMinting.minDailyFrequency) and \(HabitCreditMinting.maxDailyFrequency)."
        case .duplicateCompletion:
            return "That habit completion has already been recorded."
        case .clockTampered(let skew):
            return "Clock tamper lock: wall clock diverged from the monotonic baseline by \(Int(skew.rounded(.up)))s."
        }
    }
}

/// Pure habit-credit arithmetic. Hard 1.5 credit/day ceiling across all habits.
public enum HabitCreditMinting: Sendable {
    public static let dailyCreditCap: Double = 1.5
    public static let defaultReward: Double = 0.25
    public static let minReward: Double = 0.25
    public static let maxReward: Double = 1.5
    public static let minDailyFrequency: Int = 1
    public static let maxDailyFrequency: Int = 5
    public static let maxTitleLength: Int = 80
    public static let rollingWindowSeconds: TimeInterval = 86_400

    public static func walletReference(completionID: UUID) -> String {
        "habit:\(completionID.uuidString)"
    }

    public static func remainingDailyBudget(earnedToday: Double) -> Double {
        CreditMath.normalize(max(0, dailyCreditCap - earnedToday))
    }

    public static func clippedCredits(requested: Double, earnedToday: Double) -> Double {
        CreditMath.normalize(min(max(0, requested), remainingDailyBudget(earnedToday: earnedToday)))
    }

    /// Conservative cap: civil-day earned and rolling 24h monotonic earned.
    public static func cappedEarned(civilDay: Double, rollingWindow: Double) -> Double {
        CreditMath.normalize(max(civilDay, rollingWindow))
    }

    public static func sanitizedTitle(_ raw: String) -> String? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !trimmed.isEmpty, trimmed.count <= maxTitleLength else {
            return nil
        }
        return trimmed
    }

    public static func validatedReward(_ value: Double) -> Double? {
        let normalized = CreditMath.normalize(value)
        guard normalized + 0.000_1 >= minReward, normalized <= maxReward + 0.000_1 else {
            return nil
        }
        return normalized
    }

    public static func validatedFrequency(_ value: Int) -> Int? {
        guard (minDailyFrequency...maxDailyFrequency).contains(value) else {
            return nil
        }
        return value
    }
}

/// Result of an idempotent, daily-capped habit mint.
public struct HabitCreditMintOutcome: Sendable, Equatable {
    public var transaction: WalletTransaction?
    public var creditsMinted: Double
    public var requestedCredits: Double
    public var clipped: Bool
    public var dailyEarnedAfter: Double
    public var explanation: String?

    public init(
        transaction: WalletTransaction?,
        creditsMinted: Double,
        requestedCredits: Double,
        clipped: Bool,
        dailyEarnedAfter: Double,
        explanation: String? = nil
    ) {
        self.transaction = transaction
        self.creditsMinted = CreditMath.normalize(creditsMinted)
        self.requestedCredits = CreditMath.normalize(requestedCredits)
        self.clipped = clipped
        self.dailyEarnedAfter = CreditMath.normalize(dailyEarnedAfter)
        self.explanation = explanation
    }
}

public struct HabitCompletionOutcome: Sendable, Equatable {
    public var completion: MicroHabitCompletion
    public var transaction: WalletTransaction
    public var creditsMinted: Double
    public var dailyHabitCreditsAfter: Double
    public var clipped: Bool
    public var feedbackCaption: String

    public init(
        completion: MicroHabitCompletion,
        transaction: WalletTransaction,
        creditsMinted: Double,
        dailyHabitCreditsAfter: Double,
        clipped: Bool
    ) {
        self.completion = completion
        self.transaction = transaction
        self.creditsMinted = CreditMath.normalize(creditsMinted)
        self.dailyHabitCreditsAfter = CreditMath.normalize(dailyHabitCreditsAfter)
        self.clipped = clipped
        self.feedbackCaption = CreditMath.feedbackCaption(creditsMinted)
    }
}

public struct BlocklistRule: Sendable, Equatable, Identifiable {
    public var suffix: String
    public var createdAt: Date

    public var id: String { suffix }

    public init(suffix: String, createdAt: Date) {
        self.suffix = DomainFilterRules.normalize(suffix)
        self.createdAt = createdAt
    }
}
