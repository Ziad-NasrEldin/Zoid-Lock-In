import Foundation

/// First-launch 3-day audit window. Days 1–3 warn; Day 4 at local 00:00:00
/// (or 72h monotonic when the wall clock is untrusted) engages hard lockdown.
public final class CalibrationCoordinator: @unchecked Sendable {
    public static let softModeDuration: TimeInterval = 72 * 60 * 60
    public static let softCivilDays = 3

    public let store: any CalibrationStoring
    public let clock: any MonotonicTimeProviding
    public let wallClock: any WallClockProviding
    public let timeTravel: TimeTravelGuard
    public let civilClock: LocalCivilClock
    public let bootSessionUUID: String

    private let lock = NSRecursiveLock()

    public init(
        store: any CalibrationStoring,
        clock: any MonotonicTimeProviding = MachContinuousTimeClock(),
        wallClock: any WallClockProviding = SystemWallClock(),
        timeTravel: TimeTravelGuard = TimeTravelGuard(),
        timeZone: TimeZone = .current,
        bootSessionUUID: String = BootSession.currentUUID()
    ) {
        self.store = store
        self.clock = clock
        self.wallClock = wallClock
        self.timeTravel = timeTravel
        self.civilClock = LocalCivilClock(timeZone: timeZone)
        self.bootSessionUUID = bootSessionUUID
        restoreTimeTravelOrigin()
    }

    public func snapshot() -> CalibrationSnapshot {
        withLock {
            evaluateAndPersistLocked()
        }
    }

    public func currentDay() -> Int {
        snapshot().currentDay
    }

    public func remainingSeconds() -> TimeInterval {
        snapshot().remainingSeconds
    }

    public func isSoftModeActive() -> Bool {
        snapshot().isSoftModeActive
    }

    public func phase() -> CalibrationPhase {
        snapshot().phase
    }

    public func enforcementMode() -> EnforcementMode {
        snapshot().enforcementMode
    }

    public func apply(to policy: EnforcementPolicy) -> EnforcementPolicy {
        policy.applying(calibrationMode: enforcementMode())
    }

    /// Pure transition rules. Tests use this seam without touching SQLite.
    public static func evaluate(
        state: CalibrationState,
        nowWall: Date,
        accruedMonotonic: TimeInterval,
        civilClock: LocalCivilClock,
        isTampered: Bool
    ) -> CalibrationSnapshot {
        if state.isCompleted {
            return CalibrationSnapshot(
                phase: .hardLockdown,
                state: state,
                remainingSeconds: 0,
                isClockTampered: isTampered
            )
        }

        let wallReached = nowWall >= state.transitionToHardAt
        let monoBackstop = accruedMonotonic + 0.000_1 >= softModeDuration
        let shouldComplete: Bool
        if isTampered {
            shouldComplete = monoBackstop
        } else {
            shouldComplete = wallReached || monoBackstop
        }

        if shouldComplete {
            var completed = state
            completed.isCompleted = true
            return CalibrationSnapshot(
                phase: .hardLockdown,
                state: completed,
                remainingSeconds: 0,
                isClockTampered: isTampered
            )
        }

        let remaining: TimeInterval
        if isTampered {
            remaining = max(0, softModeDuration - accruedMonotonic)
        } else {
            remaining = max(0, state.transitionToHardAt.timeIntervalSince(nowWall))
        }

        let phase = softPhase(
            state: state,
            nowWall: nowWall,
            accruedMonotonic: accruedMonotonic,
            civilClock: civilClock,
            isTampered: isTampered
        )
        return CalibrationSnapshot(
            phase: phase,
            state: state,
            remainingSeconds: remaining,
            isClockTampered: isTampered
        )
    }

    private static func softPhase(
        state: CalibrationState,
        nowWall: Date,
        accruedMonotonic: TimeInterval,
        civilClock: LocalCivilClock,
        isTampered: Bool
    ) -> CalibrationPhase {
        let elapsedDays: Int
        if isTampered {
            elapsedDays = min(2, Int(accruedMonotonic / (24 * 3600)))
        } else {
            elapsedDays = min(2, civilClock.civilDaysElapsed(from: state.calibrationStartedAt, to: nowWall))
        }
        switch elapsedDays {
        case 0: return .day1
        case 1: return .day2
        default: return .day3
        }
    }

    private func restoreTimeTravelOrigin() {
        guard let state = try? store.loadCalibrationState() else { return }
        guard state.bootSessionUUID == bootSessionUUID else { return }
        let wall = state.lastObservedWall ?? state.calibrationStartedAt
        let mono = state.lastObservedMonotonic ?? state.calibrationStartedMonotonic
        timeTravel.restoreOriginIfNeeded(wall: wall, monotonic: mono)
    }

    @discardableResult
    private func evaluateAndPersistLocked() -> CalibrationSnapshot {
        let nowWall = wallClock.now()
        let nowMono = clock.nowSeconds()
        var state = loadOrStartLocked(nowWall: nowWall, nowMono: nowMono)
        _ = timeTravel.observe(wall: nowWall, monotonic: nowMono)
        state = accrueLocked(state, nowWall: nowWall, nowMono: nowMono)
        var evaluated = Self.evaluate(
            state: state,
            nowWall: nowWall,
            accruedMonotonic: state.accruedMonotonicElapsed,
            civilClock: civilClock,
            isTampered: timeTravel.isTampered
        )
        state = evaluated.state
        state.lastObservedWall = nowWall
        state.lastObservedMonotonic = nowMono
        evaluated = CalibrationSnapshot(
            phase: evaluated.phase,
            state: state,
            remainingSeconds: evaluated.remainingSeconds,
            isClockTampered: evaluated.isClockTampered
        )
        try? store.saveCalibrationState(state)
        return evaluated
    }

    private func loadOrStartLocked(nowWall: Date, nowMono: TimeInterval) -> CalibrationState {
        if var existing = try? store.loadCalibrationState() {
            if existing.bootSessionUUID != bootSessionUUID {
                existing.bootSessionUUID = bootSessionUUID
                existing.lastObservedMonotonic = nowMono
                existing.lastObservedWall = nowWall
            }
            return existing
        }

        let transition = civilClock.startOfDay(addingDays: Self.softCivilDays, to: nowWall)
        let started = CalibrationState(
            calibrationStartedAt: nowWall,
            calibrationStartedMonotonic: nowMono,
            bootSessionUUID: bootSessionUUID,
            isCompleted: false,
            transitionToHardAt: transition,
            lastObservedWall: nowWall,
            lastObservedMonotonic: nowMono,
            accruedMonotonicElapsed: 0
        )
        timeTravel.restoreOriginIfNeeded(wall: nowWall, monotonic: nowMono)
        _ = timeTravel.observe(wall: nowWall, monotonic: nowMono)
        try? store.saveCalibrationState(started)
        return started
    }

    private func accrueLocked(
        _ state: CalibrationState,
        nowWall: Date,
        nowMono: TimeInterval
    ) -> CalibrationState {
        var next = state
        if next.bootSessionUUID != bootSessionUUID {
            next.bootSessionUUID = bootSessionUUID
            next.lastObservedMonotonic = nowMono
            next.lastObservedWall = nowWall
            return next
        }

        if let lastMono = next.lastObservedMonotonic {
            next.accruedMonotonicElapsed += max(0, nowMono - lastMono)
        } else {
            next.accruedMonotonicElapsed = max(0, nowMono - next.calibrationStartedMonotonic)
        }
        next.lastObservedMonotonic = nowMono
        next.lastObservedWall = nowWall
        return next
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
