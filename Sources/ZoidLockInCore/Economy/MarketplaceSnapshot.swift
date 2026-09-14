import Foundation

/// One catalog row in the menu-bar marketplace popover.
public struct MarketplaceItemSnapshot: Sendable, Equatable, Identifiable {
    public var kind: AmenityKind
    public var title: String
    public var subtitle: String
    public var sealGlyph: String
    public var standardCost: Double
    public var effectiveCost: Double
    public var durationCaption: String
    public var isBlockedByCurfew: Bool
    public var isActive: Bool
    public var remainingSeconds: Int?
    public var isFridayZeroCost: Bool

    public var id: AmenityKind { kind }

    public init(
        kind: AmenityKind,
        title: String,
        subtitle: String,
        sealGlyph: String,
        standardCost: Double,
        effectiveCost: Double,
        durationCaption: String,
        isBlockedByCurfew: Bool,
        isActive: Bool,
        remainingSeconds: Int?,
        isFridayZeroCost: Bool
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.sealGlyph = sealGlyph
        self.standardCost = CreditMath.normalize(standardCost)
        self.effectiveCost = CreditMath.normalize(effectiveCost)
        self.durationCaption = durationCaption
        self.isBlockedByCurfew = isBlockedByCurfew
        self.isActive = isActive
        self.remainingSeconds = remainingSeconds
        self.isFridayZeroCost = isFridayZeroCost
    }

    public var formattedCost: String {
        if isFridayZeroCost {
            return "0"
        }
        return String(format: "%0.1f", effectiveCost)
    }

    public var formattedRemaining: String? {
        guard let remainingSeconds else { return nil }
        return MarketplaceSnapshot.formattedCountdown(remainingSeconds)
    }
}

/// View model for the SUMI-E marketplace popover.
public struct MarketplaceSnapshot: Sendable, Equatable {
    public var spendableBalance: Double
    public var walletBalance: Double
    public var lifetimeSurplus: Double
    public var currentStreak: Int
    public var highestStreak: Int
    public var isFridayRest: Bool
    public var isCurfew: Bool
    public var weekdayCaption: String
    public var localDayKey: String
    public var dayStateCaption: String
    public var purchaseError: String?
    public var purchaseInFlight: Bool
    public var items: [MarketplaceItemSnapshot]
    public var mobileShield: MobileShieldStatus

    public init(
        spendableBalance: Double,
        walletBalance: Double,
        lifetimeSurplus: Double,
        currentStreak: Int,
        highestStreak: Int,
        isFridayRest: Bool,
        isCurfew: Bool,
        weekdayCaption: String,
        localDayKey: String,
        dayStateCaption: String,
        purchaseError: String?,
        items: [MarketplaceItemSnapshot],
        purchaseInFlight: Bool = false,
        mobileShield: MobileShieldStatus = .standby
    ) {
        self.spendableBalance = CreditMath.normalize(spendableBalance)
        self.walletBalance = CreditMath.normalize(walletBalance)
        self.lifetimeSurplus = CreditMath.normalize(lifetimeSurplus)
        self.currentStreak = currentStreak
        self.highestStreak = highestStreak
        self.isFridayRest = isFridayRest
        self.isCurfew = isCurfew
        self.weekdayCaption = weekdayCaption
        self.localDayKey = localDayKey
        self.dayStateCaption = dayStateCaption
        self.purchaseError = purchaseError
        self.purchaseInFlight = purchaseInFlight
        self.items = items
        self.mobileShield = mobileShield
    }

    public var mobileShieldCaption: String {
        mobileShield.caption
    }

    public var formattedBalance: String {
        CreditMath.displayString(spendableBalance)
    }

    public var formattedVault: String {
        String(format: "%0.1f surplus", lifetimeSurplus)
    }

    public var activeItems: [MarketplaceItemSnapshot] {
        items.filter { $0.isActive }
    }

    public var curfewCaption: String {
        if isCurfew {
            return "CURFEW ACTIVE · 22:00–03:59"
        }
        return "OPEN · CURFEW 22:00–03:59"
    }

    public static func formattedCountdown(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let remainder = clamped % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    public static func assemble(
        ticker: MenuBarTickerSnapshot,
        catalog: AmenityCatalog = .standard,
        status: EnforcementStatus? = nil,
        localRemaining: [AmenityKind: Int] = [:],
        purchaseError: String? = nil,
        purchaseInFlight: Bool = false,
        mobileShield: MobileShieldStatus? = nil
    ) -> MarketplaceSnapshot {
        let remainingByPass: [PassKind: Int] = Dictionary(
            uniqueKeysWithValues: (status?.activePasses ?? []).map { ($0.kind, $0.remainingSeconds) }
        )
        let items = AmenityKind.allCases.map { kind -> MarketplaceItemSnapshot in
            let cost = catalog.cost(of: kind, fridayRestMode: ticker.isFridayRest)
            let remaining: Int?
            if let passKind = kind.passKind, let seconds = remainingByPass[passKind] {
                remaining = seconds
            } else {
                remaining = localRemaining[kind]
            }
            let blocked = ticker.isCurfew && catalog.isBlockedByCurfew(kind)
            return MarketplaceItemSnapshot(
                kind: kind,
                title: kind.displayName,
                subtitle: kind.subtitle,
                sealGlyph: kind.sealGlyph,
                standardCost: catalog.standardCost(of: kind),
                effectiveCost: cost,
                durationCaption: catalog.durationCaption(of: kind),
                isBlockedByCurfew: blocked,
                isActive: (remaining ?? 0) > 0,
                remainingSeconds: remaining,
                isFridayZeroCost: ticker.isFridayRest && catalog.isBasicComfort(kind)
            )
        }

        return MarketplaceSnapshot(
            spendableBalance: ticker.spendableBalance,
            walletBalance: ticker.walletBalance,
            lifetimeSurplus: ticker.lifetimeSurplus,
            currentStreak: ticker.currentStreak,
            highestStreak: ticker.highestStreak,
            isFridayRest: ticker.isFridayRest,
            isCurfew: ticker.isCurfew,
            weekdayCaption: ticker.weekdayCaption,
            localDayKey: ticker.localDayKey,
            dayStateCaption: ticker.dayStateCaption,
            purchaseError: purchaseError,
            items: items,
            purchaseInFlight: purchaseInFlight,
            mobileShield: mobileShield ?? MobileShieldStatus.derive(
                ticker: ticker,
                status: status,
                localRemaining: localRemaining,
                relayConfigured: false
            )
        )
    }

    /// Slice 5 proof: configured relay, live focus, food + phone windows.
    public static let mobileShieldProof = MarketplaceSnapshot.assemble(
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
        status: EnforcementStatus(
            mode: .hard,
            isLockedDown: false,
            activePassKind: .food,
            remainingPassSeconds: 12 * 60 + 40,
            activePasses: [
                ActivePassStatus(kind: .food, remainingSeconds: 12 * 60 + 40),
                ActivePassStatus(kind: .phone, remainingSeconds: 41 * 60 + 12),
            ]
        ),
        mobileShield: MobileShieldStatus(
            link: .synced,
            sessionActive: true,
            passActive: true,
            relayConfigured: true
        )
    )

    /// Deterministic high-resolution proof: two live passes, vault, full catalog.
    public static let proof = MarketplaceSnapshot.assemble(
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
            dayStateCaption: "Marketplace"
        ),
        status: EnforcementStatus(
            mode: .hard,
            isLockedDown: false,
            activePassKind: .food,
            remainingPassSeconds: 12 * 60 + 40,
            activePasses: [
                ActivePassStatus(kind: .food, remainingSeconds: 12 * 60 + 40),
                ActivePassStatus(kind: .phone, remainingSeconds: 41 * 60 + 12),
            ]
        )
    )
}
