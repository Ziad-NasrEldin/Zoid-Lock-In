import Foundation

/// Amenity / emergency pass kind. Daemon-owned; user-space SQLite is not consulted.
public enum PassKind: String, Sendable, Equatable, Codable {
    case food
    case phone
    case streaming
    case gaming
    case emergency
}

/// Stub voucher type for Slice 4 ledger passes. Slice 2 always rejects amenity
/// `openPass` until a cryptographic voucher is presented.
public struct AmenityPassVoucher: Sendable, Equatable, Codable {
    public var payload: Data

    public init(payload: Data = Data()) {
        self.payload = payload
    }

    /// Slice 4 will verify a signature over `(kind, duration, nonce, teamID)`.
    public var isVerified: Bool {
        false
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
public struct DaemonPassController: Sendable, Equatable {
    public static let emergencyCooldownSeconds: TimeInterval = 24 * 60 * 60

    public var active: DaemonLocalPass?
    public var lastEmergencyStartedAt: TimeInterval?
    public var lastEmergencyUTC: Date?
    public var lastEmergencyBootSessionUUID: String?

    public init(active: DaemonLocalPass? = nil) {
        self.active = active
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
        if let active, active.isActive(at: time) {
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
        active = DaemonLocalPass(
            kind: .emergency,
            startedAtSeconds: time,
            durationSeconds: DaemonLocalPass.emergencyDurationSeconds
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

    public mutating func open(
        kind: PassKind,
        durationSeconds: TimeInterval,
        at time: TimeInterval
    ) throws {
        _ = (kind, durationSeconds, time)
        throw EnforcementControlError.amenityPassRequiresVoucher
    }

    public mutating func revoke() {
        active = nil
    }

    /// Returns true when a previously active pass just expired.
    @discardableResult
    public mutating func expireIfNeeded(at time: TimeInterval) -> Bool {
        guard let active else { return false }
        if active.isActive(at: time) {
            return false
        }
        self.active = nil
        return true
    }

    public func isEmergencyPassActive(at time: TimeInterval) -> Bool {
        guard let active, active.kind == .emergency else { return false }
        return active.isActive(at: time)
    }
}
