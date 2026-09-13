import Foundation

/// Amenity / emergency pass kind. Daemon-owned; user-space SQLite is not consulted.
public enum PassKind: String, Sendable, Equatable, Hashable, Codable, CaseIterable, Comparable {
    case emergency
    case food
    case phone
    case streaming
    case gaming

    /// Domains this pass may whitelist. Empty means no network relax (gaming).
    public var relaxedDomainSuffixes: [String] {
        switch self {
        case .emergency:
            return DomainFilterRules.defaultBlacklist
        case .food:
            return DomainFilterRules.foodDeliverySuffixes
        case .phone:
            return DomainFilterRules.communicationSuffixes
        case .streaming:
            return DomainFilterRules.streamingSuffixes
        case .gaming:
            return []
        }
    }

    /// Emergency and gaming pause process kills; other kinds keep the sentinel hard.
    public var relaxesProcessTermination: Bool {
        switch self {
        case .emergency, .gaming:
            return true
        case .food, .phone, .streaming:
            return false
        }
    }

    /// Catalog durations. The daemon ignores client-supplied durations and uses these.
    public var catalogDurationSeconds: Int {
        switch self {
        case .emergency:
            return Int(DaemonLocalPass.emergencyDurationSeconds)
        case .food, .gaming:
            return 30 * 60
        case .phone, .streaming:
            return 60 * 60
        }
    }

    /// True for ledger-backed amenity tickets. Emergency is the safety valve, not a voucher.
    public var isAmenityPass: Bool {
        self != .emergency
    }

    public static func < (lhs: PassKind, rhs: PassKind) -> Bool {
        lhs.canonicalRank < rhs.canonicalRank
    }

    public var canonicalRank: Int {
        switch self {
        case .emergency: return 0
        case .food: return 1
        case .phone: return 2
        case .streaming: return 3
        case .gaming: return 4
        }
    }
}

/// HMAC-signed ticket proving a user-space ledger debit. Empty vouchers are not verified.
public struct AmenityPassVoucher: Sendable, Equatable, Codable {
    public var payload: Data
    public var signature: Data

    public init(payload: Data = Data(), signature: Data = Data()) {
        self.payload = payload
        self.signature = signature
    }

    /// Structural completeness. Cryptographic validation is `AmenityVoucherVerifier.verify`.
    public var isVerified: Bool {
        !payload.isEmpty && !signature.isEmpty
    }
}

/// Daemon-owned amenity or emergency pass. Expiry is monotonic-continuous;
/// clients cannot supply `expires_at`. User-space SQLite is never consulted.
public struct DaemonLocalPass: Sendable, Equatable {
    public static let emergencyDurationSeconds: TimeInterval = 30 * 60

    public var kind: PassKind
    public var startedAtSeconds: TimeInterval
    public var durationSeconds: TimeInterval

    public init(
        kind: PassKind,
        startedAtSeconds: TimeInterval,
        durationSeconds: TimeInterval
    ) {
        self.kind = kind
        self.startedAtSeconds = startedAtSeconds
        self.durationSeconds = durationSeconds
    }

    public var expiresAtSeconds: TimeInterval {
        startedAtSeconds + durationSeconds
    }

    public func isActive(at time: TimeInterval) -> Bool {
        time < expiresAtSeconds
    }

    public func remainingSeconds(at time: TimeInterval) -> TimeInterval {
        max(0, expiresAtSeconds - time)
    }
}

/// Privilege-process pass controller. Tick with a continuous monotonic clock;
/// never `Date()` for expiry. Emergency activations honor a 24-hour cooldown.
///
/// Amenity passes are indexed by `PassKind` so Food and Phone can run at the
/// same time without clobbering each other. Each kind expires independently.
public struct DaemonPassController: Sendable, Equatable {
    public static let emergencyCooldownSeconds: TimeInterval = 24 * 60 * 60

    public var passes: [PassKind: DaemonLocalPass]
    public var lastEmergencyStartedAt: TimeInterval?
    public var lastEmergencyUTC: Date?
    public var lastEmergencyBootSessionUUID: String?

    public init(passes: [PassKind: DaemonLocalPass] = [:]) {
        self.passes = passes
    }

    /// Primary stored pass for single-slot APIs. Emergency wins; otherwise the
    /// soonest-expiring stored kind. Call `expireIfNeeded` before relying on liveness.
    public var active: DaemonLocalPass? {
        get {
            if let emergency = passes[.emergency] {
                return emergency
            }
            return passes.values.min { lhs, rhs in
                if lhs.expiresAtSeconds != rhs.expiresAtSeconds {
                    return lhs.expiresAtSeconds < rhs.expiresAtSeconds
                }
                return lhs.kind < rhs.kind
            }
        }
        set {
            if let newValue {
                passes[newValue.kind] = newValue
            } else {
                passes.removeAll()
            }
        }
    }

    public func primaryPass(at time: TimeInterval) -> DaemonLocalPass? {
        let live = activePasses(at: time)
        if let emergency = live[.emergency] {
            return emergency
        }
        return live.values.min { lhs, rhs in
            if lhs.expiresAtSeconds != rhs.expiresAtSeconds {
                return lhs.expiresAtSeconds < rhs.expiresAtSeconds
            }
            return lhs.kind < rhs.kind
        }
    }

    public func activePasses(at time: TimeInterval) -> [PassKind: DaemonLocalPass] {
        passes.filter { $0.value.isActive(at: time) }
    }

    public func activeKinds(at time: TimeInterval) -> Set<PassKind> {
        Set(activePasses(at: time).keys)
    }

    public mutating func restoreCooldown(
        startedAt: TimeInterval,
        utc: Date,
        bootSessionUUID: String
    ) {
        lastEmergencyStartedAt = startedAt
        lastEmergencyUTC = utc
        lastEmergencyBootSessionUUID = bootSessionUUID
    }

    public func emergencyCooldownRemaining(
        at time: TimeInterval,
        utcNow: Date,
        bootSessionUUID: String,
        cooldownSeconds: TimeInterval = Self.emergencyCooldownSeconds
    ) -> TimeInterval {
        if lastEmergencyBootSessionUUID == bootSessionUUID, let started = lastEmergencyStartedAt {
            return max(0, cooldownSeconds - (time - started))
        }
        if let utc = lastEmergencyUTC {
            return max(0, cooldownSeconds - utcNow.timeIntervalSince(utc))
        }
        return 0
    }

    public mutating func expireIfNeededThenEnsureEmergencyAllowed(
        at time: TimeInterval,
        utcNow: Date,
        bootSessionUUID: String,
        cooldownSeconds: TimeInterval = Self.emergencyCooldownSeconds
    ) throws {
        expireIfNeeded(at: time)
        if let emergency = passes[.emergency], emergency.isActive(at: time) {
            throw EnforcementControlError.passAlreadyActive
        }
        let remaining = emergencyCooldownRemaining(
            at: time,
            utcNow: utcNow,
            bootSessionUUID: bootSessionUUID,
            cooldownSeconds: cooldownSeconds
        )
        if remaining > 0 {
            throw EnforcementControlError.emergencyCooldownActive(remainingSeconds: remaining)
        }
    }

    public mutating func commitEmergency(
        at time: TimeInterval,
        utcNow: Date,
        bootSessionUUID: String
    ) {
        install(
            kind: .emergency,
            durationSeconds: DaemonLocalPass.emergencyDurationSeconds,
            at: time
        )
        lastEmergencyStartedAt = time
        lastEmergencyUTC = utcNow
        lastEmergencyBootSessionUUID = bootSessionUUID
    }

    public mutating func engageEmergency(
        at time: TimeInterval,
        utcNow: Date = Date(timeIntervalSince1970: 0),
        bootSessionUUID: String = "test-boot",
        cooldownSeconds: TimeInterval = Self.emergencyCooldownSeconds
    ) throws {
        try expireIfNeededThenEnsureEmergencyAllowed(
            at: time,
            utcNow: utcNow,
            bootSessionUUID: bootSessionUUID,
            cooldownSeconds: cooldownSeconds
        )
        commitEmergency(at: time, utcNow: utcNow, bootSessionUUID: bootSessionUUID)
    }

    /// Ungated amenity open. Slice 4 requires a cryptographic voucher; this
    /// entry still fails closed so a bare XPC `openPass` cannot mint a pass.
    public mutating func open(
        kind: PassKind,
        durationSeconds: TimeInterval,
        at time: TimeInterval
    ) throws {
        _ = (kind, durationSeconds, time)
        throw EnforcementControlError.amenityPassRequiresVoucher
    }

    /// Installs or replaces one kind without touching other concurrent passes.
    public mutating func install(
        kind: PassKind,
        durationSeconds: TimeInterval,
        at time: TimeInterval
    ) {
        expireIfNeeded(at: time)
        passes[kind] = DaemonLocalPass(
            kind: kind,
            startedAtSeconds: time,
            durationSeconds: durationSeconds
        )
    }

    public mutating func revoke() {
        passes.removeAll()
    }

    public mutating func revoke(kind: PassKind) {
        passes.removeValue(forKey: kind)
    }

    /// Returns true when at least one previously active pass just expired.
    @discardableResult
    public mutating func expireIfNeeded(at time: TimeInterval) -> Bool {
        let before = passes
        passes = passes.filter { $0.value.isActive(at: time) }
        return passes != before
    }

    public func isEmergencyPassActive(at time: TimeInterval) -> Bool {
        guard let emergency = passes[.emergency] else { return false }
        return emergency.isActive(at: time)
    }
}
