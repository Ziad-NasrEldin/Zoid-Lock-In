import Foundation

/// Compares wall-clock motion against a monotonic hardware baseline.
///
/// A jump larger than 120 seconds means the user (or NTP) moved the system
/// clock independently of `CLOCK_MONOTONIC` / `mach_continuous_time`.
public enum TimeTravelError: Error, Equatable, Sendable {
    case clockTampered(skewSeconds: TimeInterval)
}

public final class TimeTravelGuard: @unchecked Sendable {
    public static let maxSkewSeconds: TimeInterval = 120

    private let lock = NSLock()
    private var originWall: Date?
    private var originMonotonic: TimeInterval?
    private var tampered = false
    private var lastSkew: TimeInterval = 0

    public init() {}

    public var isTampered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tampered
    }

    public var lastObservedSkewSeconds: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return lastSkew
    }

    public var hasOrigin: Bool {
        lock.lock()
        defer { lock.unlock() }
        return originWall != nil && originMonotonic != nil
    }

    /// Restores a persisted origin so a wall jump while the app was quit is still caught.
    public func restoreOriginIfNeeded(wall: Date, monotonic: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard originWall == nil, originMonotonic == nil else { return }
        originWall = wall
        originMonotonic = monotonic
        lastSkew = 0
    }

    @discardableResult
    public func observe(wall: Date, monotonic: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }

        guard let originWall, let originMonotonic else {
            self.originWall = wall
            self.originMonotonic = monotonic
            lastSkew = 0
            return 0
        }

        let wallDelta = wall.timeIntervalSince(originWall)
        let monoDelta = monotonic - originMonotonic
        let skew = wallDelta - monoDelta
        lastSkew = skew
        if abs(skew) > Self.maxSkewSeconds {
            tampered = true
        }
        return skew
    }

    public func ensureWritable() throws {
        if isTampered {
            throw TimeTravelError.clockTampered(skewSeconds: lastObservedSkewSeconds)
        }
    }

    /// Restores a persisted tamper bit. Once set, the flag never clears.
    public func markTampered() {
        lock.lock()
        tampered = true
        lock.unlock()
    }
}
