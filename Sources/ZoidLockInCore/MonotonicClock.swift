import Darwin
import Foundation

/// Monotonic elapsed-time source. Pass expiry and hold timers must not use wall clocks.
public protocol MonotonicTimeProviding: Sendable {
    func nowSeconds() -> TimeInterval
}

/// Continuous monotonic clock (`CLOCK_MONOTONIC` / `mach_continuous_time`).
///
/// Advances while the system is asleep so a 30-minute pass cannot be extended
/// by closing a laptop lid. Does not track NTP or the wall clock.
public struct MachContinuousTimeClock: MonotonicTimeProviding {
    public init() {}

    public func nowSeconds() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}

/// Backwards-compatible name. Pass expiry uses continuous time, not uptime.
public typealias MachAbsoluteTimeClock = MachContinuousTimeClock

/// Uptime clock that **pauses during sleep**. Must not be used for pass expiry.
public struct MachUptimeClock: MonotonicTimeProviding {
    public init() {}

    public func nowSeconds() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }
}

/// Deterministic clock for tests and injected daemon watchdogs.
public final class ManualMonotonicClock: MonotonicTimeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval

    public init(startingAt seconds: TimeInterval = 0) {
        self.seconds = seconds
    }

    public func nowSeconds() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return seconds
    }

    public func advance(by delta: TimeInterval) {
        lock.lock()
        seconds += delta
        lock.unlock()
    }

    public func set(_ seconds: TimeInterval) {
        lock.lock()
        self.seconds = seconds
        lock.unlock()
    }
}

/// Test clock that distinguishes sleep (uptime frozen, continuous advancing).
///
/// `nowSeconds()` returns continuous time, matching `MachContinuousTimeClock`.
public final class SleepSimulationClock: MonotonicTimeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var uptimeSeconds: TimeInterval
    private var continuousSeconds: TimeInterval

    public init(startingAt seconds: TimeInterval = 0) {
        self.uptimeSeconds = seconds
        self.continuousSeconds = seconds
    }

    public func nowSeconds() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return continuousSeconds
    }

    public func uptimeNowSeconds() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return uptimeSeconds
    }

    public func continuousNowSeconds() -> TimeInterval {
        nowSeconds()
    }

    public func advanceAwake(by delta: TimeInterval) {
        lock.lock()
        uptimeSeconds += delta
        continuousSeconds += delta
        lock.unlock()
    }

    /// System sleep: continuous time keeps moving; uptime does not.
    public func simulateSleep(for duration: TimeInterval) {
        lock.lock()
        continuousSeconds += duration
        lock.unlock()
    }

    /// Focus-elapsed adapter: pauses while `simulateSleep` runs.
    public var uptimeClock: any MonotonicTimeProviding {
        SleepSimulationUptimeFacade(clock: self)
    }
}

private final class SleepSimulationUptimeFacade: MonotonicTimeProviding, @unchecked Sendable {
    private let clock: SleepSimulationClock

    init(clock: SleepSimulationClock) {
        self.clock = clock
    }

    func nowSeconds() -> TimeInterval {
        clock.uptimeNowSeconds()
    }
}

/// Wall clock used only for human-readable incident timestamps, never for expiry.
public protocol WallClockProviding: Sendable {
    func now() -> Date
}

public struct SystemWallClock: WallClockProviding {
    public init() {}

    public func now() -> Date {
        Date()
    }
}

public struct FixedWallClock: WallClockProviding, Sendable {
    public var date: Date

    public init(_ date: Date) {
        self.date = date
    }

    public func now() -> Date {
        date
    }
}

/// Mutable wall clock for economic tests. Advance in lockstep with a monotonic
/// clock so the anti-time-travel guard does not treat simulated focus as tamper.
public final class ManualWallClock: WallClockProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    public init(_ date: Date) {
        self.date = date
    }

    public func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    public func set(_ date: Date) {
        lock.lock()
        self.date = date
        lock.unlock()
    }

    public func advance(by delta: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(delta)
        lock.unlock()
    }
}

/// Boot-session identity. Persisted passes (never used) and cooldown restoration
/// compare this UUID so a reboot cannot resurrect a previous boot's monotonic timestamps.
public enum BootSession: Sendable {
    public static let unknownUUID = "unknown"

    public static func currentUUID() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
            return unknownUUID
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
            return unknownUUID
        }
        return buffer.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return unknownUUID }
            return String(cString: base)
        }
    }

    /// `kern.bootsessionuuid` can fail on Darwin and collapse to `"unknown"`.
    /// That sentinel is not a stable boot identity, so two processes both
    /// seeing it must not restore a previous boot's monotonic origin.
    public static func isStableIdentity(_ uuid: String?) -> Bool {
        guard let uuid else { return false }
        let trimmed = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.caseInsensitiveCompare(unknownUUID) != .orderedSame
    }

    public static func isSameBoot(_ lhs: String?, _ rhs: String?) -> Bool {
        guard isStableIdentity(lhs), isStableIdentity(rhs), let lhs, let rhs else {
            return false
        }
        return lhs == rhs
    }
}
