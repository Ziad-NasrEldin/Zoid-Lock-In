import CoreGraphics
import Foundation

/// Physical-input idle sensor. Focus minting must not trust a frontmost window alone.
public protocol ActivityDetecting: Sendable {
    func secondsSinceLastPhysicalEvent() -> TimeInterval
}

/// `CGEventSource.secondsSinceLastEventType` over the combined session.
///
/// Uses `kCGAnyInputEventType` so keyboard, mouse, tablet, and other HID
/// sources all count as human activity.
public struct CGEventIdleMonitor: ActivityDetecting {
    private static let anyInputEventType = CGEventType(rawValue: UInt32.max)!

    private let secondsSinceLastEvent: @Sendable (CGEventType) -> TimeInterval

    public init(
        secondsSinceLastEvent: @escaping @Sendable (CGEventType) -> TimeInterval = { eventType in
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: eventType)
        }
    ) {
        self.secondsSinceLastEvent = secondsSinceLastEvent
    }

    public func secondsSinceLastPhysicalEvent() -> TimeInterval {
        secondsSinceLastEvent(Self.anyInputEventType)
    }
}

/// Deterministic idle source. Either pin an idle duration or drive a mock event clock.
public final class ManualActivityDetector: ActivityDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var overrideIdle: TimeInterval?
    private let eventClock: (any MonotonicTimeProviding)?
    private var lastEventAt: TimeInterval

    public init(idleSeconds: TimeInterval = 0) {
        self.overrideIdle = idleSeconds
        self.eventClock = nil
        self.lastEventAt = 0
    }

    public init(eventClock: any MonotonicTimeProviding, lastEventAt: TimeInterval? = nil) {
        self.overrideIdle = nil
        self.eventClock = eventClock
        self.lastEventAt = lastEventAt ?? eventClock.nowSeconds()
    }

    public func setIdleSeconds(_ seconds: TimeInterval) {
        lock.lock()
        overrideIdle = seconds
        lock.unlock()
    }

    public func recordPhysicalEvent(at time: TimeInterval? = nil) {
        lock.lock()
        overrideIdle = nil
        if let time {
            lastEventAt = time
        } else if let eventClock {
            lastEventAt = eventClock.nowSeconds()
        }
        lock.unlock()
    }

    public func secondsSinceLastPhysicalEvent() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        if let overrideIdle {
            return overrideIdle
        }
        guard let eventClock else { return 0 }
        return max(0, eventClock.nowSeconds() - lastEventAt)
    }
}
