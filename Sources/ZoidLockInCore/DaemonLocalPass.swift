import Foundation

/// Amenity / emergency pass kind. Daemon-owned; user-space SQLite is not consulted.
public enum PassKind: String, Sendable, Equatable, Codable {
    case food
    case phone
    case streaming
    case gaming
    case emergency
}

/// Daemon-owned amenity or emergency pass. Expiry is monotonic; clients cannot
/// supply `expires_at`. User-space SQLite is never consulted.
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

/// Privilege-process pass controller. Tick with a monotonic clock; never `Date()`.
public struct DaemonPassController: Sendable, Equatable {
    public var active: DaemonLocalPass?

    public init(active: DaemonLocalPass? = nil) {
        self.active = active
    }

    public mutating func engageEmergency(at time: TimeInterval) {
        active = DaemonLocalPass(
            kind: .emergency,
            startedAtSeconds: time,
            durationSeconds: DaemonLocalPass.emergencyDurationSeconds
        )
    }

    public mutating func open(
        kind: PassKind,
        durationSeconds: TimeInterval,
        at time: TimeInterval
    ) {
        let duration: TimeInterval
        if kind == .emergency {
            duration = DaemonLocalPass.emergencyDurationSeconds
        } else {
            duration = min(max(durationSeconds, 0), 60 * 60)
        }
        active = DaemonLocalPass(
            kind: kind,
            startedAtSeconds: time,
            durationSeconds: duration
        )
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
