import Foundation

/// Tracks authenticated client liveness. A silent or dead UI process must not
/// leave the daemon unlocked (except for a still-valid daemon-local pass).
public struct HeartbeatMonitor: Sendable, Equatable {
    public static let timeoutSeconds: TimeInterval = 5.0

    public private(set) var lastBeatSeconds: TimeInterval?
    public private(set) var connectionAlive: Bool
    public private(set) var forceTimedOut: Bool

    public init() {
        self.lastBeatSeconds = nil
        self.connectionAlive = false
        self.forceTimedOut = false
    }

    public mutating func noteAcceptedConnection(at time: TimeInterval) {
        connectionAlive = true
        forceTimedOut = false
        lastBeatSeconds = time
    }

    public mutating func recordBeat(at time: TimeInterval) {
        connectionAlive = true
        forceTimedOut = false
        lastBeatSeconds = time
    }

    /// Connection death is treated as an immediate heartbeat failure.
    public mutating func noteConnectionLost(at time: TimeInterval) {
        connectionAlive = false
        forceTimedOut = true
        if lastBeatSeconds == nil {
            lastBeatSeconds = time
        }
    }

    public func hasTimedOut(at time: TimeInterval) -> Bool {
        if forceTimedOut {
            return true
        }
        guard let lastBeatSeconds else {
            return false
        }
        return time - lastBeatSeconds >= Self.timeoutSeconds
    }

    public func secondsSinceLastBeat(at time: TimeInterval) -> TimeInterval? {
        guard let lastBeatSeconds else { return nil }
        return time - lastBeatSeconds
    }
}
