import Foundation

/// Signed wallet mutation recorded in the append-only ledger.
public enum WalletTransactionType: String, Sendable, Equatable, Codable {
    case mint
    case earnedMeeting = "EARNED_MEETING"
    case earnedHabit = "EARNED_HABIT"
    case spend
    case refund = "refund_amenity"
    case penalty
    case reset
    case surplusTransfer = "surplus_transfer"

    /// Credits that count toward the daily 3.0 target.
    public var countsAsDailyEarned: Bool {
        switch self {
        case .mint, .earnedMeeting, .earnedHabit:
            return true
        case .spend, .refund, .penalty, .reset, .surplusTransfer:
            return false
        }
    }
}

/// Persistent focus-session state machine.
public enum FocusSessionState: String, Sendable, Equatable, Codable {
    case active
    case pausedGrace = "paused_grace"
    case completed
    case abandoned
}

/// One append-only wallet event. `amount` is the signed daily-wallet delta.
public struct WalletTransaction: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var amount: Double
    public var balanceAfter: Double
    public var transactionType: WalletTransactionType
    public var referenceID: String?
    public var description: String

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        amount: Double,
        balanceAfter: Double,
        transactionType: WalletTransactionType,
        referenceID: String? = nil,
        description: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.amount = CreditMath.normalize(amount)
        self.balanceAfter = CreditMath.normalize(balanceAfter)
        self.transactionType = transactionType
        self.referenceID = referenceID
        self.description = description
    }
}

/// User-space focus session. Mutable for state transitions; not the ledger.
public struct FocusSessionRecord: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var startTime: Date
    public var endTime: Date?
    public var elapsedSeconds: TimeInterval
    public var state: FocusSessionState
    public var creditsEarned: Double
    public var multiplierApplied: Double

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date? = nil,
        elapsedSeconds: TimeInterval = 0,
        state: FocusSessionState = .active,
        creditsEarned: Double = 0,
        multiplierApplied: Double = FocusMinting.standardMultiplier
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.elapsedSeconds = elapsedSeconds
        self.state = state
        self.creditsEarned = CreditMath.normalize(creditsEarned)
        self.multiplierApplied = multiplierApplied
    }
}

/// One local civil day's midnight close.
public struct DailyReconciliationRecord: Sendable, Equatable {
    public var date: String
    public var targetCredits: Double
    public var earnedCredits: Double
    public var spentCredits: Double
    public var sweptToVault: Double
    public var victoryStreakCount: Int
    public var deficitStrikeApplied: Bool
    public var fridayRestMode: Bool

    public init(
        date: String,
        targetCredits: Double = FocusMinting.dailyTargetCredits,
        earnedCredits: Double,
        spentCredits: Double,
        sweptToVault: Double,
        victoryStreakCount: Int,
        deficitStrikeApplied: Bool,
        fridayRestMode: Bool
    ) {
        self.date = date
        self.targetCredits = CreditMath.normalize(targetCredits)
        self.earnedCredits = CreditMath.normalize(earnedCredits)
        self.spentCredits = CreditMath.normalize(spentCredits)
        self.sweptToVault = CreditMath.normalize(sweptToVault)
        self.victoryStreakCount = victoryStreakCount
        self.deficitStrikeApplied = deficitStrikeApplied
        self.fridayRestMode = fridayRestMode
    }
}

/// Single-row lifetime surplus and streak snapshot.
public struct LifetimeVaultRecord: Sendable, Equatable {
    public var totalSurplusCredits: Double
    public var currentStreak: Int
    public var highestStreak: Int

    public static let empty = LifetimeVaultRecord(
        totalSurplusCredits: 0,
        currentStreak: 0,
        highestStreak: 0
    )

    public init(
        totalSurplusCredits: Double = 0,
        currentStreak: Int = 0,
        highestStreak: Int = 0
    ) {
        self.totalSurplusCredits = CreditMath.normalize(totalSurplusCredits)
        self.currentStreak = currentStreak
        self.highestStreak = highestStreak
    }
}

/// Default on-disk location. The privileged daemon never opens this file.
public enum EconomicLedgerLocation: Sendable {
    public static let applicationSupportDirectoryName = "ZoidLockIn"
    public static let defaultFileName = "db.sqlite"

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(defaultFileName)
    }

    public static func makeIsolatedFileURL(fileManager: FileManager = .default) -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("zoidlockin-ledger-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(defaultFileName)
    }
}

/// Ledger-layer failures. Engine errors live on `ExchangeEngineError`.
public enum EconomicLedgerError: Error, Equatable, Sendable {
    case appendOnly
    case duplicateTransaction
    case duplicateReconciliation
    case invalidSchema
    case sqlite(code: Int32, message: String)
}

/// Wallet rounding. Slice 8 needs hundredths so +0.25 micro-habits stay exact.
public enum CreditMath: Sendable {
    public static let scale: Double = 100

    public static func normalize(_ value: Double) -> Double {
        (value * scale).rounded() / scale
    }

    public static func spendable(_ balance: Double) -> Double {
        max(0, normalize(balance))
    }

    /// `0.5` / `1.5` stay one decimal; `0.25` keeps two.
    public static func displayString(_ value: Double) -> String {
        let normalized = normalize(value)
        let hundredths = Int((normalized * 100).rounded())
        if hundredths % 10 == 0 {
            return String(format: "%0.1f", normalized)
        }
        return String(format: "%0.2f", normalized)
    }

    public static func feedbackCaption(_ amount: Double) -> String {
        "+\(displayString(amount))c"
    }
}
