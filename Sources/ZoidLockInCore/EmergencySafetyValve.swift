import Foundation

/// Observable hold-state for the Emergency Safety Valve.
public struct EmergencySafetyValveState: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case idle
        case holding
        case readyToConfirm
        case cancelled
        case activated
    }

    public var phase: Phase
    public var elapsedSeconds: TimeInterval
    public var confirmationPrompt: String?

    public init(
        phase: Phase = .idle,
        elapsedSeconds: TimeInterval = 0,
        confirmationPrompt: String? = nil
    ) {
        self.phase = phase
        self.elapsedSeconds = elapsedSeconds
        self.confirmationPrompt = confirmationPrompt
    }

    public var canConfirm: Bool {
        phase == .readyToConfirm
    }
}

public enum EmergencySafetyValveError: Error, Equatable, Sendable {
    case holdIncomplete
    case alreadyActivated
    case cancelled
}

/// Dispatches the privileged emergency unlock. Implemented by the daemon and XPC client.
public protocol EmergencySafetyValveDispatching: Sendable {
    func engageEmergencySafetyValve() async throws
}

/// User-space incident mailer. Failures must not roll back a granted daemon pass.
public protocol EmergencyIncidentAlerting: Sendable {
    var recipient: String { get }
    func dispatchEmergencyIncident(_ report: EmergencyIncidentReport) async throws
}

/// Pure 5-second press-and-hold engine. No XPC, mail, or debt side effects.
public struct EmergencySafetyValveEngine: Sendable, Equatable {
    public static let requiredHoldDuration: TimeInterval = 5.0
    public static let confirmationPromptText =
        "Confirm Emergency Access: This unlocks all distractions for 30 minutes, dispatches an incident audit alert, and levies a mandatory 2-hour focus debt tomorrow."

    public private(set) var state: EmergencySafetyValveState
    private var pressStartedAt: TimeInterval?

    public init() {
        self.state = EmergencySafetyValveState()
        self.pressStartedAt = nil
    }

    public mutating func press(at time: TimeInterval) {
        pressStartedAt = time
        state = EmergencySafetyValveState(
            phase: .holding,
            elapsedSeconds: 0,
            confirmationPrompt: nil
        )
    }

    public mutating func tick(at time: TimeInterval) {
        guard state.phase == .holding, let pressStartedAt else { return }

        let elapsed = max(0, time - pressStartedAt)
        if elapsed >= Self.requiredHoldDuration {
            state = EmergencySafetyValveState(
                phase: .readyToConfirm,
                elapsedSeconds: elapsed,
                confirmationPrompt: Self.confirmationPromptText
            )
        } else {
            state.elapsedSeconds = elapsed
        }
    }

    /// Release before 5.0s cancels with no side effects. Release after 5.0s keeps
    /// the confirmation prompt armed so the user can click Confirm.
    public mutating func release(at time: TimeInterval) {
        switch state.phase {
        case .holding:
            let start = pressStartedAt ?? time
            let elapsed = max(0, time - start)
            if elapsed >= Self.requiredHoldDuration {
                state = EmergencySafetyValveState(
                    phase: .readyToConfirm,
                    elapsedSeconds: elapsed,
                    confirmationPrompt: Self.confirmationPromptText
                )
            } else {
                state = EmergencySafetyValveState(
                    phase: .cancelled,
                    elapsedSeconds: elapsed,
                    confirmationPrompt: nil
                )
            }
            pressStartedAt = nil
        case .idle, .readyToConfirm, .cancelled, .activated:
            break
        }
    }

    public mutating func cancel() {
        guard state.phase == .holding || state.phase == .readyToConfirm else { return }
        state = EmergencySafetyValveState(
            phase: .cancelled,
            elapsedSeconds: state.elapsedSeconds,
            confirmationPrompt: nil
        )
        pressStartedAt = nil
    }

    public mutating func markActivated() {
        state = EmergencySafetyValveState(
            phase: .activated,
            elapsedSeconds: state.elapsedSeconds,
            confirmationPrompt: nil
        )
        pressStartedAt = nil
    }
}

/// User-space Emergency Safety Valve: 5s hold, confirmation, then XPC + mail + debt.
public final class EmergencySafetyValveCoordinator: @unchecked Sendable {
    public static let requiredHoldDuration: TimeInterval = EmergencySafetyValveEngine.requiredHoldDuration
    public static let emergencyPassDurationSeconds = Int(DaemonLocalPass.emergencyDurationSeconds)
    public static let emergencyDebtCredits = PendingDebtRecord.emergencyPenaltyCredits

    private let lock = NSLock()
    private var engine = EmergencySafetyValveEngine()
    private let clock: any MonotonicTimeProviding
    private let wallClock: any WallClockProviding
    private let debtStore: any PendingDebtStoring
    private let mailer: any EmergencyIncidentAlerting
    private let dispatcher: any EmergencySafetyValveDispatching

    private var confirmInFlight = false
    public private(set) var lastMailError: Error?

    public init(
        clock: any MonotonicTimeProviding = MachContinuousTimeClock(),
        wallClock: any WallClockProviding = SystemWallClock(),
        debtStore: any PendingDebtStoring,
        mailer: any EmergencyIncidentAlerting,
        dispatcher: any EmergencySafetyValveDispatching
    ) {
        self.clock = clock
        self.wallClock = wallClock
        self.debtStore = debtStore
        self.mailer = mailer
        self.dispatcher = dispatcher
    }

    public var state: EmergencySafetyValveState {
        withLock { engine.state }
    }

    public func press(at time: TimeInterval? = nil) {
        let now = time ?? clock.nowSeconds()
        withLock { engine.press(at: now) }
    }

    public func tick(at time: TimeInterval? = nil) {
        let now = time ?? clock.nowSeconds()
        withLock { engine.tick(at: now) }
    }

    public func release(at time: TimeInterval? = nil) {
        let now = time ?? clock.nowSeconds()
        withLock { engine.release(at: now) }
    }

    public func cancel() {
        withLock { engine.cancel() }
    }

    /// Fires only after a complete 5.0s hold. The daemon writes the incident and
    /// pass first; mail is best-effort and must not roll back a granted pass.
    public func confirm() async throws {
        try withLock { () throws in
            switch engine.state.phase {
            case .activated:
                throw EmergencySafetyValveError.alreadyActivated
            case .cancelled:
                throw EmergencySafetyValveError.cancelled
            case .idle, .holding:
                throw EmergencySafetyValveError.holdIncomplete
            case .readyToConfirm:
                break
            }
            if confirmInFlight {
                throw EmergencySafetyValveError.alreadyActivated
            }
            confirmInFlight = true
        }
        defer { withLock { confirmInFlight = false } }

        try await dispatcher.engageEmergencySafetyValve()

        let now = clock.nowSeconds()
        debtStore.record(.emergencyPenalty(at: now))
        withLock { engine.markActivated() }

        let report = EmergencyIncidentReport(
            timestamp: wallClock.now(),
            durationSeconds: Self.emergencyPassDurationSeconds,
            recipient: mailer.recipient,
            eventType: "EMERGENCY_OVERRIDE",
            creditDebt: Self.emergencyDebtCredits
        )
        do {
            try await mailer.dispatchEmergencyIncident(report)
        } catch {
            withLock { lastMailError = error }
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
