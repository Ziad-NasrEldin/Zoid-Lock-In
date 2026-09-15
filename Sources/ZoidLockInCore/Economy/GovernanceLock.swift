import Foundation

/// 48-hour configuration cooldown. Mutations persist `last_configuration_mutation_at`.
public enum GovernanceLockPolicy: Sendable {
    public static let cooldownSeconds: TimeInterval = 172_800
    public static let bypassEnvironmentKey = "ZOID_BYPASS_GOVERNANCE_COOLDOWN"

    /// Environment bypass is compiled in for DEBUG only. Release always returns false.
    public static var isCompileTimeBypassAllowed: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    public static func isEnvironmentBypassEnabled(_ environment: [String: String]) -> Bool {
        #if DEBUG
        guard let raw = environment[bypassEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return false
        }
        let lowered = raw.lowercased()
        return raw == "1" || lowered == "true" || lowered == "yes"
        #else
        _ = environment
        return false
        #endif
    }

    public static func formattedCountdown(_ seconds: TimeInterval) -> String {
        let clamped = max(0, Int(seconds.rounded(.down)))
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let remainder = clamped % 60
        return String(format: "%d:%02d:%02d", hours, minutes, remainder)
    }
}

/// Test-target seam. Production `ZoidLockInApp` uses the public coordinator
/// initializer, which cannot see this type (`internal`). `@testable import`
/// is required from `Tests/ZoidLockInTests`.
struct GovernanceLockTestConfiguration: Sendable {
    var bypassCooldown: Bool

    init(bypassCooldown: Bool) {
        self.bypassCooldown = bypassCooldown
    }
}

public enum GovernanceLockError: Error, Equatable, Sendable {
    case cooldownActive(remainingSeconds: TimeInterval)
    case clockTampered(skewSeconds: TimeInterval)
    case integrityFailed
    case invalidAmenityPrice
    case invalidBlocklistSuffix
}

extension GovernanceLockError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cooldownActive(let remaining):
            return "Configuration is locked for \(GovernanceLockPolicy.formattedCountdown(remaining)) more."
        case .clockTampered(let skew):
            return "Clock tamper lock: wall clock diverged from the monotonic baseline by \(Int(skew.rounded(.up)))s."
        case .integrityFailed:
            return "Governance lock integrity check failed; configuration is locked for 48 hours."
        case .invalidAmenityPrice:
            return "Amenity price must be between 0 and 50 credits."
        case .invalidBlocklistSuffix:
            return "Blocklist suffix is not a usable hostname."
        }
    }
}

/// Persisted cooldown state. Remaining time accrues from monotonic elapsed, not wall time.
public struct GovernanceState: Sendable, Equatable {
    public var lastConfigurationMutationAt: Date?
    public var lastConfigurationMutationMonotonic: TimeInterval?
    public var mutationBootSessionUUID: String?
    public var lastObservedWall: Date?
    public var lastObservedMonotonic: TimeInterval?
    public var lastObservedBootSessionUUID: String?
    public var accruedMonotonicElapsed: TimeInterval
    public var pinnedTimeZoneIdentifier: String?
    public var sequence: UInt64

    public static let empty = GovernanceState()

    public init(
        lastConfigurationMutationAt: Date? = nil,
        lastConfigurationMutationMonotonic: TimeInterval? = nil,
        mutationBootSessionUUID: String? = nil,
        lastObservedWall: Date? = nil,
        lastObservedMonotonic: TimeInterval? = nil,
        lastObservedBootSessionUUID: String? = nil,
        accruedMonotonicElapsed: TimeInterval = 0,
        pinnedTimeZoneIdentifier: String? = nil,
        sequence: UInt64 = 0
    ) {
        self.lastConfigurationMutationAt = lastConfigurationMutationAt
        self.lastConfigurationMutationMonotonic = lastConfigurationMutationMonotonic
        self.mutationBootSessionUUID = mutationBootSessionUUID
        self.lastObservedWall = lastObservedWall
        self.lastObservedMonotonic = lastObservedMonotonic
        self.lastObservedBootSessionUUID = lastObservedBootSessionUUID
        self.accruedMonotonicElapsed = max(0, accruedMonotonicElapsed)
        self.pinnedTimeZoneIdentifier = pinnedTimeZoneIdentifier
        self.sequence = sequence
    }

    public var hasMutation: Bool {
        lastConfigurationMutationAt != nil
    }
}

public struct GovernanceLockSnapshot: Sendable, Equatable {
    public var isLocked: Bool
    public var remainingSeconds: TimeInterval
    public var remainingCaption: String
    public var bannerCaption: String
    public var isBypassEnabled: Bool
    public var lastConfigurationMutationAt: Date?
    public var isClockTampered: Bool
    public var integrityFailed: Bool

    public init(
        isLocked: Bool,
        remainingSeconds: TimeInterval,
        isBypassEnabled: Bool,
        lastConfigurationMutationAt: Date?,
        isClockTampered: Bool,
        integrityFailed: Bool = false
    ) {
        self.isLocked = isLocked
        self.remainingSeconds = max(0, remainingSeconds)
        self.remainingCaption = GovernanceLockPolicy.formattedCountdown(remainingSeconds)
        self.isBypassEnabled = isBypassEnabled
        self.lastConfigurationMutationAt = lastConfigurationMutationAt
        self.isClockTampered = isClockTampered
        self.integrityFailed = integrityFailed
        if integrityFailed {
            self.bannerCaption = "CONFIG LOCKED · \(GovernanceLockPolicy.formattedCountdown(GovernanceLockPolicy.cooldownSeconds)) REMAINING"
        } else if isBypassEnabled {
            self.bannerCaption = "CONFIG UNLOCKED · EDITABLE"
        } else if isLocked {
            self.bannerCaption = "CONFIG LOCKED · \(GovernanceLockPolicy.formattedCountdown(remainingSeconds)) REMAINING"
        } else {
            self.bannerCaption = "CONFIG UNLOCKED · EDITABLE"
        }
    }

    public static func failClosed(isClockTampered: Bool) -> GovernanceLockSnapshot {
        GovernanceLockSnapshot(
            isLocked: true,
            remainingSeconds: GovernanceLockPolicy.cooldownSeconds,
            isBypassEnabled: false,
            lastConfigurationMutationAt: Date.distantPast,
            isClockTampered: isClockTampered,
            integrityFailed: true
        )
    }
}
