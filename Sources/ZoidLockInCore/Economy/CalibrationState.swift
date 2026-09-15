import Foundation

/// Onboarding phase. Days 1–3 are audit-only; Day 4 is hard lockdown.
public enum CalibrationPhase: String, Sendable, Equatable, Codable {
    case day1
    case day2
    case day3
    case hardLockdown = "hard_lockdown"

    public var dayNumber: Int {
        switch self {
        case .day1: return 1
        case .day2: return 2
        case .day3: return 3
        case .hardLockdown: return 4
        }
    }

    public var isSoft: Bool {
        self != .hardLockdown
    }

    public var enforcementMode: EnforcementMode {
        isSoft ? .calibration : .hard
    }

    public var bannerCaption: String {
        switch self {
        case .day1, .day2, .day3:
            return "CALIBRATION MODE · DAY \(dayNumber) OF 3 · SOFT WARNINGS ONLY"
        case .hardLockdown:
            return "FULL HARD ENFORCEMENT ACTIVE"
        }
    }
}

/// Persisted 3-day calibration row (`calibration_state`).
public struct CalibrationState: Sendable, Equatable {
    public var calibrationStartedAt: Date
    public var calibrationStartedMonotonic: TimeInterval
    public var bootSessionUUID: String
    public var isCompleted: Bool
    public var transitionToHardAt: Date
    public var lastObservedWall: Date?
    public var lastObservedMonotonic: TimeInterval?
    public var accruedMonotonicElapsed: TimeInterval
    public var isTampered: Bool
    public var sequence: UInt64

    public init(
        calibrationStartedAt: Date,
        calibrationStartedMonotonic: TimeInterval,
        bootSessionUUID: String,
        isCompleted: Bool = false,
        transitionToHardAt: Date,
        lastObservedWall: Date? = nil,
        lastObservedMonotonic: TimeInterval? = nil,
        accruedMonotonicElapsed: TimeInterval = 0,
        isTampered: Bool = false,
        sequence: UInt64 = 0
    ) {
        self.calibrationStartedAt = calibrationStartedAt
        self.calibrationStartedMonotonic = calibrationStartedMonotonic
        self.bootSessionUUID = bootSessionUUID
        self.isCompleted = isCompleted
        self.transitionToHardAt = transitionToHardAt
        self.lastObservedWall = lastObservedWall
        self.lastObservedMonotonic = lastObservedMonotonic
        self.accruedMonotonicElapsed = max(0, accruedMonotonicElapsed)
        self.isTampered = isTampered
        self.sequence = sequence
    }

    /// Sealed fail-closed row. Never a fresh 3-day window.
    public static func failClosedHard(
        nowWall: Date,
        nowMono: TimeInterval,
        bootSessionUUID: String
    ) -> CalibrationState {
        CalibrationState(
            calibrationStartedAt: nowWall,
            calibrationStartedMonotonic: nowMono,
            bootSessionUUID: bootSessionUUID,
            isCompleted: true,
            transitionToHardAt: nowWall,
            lastObservedWall: nowWall,
            lastObservedMonotonic: nowMono,
            accruedMonotonicElapsed: CalibrationCoordinator.softModeDuration,
            isTampered: true,
            sequence: 0
        )
    }
}

/// Query surface for the command dashboard and enforcement overlay.
public struct CalibrationSnapshot: Sendable, Equatable {
    public var phase: CalibrationPhase
    public var state: CalibrationState
    public var remainingSeconds: TimeInterval
    public var remainingCaption: String
    public var bannerCaption: String
    public var isSoftModeActive: Bool
    public var isClockTampered: Bool
    public var currentDay: Int

    public init(
        phase: CalibrationPhase,
        state: CalibrationState,
        remainingSeconds: TimeInterval,
        isClockTampered: Bool
    ) {
        self.phase = phase
        self.state = state
        self.remainingSeconds = max(0, remainingSeconds)
        self.remainingCaption = GovernanceLockPolicy.formattedCountdown(remainingSeconds)
        self.bannerCaption = phase.bannerCaption
        self.isSoftModeActive = phase.isSoft
        self.isClockTampered = isClockTampered
        self.currentDay = phase.dayNumber
    }

    public var enforcementMode: EnforcementMode {
        phase.enforcementMode
    }

    public static let proof = CalibrationSnapshot(
        phase: .day2,
        state: CalibrationState(
            calibrationStartedAt: Date(timeIntervalSince1970: 1_788_912_000),
            calibrationStartedMonotonic: 0,
            bootSessionUUID: "proof-boot",
            isCompleted: false,
            transitionToHardAt: Date(timeIntervalSince1970: 1_789_084_800)
        ),
        remainingSeconds: 36 * 3600 + 12 * 60,
        isClockTampered: false
    )
}

/// SQLite / in-memory seam for calibration persistence.
public protocol CalibrationStoring: Sendable {
    func loadCalibrationState() throws -> CalibrationState?
    func saveCalibrationState(_ state: CalibrationState) throws
    func loadCalibrationEnvelope() throws -> CalibrationSealEnvelope?
    func saveCalibrationEnvelope(_ envelope: CalibrationSealEnvelope) throws
    func recordSoftInfraction(_ event: SoftInfractionEvent) throws
    func softInfractionCount() throws -> Int
}

public final class InMemoryCalibrationStore: CalibrationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state: CalibrationState?
    private var envelope: CalibrationSealEnvelope?
    private var infractions: [SoftInfractionEvent] = []

    public init(state: CalibrationState? = nil) {
        self.state = state
    }

    public func loadCalibrationState() throws -> CalibrationState? {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func saveCalibrationState(_ state: CalibrationState) throws {
        lock.lock()
        self.state = state
        lock.unlock()
    }

    public func loadCalibrationEnvelope() throws -> CalibrationSealEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return envelope
    }

    public func saveCalibrationEnvelope(_ envelope: CalibrationSealEnvelope) throws {
        lock.lock()
        self.envelope = envelope
        lock.unlock()
    }

    public func recordSoftInfraction(_ event: SoftInfractionEvent) throws {
        lock.lock()
        infractions.append(event)
        lock.unlock()
    }

    public func softInfractionCount() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return infractions.count
    }
}
