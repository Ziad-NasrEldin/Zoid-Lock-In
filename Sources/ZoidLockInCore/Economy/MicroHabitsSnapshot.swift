import Foundation

public struct MicroHabitRowSnapshot: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var rewardCredits: Double
    public var dailyFrequencyLimit: Int
    public var completionsToday: Int
    public var isEnabled: Bool
    public var canComplete: Bool
    public var statusCaption: String
    public var lastFeedback: String?

    public init(
        id: UUID,
        title: String,
        rewardCredits: Double,
        dailyFrequencyLimit: Int,
        completionsToday: Int,
        isEnabled: Bool,
        canComplete: Bool,
        statusCaption: String,
        lastFeedback: String? = nil
    ) {
        self.id = id
        self.title = title
        self.rewardCredits = CreditMath.normalize(rewardCredits)
        self.dailyFrequencyLimit = dailyFrequencyLimit
        self.completionsToday = completionsToday
        self.isEnabled = isEnabled
        self.canComplete = canComplete
        self.statusCaption = statusCaption
        self.lastFeedback = lastFeedback
    }

    public var formattedReward: String {
        CreditMath.feedbackCaption(rewardCredits)
    }

    public var isFrequencyReached: Bool {
        completionsToday >= dailyFrequencyLimit
    }
}

/// View model for the native SUMI-E micro-habits popover.
public struct MicroHabitsSnapshot: Sendable, Equatable {
    public var habits: [MicroHabitRowSnapshot]
    public var dailyHabitCredits: Double
    public var dailyCap: Double
    public var governance: GovernanceLockSnapshot
    public var lastFeedback: String?
    public var lastError: String?
    public var spendableBalance: Double
    public var weekdayCaption: String
    public var localDayKey: String
    public var editorIsLocked: Bool

    public init(
        habits: [MicroHabitRowSnapshot],
        dailyHabitCredits: Double,
        dailyCap: Double = HabitCreditMinting.dailyCreditCap,
        governance: GovernanceLockSnapshot,
        lastFeedback: String? = nil,
        lastError: String? = nil,
        spendableBalance: Double,
        weekdayCaption: String,
        localDayKey: String,
        editorIsLocked: Bool
    ) {
        self.habits = habits
        self.dailyHabitCredits = CreditMath.normalize(dailyHabitCredits)
        self.dailyCap = CreditMath.normalize(dailyCap)
        self.governance = governance
        self.lastFeedback = lastFeedback
        self.lastError = lastError
        self.spendableBalance = CreditMath.normalize(spendableBalance)
        self.weekdayCaption = weekdayCaption
        self.localDayKey = localDayKey
        self.editorIsLocked = editorIsLocked
    }

    public var editorFieldsDisabled: Bool { editorIsLocked }

    public var editorAllowsHitTesting: Bool { !editorIsLocked }

    public var editorFieldOpacity: Double { editorIsLocked ? 0.55 : 1 }

    public static let editorReadOnlyCaptionText = "READ-ONLY · CONFIGURATION LOCKED"

    public var editorReadOnlyCaption: String? {
        editorIsLocked ? Self.editorReadOnlyCaptionText : nil
    }

    public var formattedDailyCredits: String {
        "\(CreditMath.displayString(dailyHabitCredits)) / \(CreditMath.displayString(dailyCap))"
    }

    public var formattedBalance: String {
        CreditMath.displayString(spendableBalance)
    }

    public var dailyCapReached: Bool {
        dailyHabitCredits + 0.000_1 >= dailyCap
    }

    public static let empty = MicroHabitsSnapshot(
        habits: [],
        dailyHabitCredits: 0,
        governance: GovernanceLockSnapshot(
            isLocked: false,
            remainingSeconds: 0,
            isBypassEnabled: false,
            lastConfigurationMutationAt: nil,
            isClockTampered: false
        ),
        spendableBalance: 0,
        weekdayCaption: "Monday",
        localDayKey: "2026-09-14",
        editorIsLocked: false
    )

    /// Deterministic high-resolution proof: locked config, live checklist, +0.25c feedback.
    public static let proof = MicroHabitsSnapshot(
        habits: [
            MicroHabitRowSnapshot(
                id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                title: "Brushing Teeth / Dental Routine",
                rewardCredits: 0.25,
                dailyFrequencyLimit: 2,
                completionsToday: 1,
                isEnabled: true,
                canComplete: true,
                statusCaption: "1 / 2",
                lastFeedback: "+0.25c"
            ),
            MicroHabitRowSnapshot(
                id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                title: "Making Bed / Room Reset",
                rewardCredits: 0.25,
                dailyFrequencyLimit: 1,
                completionsToday: 1,
                isEnabled: true,
                canComplete: false,
                statusCaption: "DONE"
            ),
            MicroHabitRowSnapshot(
                id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
                title: "Daily Hydration Goal (2L Water)",
                rewardCredits: 0.25,
                dailyFrequencyLimit: 1,
                completionsToday: 0,
                isEnabled: true,
                canComplete: true,
                statusCaption: "0 / 1"
            ),
            MicroHabitRowSnapshot(
                id: UUID(uuidString: "44444444-4444-4333-8444-444444444444")!,
                title: "Physical Movement / Stretching (15m)",
                rewardCredits: 0.50,
                dailyFrequencyLimit: 1,
                completionsToday: 0,
                isEnabled: true,
                canComplete: true,
                statusCaption: "0 / 1"
            ),
            MicroHabitRowSnapshot(
                id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
                title: "Evening Journal",
                rewardCredits: 0.25,
                dailyFrequencyLimit: 1,
                completionsToday: 0,
                isEnabled: false,
                canComplete: false,
                statusCaption: "OFF"
            ),
        ],
        dailyHabitCredits: 0.50,
        governance: GovernanceLockSnapshot(
            isLocked: true,
            remainingSeconds: 47 * 3600 + 59 * 60 + 12,
            isBypassEnabled: false,
            lastConfigurationMutationAt: Date(timeIntervalSince1970: 1_700_000_000),
            isClockTampered: false
        ),
        lastFeedback: "+0.25c",
        spendableBalance: 0.50,
        weekdayCaption: "Monday",
        localDayKey: "2026-09-14",
        editorIsLocked: true
    )
}
