import Foundation

public enum CommandDashboardTab: String, Sendable, Equatable, Hashable, CaseIterable {
    case overview
    case ledger
    case settings

    public var caption: String {
        switch self {
        case .overview: return "概  OVERVIEW"
        case .ledger: return "帳  LEDGER"
        case .settings: return "鍵  SETTINGS"
        }
    }
}

/// Immutable view model for the SUMI-E Ink command dashboard window.
public struct CommandDashboardSnapshot: Sendable, Equatable {
    public var ticker: MenuBarTickerSnapshot
    public var calibration: CalibrationSnapshot
    public var vault: LifetimeVaultRecord
    public var deficitStrikeCount: Int
    public var deficitStrikeLog: [DailyReconciliationRecord]
    public var transactions: [WalletTransaction]
    public var ledgerPage: TransactionLedgerPage
    public var security: SecuritySettingsSnapshot
    public var governance: GovernanceLockSnapshot
    public var emergencyDebtCredits: Double
    public var emergencyValveActive: Bool
    public var emergencyValveCaption: String
    public var todayFocusMinutes: Int
    public var clockCaption: String
    public var healthCaption: String
    public var selectedTab: CommandDashboardTab
    public var amenityPrices: [AmenityKind: Double]
    public var blocklistRules: [BlocklistRule]
    public var habits: [MicroHabitRowSnapshot]

    public init(
        ticker: MenuBarTickerSnapshot,
        calibration: CalibrationSnapshot,
        vault: LifetimeVaultRecord,
        deficitStrikeCount: Int,
        deficitStrikeLog: [DailyReconciliationRecord],
        transactions: [WalletTransaction],
        ledgerPage: TransactionLedgerPage,
        security: SecuritySettingsSnapshot,
        governance: GovernanceLockSnapshot,
        emergencyDebtCredits: Double,
        emergencyValveActive: Bool,
        emergencyValveCaption: String,
        todayFocusMinutes: Int,
        clockCaption: String,
        healthCaption: String,
        selectedTab: CommandDashboardTab = .overview,
        amenityPrices: [AmenityKind: Double] = [:],
        blocklistRules: [BlocklistRule] = [],
        habits: [MicroHabitRowSnapshot] = []
    ) {
        self.ticker = ticker
        self.calibration = calibration
        self.vault = vault
        self.deficitStrikeCount = deficitStrikeCount
        self.deficitStrikeLog = deficitStrikeLog
        self.transactions = transactions
        self.ledgerPage = ledgerPage
        self.security = security
        self.governance = governance
        self.emergencyDebtCredits = CreditMath.normalize(emergencyDebtCredits)
        self.emergencyValveActive = emergencyValveActive
        self.emergencyValveCaption = emergencyValveCaption
        self.todayFocusMinutes = todayFocusMinutes
        self.clockCaption = clockCaption
        self.healthCaption = healthCaption
        self.selectedTab = selectedTab
        self.amenityPrices = amenityPrices
        self.blocklistRules = blocklistRules
        self.habits = habits
    }

    public func currentCost(for kind: AmenityKind) -> Double {
        if let custom = amenityPrices[kind] {
            return CreditMath.normalize(custom)
        }
        return AmenityCatalog.standard.intrinsicCost(of: kind)
    }

    public func isPriceOverridden(for kind: AmenityKind) -> Bool {
        amenityPrices[kind] != nil
    }

    public var bannerCaption: String {
        calibration.bannerCaption
    }

    public var formattedVault: String {
        CreditMath.displayString(vault.totalSurplusCredits)
    }

    public var formattedEmergencyDebt: String {
        if emergencyDebtCredits == 0 {
            return "None"
        }
        return "\(CreditMath.displayString(abs(emergencyDebtCredits))) pending"
    }

    public var curfewCaption: String {
        ticker.isCurfew ? "CURFEW ACTIVE · 22:00–03:59" : "OPEN · CURFEW 22:00–03:59"
    }

    public static func assemble(
        ticker: MenuBarTickerSnapshot,
        calibration: CalibrationSnapshot,
        vault: LifetimeVaultRecord,
        reconciliations: [DailyReconciliationRecord],
        transactions: [WalletTransaction],
        security: SecuritySettingsSnapshot,
        governance: GovernanceLockSnapshot,
        emergencyDebtCredits: Double = 0,
        emergencyValveActive: Bool = false,
        ledgerFilter: LedgerAuditKind = .all,
        ledgerSearch: String = "",
        ledgerPage: Int = 1,
        ledgerPageSize: Int = TransactionLedgerQuery.defaultPageSize,
        selectedTab: CommandDashboardTab = .overview,
        clockCaption: String? = nil,
        healthCaption: String? = nil,
        amenityPrices: [AmenityKind: Double] = [:],
        blocklistRules: [BlocklistRule] = [],
        habits: [MicroHabitRowSnapshot] = []
    ) -> CommandDashboardSnapshot {
        let strikes = reconciliations.filter(\.deficitStrikeApplied)
        let page = TransactionLedgerQuery.page(
            from: transactions,
            filter: ledgerFilter,
            search: ledgerSearch,
            page: ledgerPage,
            pageSize: ledgerPageSize
        )
        let health: String
        if let healthCaption {
            health = healthCaption
        } else if ticker.isClockTampered || calibration.isClockTampered {
            health = "CLOCK TAMPER"
        } else if calibration.isSoftModeActive {
            health = "AUDIT · SOFT"
        } else {
            health = "HARD LOCK"
        }
        let clock = clockCaption ?? "\(ticker.weekdayCaption.uppercased()) · \(ticker.localDayKey)"
        let valveCaption: String
        if emergencyValveActive {
            valveCaption = "EMERGENCY VALVE OPEN"
        } else {
            valveCaption = "EMERGENCY VALVE ARMED"
        }
        return CommandDashboardSnapshot(
            ticker: ticker,
            calibration: calibration,
            vault: vault,
            deficitStrikeCount: strikes.count,
            deficitStrikeLog: strikes,
            transactions: transactions,
            ledgerPage: page,
            security: security,
            governance: governance,
            emergencyDebtCredits: emergencyDebtCredits,
            emergencyValveActive: emergencyValveActive,
            emergencyValveCaption: valveCaption,
            todayFocusMinutes: ticker.focusElapsedSeconds / 60,
            clockCaption: clock,
            healthCaption: health,
            selectedTab: selectedTab,
            amenityPrices: amenityPrices,
            blocklistRules: blocklistRules,
            habits: habits
        )
    }

    /// Deterministic 1200×800 proof: Day 2 calibration, vault, streak, ledger.
    public static let proof = CommandDashboardSnapshot.assemble(
        ticker: MenuBarTickerSnapshot(
            walletBalance: 6.5,
            spendableBalance: 6.5,
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
        ),
        calibration: .proof,
        vault: LifetimeVaultRecord(
            totalSurplusCredits: 42.5,
            currentStreak: 7,
            highestStreak: 12
        ),
        reconciliations: [
            DailyReconciliationRecord(
                date: "2026-09-08",
                earnedCredits: 1.5,
                spentCredits: 0,
                sweptToVault: 0,
                victoryStreakCount: 0,
                deficitStrikeApplied: true,
                fridayRestMode: false
            ),
            DailyReconciliationRecord(
                date: "2026-09-10",
                earnedCredits: 2.0,
                spentCredits: 0,
                sweptToVault: 0,
                victoryStreakCount: 0,
                deficitStrikeApplied: true,
                fridayRestMode: false
            ),
            DailyReconciliationRecord(
                date: "2026-09-11",
                earnedCredits: 4.0,
                spentCredits: 1.5,
                sweptToVault: 2.5,
                victoryStreakCount: 7,
                deficitStrikeApplied: false,
                fridayRestMode: false
            ),
        ],
        transactions: proofTransactions,
        security: .unlockedProof,
        governance: GovernanceLockSnapshot(
            isLocked: true,
            remainingSeconds: 36 * 3600 + 12 * 60 + 8,
            isBypassEnabled: false,
            lastConfigurationMutationAt: Date(timeIntervalSince1970: 1_788_800_000),
            isClockTampered: false
        ),
        emergencyDebtCredits: 0,
        emergencyValveActive: false,
        clockCaption: "SATURDAY · 2026-09-12 · 09:12",
        healthCaption: "AUDIT · SOFT"
    )

    public static let hardLockProof: CommandDashboardSnapshot = {
        var snapshot = CommandDashboardSnapshot.proof
        snapshot.calibration = CalibrationSnapshot(
            phase: .hardLockdown,
            state: CalibrationState(
                calibrationStartedAt: Date(timeIntervalSince1970: 1_788_912_000),
                calibrationStartedMonotonic: 0,
                bootSessionUUID: "proof-boot",
                isCompleted: true,
                transitionToHardAt: Date(timeIntervalSince1970: 1_789_084_800)
            ),
            remainingSeconds: 0,
            isClockTampered: false
        )
        snapshot.healthCaption = "HARD LOCK"
        return snapshot
    }()

    private static let proofTransactions: [WalletTransaction] = {
        let base = Date(timeIntervalSince1970: 1_788_912_000)
        func tx(
            index: Int,
            offset: TimeInterval,
            amount: Double,
            balance: Double,
            type: WalletTransactionType,
            reference: String?,
            description: String
        ) -> WalletTransaction {
            WalletTransaction(
                id: UUID(uuidString: String(format: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEE%02d", index))!,
                timestamp: base.addingTimeInterval(offset),
                amount: amount,
                balanceAfter: balance,
                transactionType: type,
                referenceID: reference,
                description: description
            )
        }
        return [
            tx(index: 1, offset: 3600, amount: 1.0, balance: 1.0, type: .mint, reference: "focus-1", description: "Focus mint +1.0 (3600s)"),
            tx(index: 2, offset: 5400, amount: 1.0, balance: 2.0, type: .mint, reference: "focus-1", description: "Morning Momentum 2.0×"),
            tx(index: 3, offset: 7200, amount: 0.25, balance: 2.25, type: .earnedHabit, reference: "habit:brush", description: "EARNED_HABIT Brushing Teeth"),
            tx(index: 4, offset: 9000, amount: 1.5, balance: 3.75, type: .earnedMeeting, reference: "meeting:1", description: "EARNED_MEETING client audit"),
            tx(index: 5, offset: 10_800, amount: -1.5, balance: 2.25, type: .spend, reference: "food", description: "Spend 1.5 on food_pass"),
            tx(index: 6, offset: 12_000, amount: 3.0, balance: 5.25, type: .mint, reference: "focus-2", description: "Focus mint +3.0 (10800s)"),
            tx(index: 7, offset: 14_400, amount: 1.25, balance: 0, type: .surplusTransfer, reference: "2026-09-11", description: "Surplus sweep 1.25 to vault"),
            tx(index: 8, offset: 16_200, amount: -2.0, balance: -2.0, type: .penalty, reference: "emergency-1", description: "Emergency safety valve −2.0 credit debt"),
        ]
    }()
}
