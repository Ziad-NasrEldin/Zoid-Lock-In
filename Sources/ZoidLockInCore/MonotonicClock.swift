import Darwin
import Foundation

/// Monotonic elapsed-time source. Pass expiry and hold timers must not use wall clocks.
public protocol MonotonicTimeProviding: Sendable {
    func nowSeconds() -> TimeInterval
}

/// `mach_absolute_time` / `CLOCK_UPTIME_RAW` clock. Pauses while the system is asleep.
public struct MachAbsoluteTimeClock: MonotonicTimeProviding {
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
