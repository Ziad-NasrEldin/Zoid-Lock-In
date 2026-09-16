import CryptoKit
import Foundation

/// First-launch 3-day audit window. Days 1–3 warn; Day 4 at local 00:00:00
/// (or 72h monotonic when the wall clock is untrusted) engages hard lockdown.
///
/// Missing, corrupt, or HMAC-mismatched `calibration_state` fail-closes to
/// `.hard` and never mints a replacement 3-day window.
public final class CalibrationCoordinator: @unchecked Sendable {
    public static let softModeDuration: TimeInterval = 72 * 60 * 60
    public static let softCivilDays = 3

    public let store: any CalibrationStoring
    public let clock: any MonotonicTimeProviding
    public let wallClock: any WallClockProviding
    public let timeTravel: TimeTravelGuard
    public let civilClock: LocalCivilClock
    public let bootSessionUUID: String
    public let replicaSealStore: (any CalibrationSealPersisting)?

    private let keyProvider: any CalibrationKeyProviding
    private let lock = NSRecursiveLock()
    private var cachedKey: SymmetricKey?
    private var failedClosed = false

    public init(
        store: any CalibrationStoring,
        clock: any MonotonicTimeProviding = MachContinuousTimeClock(),
        wallClock: any WallClockProviding = SystemWallClock(),
        timeTravel: TimeTravelGuard = TimeTravelGuard(),
        timeZone: TimeZone = .current,
        bootSessionUUID: String = BootSession.currentUUID(),
        keyProvider: any CalibrationKeyProviding = InMemoryCalibrationKeyProvider(),
        replicaSealStore: (any CalibrationSealPersisting)? = nil
    ) {
        self.store = store
        self.clock = clock
        self.wallClock = wallClock
        self.timeTravel = timeTravel
        self.civilClock = LocalCivilClock(timeZone: timeZone)
        self.bootSessionUUID = bootSessionUUID
        self.keyProvider = keyProvider
        self.replicaSealStore = replicaSealStore
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
                isClockTampered: isTampered || state.isTampered
            )
        }

        let wallReached = nowWall >= state.transitionToHardAt
        let monoBackstop = accruedMonotonic + 0.000_1 >= softModeDuration
        let shouldComplete: Bool
        if isTampered || state.isTampered {
            shouldComplete = monoBackstop
        } else {
            shouldComplete = wallReached || monoBackstop
        }

        if shouldComplete {
            var completed = state
            completed.isCompleted = true
            completed.isTampered = completed.isTampered || isTampered
            return CalibrationSnapshot(
                phase: .hardLockdown,
                state: completed,
                remainingSeconds: 0,
                isClockTampered: isTampered || completed.isTampered
            )
        }

        let remaining: TimeInterval
        if isTampered || state.isTampered {
            remaining = max(0, softModeDuration - accruedMonotonic)
        } else {
            remaining = max(0, state.transitionToHardAt.timeIntervalSince(nowWall))
        }

        let phase = softPhase(
            state: state,
            nowWall: nowWall,
            accruedMonotonic: accruedMonotonic,
            civilClock: civilClock,
            isTampered: isTampered || state.isTampered
        )
        return CalibrationSnapshot(
            phase: phase,
            state: state,
            remainingSeconds: remaining,
            isClockTampered: isTampered || state.isTampered
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
        guard let state = try? verifiedStateLocked() else { return }
        if state.isTampered {
            timeTravel.markTampered()
        }
        guard state.bootSessionUUID == bootSessionUUID else {
            return
        }
        let wall = state.lastObservedWall ?? state.calibrationStartedAt
        let mono = state.lastObservedMonotonic ?? state.calibrationStartedMonotonic
        timeTravel.restoreOriginIfNeeded(wall: wall, monotonic: mono)
    }

    @discardableResult
    private func evaluateAndPersistLocked() -> CalibrationSnapshot {
        let nowWall = wallClock.now()
        let nowMono = clock.nowSeconds()
        let state: CalibrationState
        do {
            state = try loadOrStartLocked(nowWall: nowWall, nowMono: nowMono)
        } catch {
            return failClosedSnapshotLocked(nowWall: nowWall, nowMono: nowMono)
        }

        _ = timeTravel.observe(wall: nowWall, monotonic: nowMono)
        var next = accrueLocked(state, nowWall: nowWall, nowMono: nowMono)
        if timeTravel.isTampered {
            next.isTampered = true
        }
        let evaluated = Self.evaluate(
            state: next,
            nowWall: nowWall,
            accruedMonotonic: next.accruedMonotonicElapsed,
            civilClock: civilClock,
            isTampered: timeTravel.isTampered || next.isTampered
        )
        next = evaluated.state
        next.lastObservedWall = nowWall
        next.lastObservedMonotonic = nowMono
        next.isTampered = next.isTampered || timeTravel.isTampered
        let previousPhase = Self.evaluate(
            state: state,
            nowWall: state.lastObservedWall ?? nowWall,
            accruedMonotonic: state.accruedMonotonicElapsed,
            civilClock: civilClock,
            isTampered: state.isTampered
        ).phase
        let phaseChanged = evaluated.phase != previousPhase
        let tamperChanged = evaluated.state.isTampered != state.isTampered
        let completedChanged = evaluated.state.isCompleted != state.isCompleted
        let monotonicDelta = (evaluated.state.lastObservedMonotonic ?? nowMono) - (state.lastObservedMonotonic ?? nowMono)

        if phaseChanged || tamperChanged || completedChanged || monotonicDelta >= 60 {
            try? persistStateLocked(next)
        }
        return evaluated
    }

    private func loadOrStartLocked(nowWall: Date, nowMono: TimeInterval) throws -> CalibrationState {
        if failedClosed {
            throw CalibrationError.integrityFailed
        }

        let sqlite: CalibrationState?
        do {
            sqlite = try store.loadCalibrationState()
        } catch {
            throw CalibrationError.integrityFailed
        }

        let envelope: CalibrationSealEnvelope?
        do {
            envelope = try store.loadCalibrationEnvelope()
        } catch {
            throw CalibrationError.integrityFailed
        }

        let replica: CalibrationSealEnvelope?
        do {
            replica = try replicaSealStore?.loadEnvelope()
        } catch {
            throw CalibrationError.integrityFailed
        }

        let key = try sealKeyLocked()
        switch try CalibrationIntegrity.verify(
            sqlite: sqlite,
            envelope: envelope,
            replica: replica,
            key: key
        ) {
        case .firstLaunch:
            return startWindowLocked(nowWall: nowWall, nowMono: nowMono)
        case .loaded(var existing):
            if existing.bootSessionUUID != bootSessionUUID {
                existing.bootSessionUUID = bootSessionUUID
                existing.lastObservedMonotonic = nowMono
                existing.lastObservedWall = nowWall
            }
            if existing.isTampered {
                timeTravel.markTampered()
            }
            return existing
        }
    }

    private func startWindowLocked(nowWall: Date, nowMono: TimeInterval) -> CalibrationState {
        let transition = civilClock.startOfDay(addingDays: Self.softCivilDays, to: nowWall)
        let started = CalibrationState(
            calibrationStartedAt: nowWall,
            calibrationStartedMonotonic: nowMono,
            bootSessionUUID: bootSessionUUID,
            isCompleted: false,
            transitionToHardAt: transition,
            lastObservedWall: nowWall,
            lastObservedMonotonic: nowMono,
            accruedMonotonicElapsed: 0,
            isTampered: false,
            sequence: 0
        )
        timeTravel.restoreOriginIfNeeded(wall: nowWall, monotonic: nowMono)
        _ = timeTravel.observe(wall: nowWall, monotonic: nowMono)
        try? persistStateLocked(started)
        return started
    }

    private func failClosedSnapshotLocked(nowWall: Date, nowMono: TimeInterval) -> CalibrationSnapshot {
        let wasFailedClosed = failedClosed
        failedClosed = true
        timeTravel.markTampered()
        var hard = CalibrationState.failClosedHard(
            nowWall: nowWall,
            nowMono: nowMono,
            bootSessionUUID: bootSessionUUID
        )
        hard.isCompleted = true
        hard.isTampered = true
        if !wasFailedClosed {
            try? persistStateLocked(hard)
        }
        return CalibrationSnapshot(
            phase: .hardLockdown,
            state: hard,
            remainingSeconds: 0,
            isClockTampered: true
        )
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

    private func persistStateLocked(_ state: CalibrationState) throws {
        var next = state
        let previousSequence = (try? store.loadCalibrationState()?.sequence) ?? 0
        next.sequence = max(state.sequence, previousSequence) + 1
        let key = try sealKeyLocked()
        let envelope = try CalibrationSeal.seal(CalibrationSealPayload(next), key: key)
        try replicaSealStore?.saveEnvelope(envelope)
        try store.saveCalibrationEnvelope(envelope)
        try store.saveCalibrationState(next)
    }

    private func verifiedStateLocked() throws -> CalibrationState {
        let sqlite = try store.loadCalibrationState()
        let envelope = try store.loadCalibrationEnvelope()
        let replica = try replicaSealStore?.loadEnvelope()
        let key = try sealKeyLocked()
        switch try CalibrationIntegrity.verify(
            sqlite: sqlite,
            envelope: envelope,
            replica: replica,
            key: key
        ) {
        case .firstLaunch:
            throw CalibrationError.integrityFailed
        case .loaded(let state):
            return state
        }
    }

    private func sealKeyLocked() throws -> SymmetricKey {
        if let cachedKey {
            return cachedKey
        }
        let key = try keyProvider.loadOrCreate()
        cachedKey = key
        return key
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
