import Foundation
import Testing
import ZoidLockInCore
import ZoidLockInEnforcer
import ZoidLockInIPC

@Suite("Emergency safety valve")
struct EmergencySafetyValveTests {
    @Test("hold progression remains incomplete until 5.0 seconds")
    func holdProgression() {
        var engine = EmergencySafetyValveEngine()
        engine.press(at: 0)
        engine.tick(at: 2.5)
        #expect(engine.state.phase == .holding)
        #expect(engine.state.elapsedSeconds == 2.5)
        #expect(engine.state.confirmationPrompt == nil)
        #expect(!engine.state.canConfirm)

        engine.tick(at: 4.999)
        #expect(engine.state.phase == .holding)
        #expect(!engine.state.canConfirm)

        engine.tick(at: 5.0)
        #expect(engine.state.phase == .readyToConfirm)
        #expect(engine.state.canConfirm)
        #expect(engine.state.confirmationPrompt == EmergencySafetyValveEngine.confirmationPromptText)
    }

    @Test("premature release before 5.0 seconds cancels without side effects")
    func prematureReleaseCancels() async {
        let dispatcher = RecordingDispatcher()
        let mailer = RecordingMailer()
        let debts = InMemoryPendingDebtStore()
        let coordinator = EmergencySafetyValveCoordinator(
            clock: ManualMonotonicClock(),
            wallClock: FixedWallClock(Date(timeIntervalSince1970: 1_700_000_000)),
            debtStore: debts,
            mailer: mailer,
            dispatcher: dispatcher
        )

        coordinator.press(at: 10)
        coordinator.tick(at: 14.9)
        coordinator.release(at: 14.9)

        #expect(coordinator.state.phase == .cancelled)
        #expect(!coordinator.state.canConfirm)

        do {
            try await coordinator.confirm()
            Issue.record("confirm() should fail after a cancelled hold")
        } catch let error as EmergencySafetyValveError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("unexpected error \(error)")
        }

        #expect(dispatcher.engagements == 0)
        #expect(mailer.reports.isEmpty)
        #expect(debts.totalSignedCreditsPendingReconciliation() == 0)
    }

    @Test("successful 5-second hold plus confirm fires XPC, mail, and -2.0 debt")
    func successfulActivation() async throws {
        let dispatcher = RecordingDispatcher()
        let mailer = RecordingMailer(recipient: "founder@mavoid.com")
        let debts = InMemoryPendingDebtStore()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = EmergencySafetyValveCoordinator(
            clock: ManualMonotonicClock(startingAt: 100),
            wallClock: FixedWallClock(timestamp),
            debtStore: debts,
            mailer: mailer,
            dispatcher: dispatcher
        )

        coordinator.press(at: 0)
        coordinator.tick(at: 5)
        #expect(coordinator.state.phase == .readyToConfirm)

        try await coordinator.confirm()

        #expect(coordinator.state.phase == .activated)
        #expect(dispatcher.engagements == 1)
        #expect(debts.totalSignedCreditsPendingReconciliation() == -2.0)
        #expect(debts.recordsPendingReconciliation().count == 1)
        #expect(debts.recordsPendingReconciliation()[0].reason == .emergencyPenalty)
        #expect(debts.recordsPendingReconciliation()[0].levyOnNextReconciliation)

        #expect(mailer.reports.count == 1)
        #expect(mailer.reports[0].durationSeconds == 1800)
        #expect(mailer.reports[0].creditDebt == -2.0)
        #expect(mailer.reports[0].eventType == "EMERGENCY_OVERRIDE")
        #expect(mailer.reports[0].recipient == "founder@mavoid.com")
        #expect(mailer.reports[0].timestamp == timestamp)
    }

    @Test("confirm before the hold completes does not fire")
    func confirmBeforeReadyFails() async {
        let dispatcher = RecordingDispatcher()
        let coordinator = EmergencySafetyValveCoordinator(
            debtStore: InMemoryPendingDebtStore(),
            mailer: RecordingMailer(),
            dispatcher: dispatcher
        )
        coordinator.press(at: 0)
        coordinator.tick(at: 4)

        do {
            try await coordinator.confirm()
            Issue.record("confirm() should fail before 5.0s")
        } catch let error as EmergencySafetyValveError {
            #expect(error == .holdIncomplete)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(dispatcher.engagements == 0)
    }

    @Test("second confirm without a new hold does not double-charge debt")
    func secondConfirmRejected() async throws {
        let dispatcher = RecordingDispatcher()
        let debts = InMemoryPendingDebtStore()
        let coordinator = EmergencySafetyValveCoordinator(
            debtStore: debts,
            mailer: RecordingMailer(),
            dispatcher: dispatcher
        )
        coordinator.press(at: 0)
        coordinator.tick(at: 5)
        try await coordinator.confirm()

        do {
            try await coordinator.confirm()
            Issue.record("second confirm should fail")
        } catch let error as EmergencySafetyValveError {
            #expect(error == .alreadyActivated)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(dispatcher.engagements == 1)
        #expect(debts.totalSignedCreditsPendingReconciliation() == -2.0)
    }
}

@Suite("Daemon-local emergency pass and heartbeat")
struct DaemonEmergencyPassAndHeartbeatTests {
    @Test("emergency pass relaxes domains and process kills for 30 monotonic minutes")
    func emergencyPassActivates() async throws {
        let runtime = ValveTestProcessRuntime(
            processes: [RunningProcess(pid: 202, name: "Steam")]
        )
        let clock = ManualMonotonicClock(startingAt: 1_000)
        let daemon = EnforcementDaemon(
            processSentinel: ProcessSentinel(runtime: runtime, scanInterval: 1.5),
            clock: clock
        )

        #expect(daemon.currentPolicy.flowVerdict(
            hostname: "youtube.com",
            port: 443,
            transport: .tcp
        ) == .drop)

        try await daemon.engageEmergencySafetyValve()

        let status = try await daemon.queryStatus()
        #expect(status.activePassKind == .emergency)
        #expect(!status.isLockedDown)
        #expect(status.remainingPassSeconds == 1800)
        #expect(daemon.currentPolicy.mode == .soft)
        #expect(daemon.currentPolicy.flowVerdict(
            hostname: "youtube.com",
            port: 443,
            transport: .tcp
        ) == .allow)
        #expect(daemon.currentPolicy.flowVerdict(
            hostname: "talabat.com",
            port: 443,
            transport: .tcp
        ) == .allow)
        #expect(daemon.processSentinel.scanAndTerminate().isEmpty)
        #expect(runtime.sentSignals.isEmpty)
    }

    @Test("emergency pass expires on monotonic time and re-locks at minute 30")
    func emergencyPassExpiresAndRelocks() async throws {
        let clock = ManualMonotonicClock(startingAt: 0)
        let daemon = EnforcementDaemon(clock: clock)

        try await daemon.engageEmergencySafetyValve()
        clock.advance(by: 1799)
        daemon.evaluateWatchdogs(at: clock.nowSeconds())
        #expect(daemon.currentPolicy.mode == .soft)
        #expect(try await daemon.queryStatus().remainingPassSeconds == 1)

        clock.advance(by: 1)
        daemon.evaluateWatchdogs(at: clock.nowSeconds())

        let status = try await daemon.queryStatus()
        #expect(status.isLockedDown)
        #expect(status.activePassKind == nil)
        #expect(status.remainingPassSeconds == 0)
        #expect(daemon.currentPolicy.mode == .hard)
        #expect(daemon.currentPolicy.flowVerdict(
            hostname: "youtube.com",
            port: 443,
            transport: .tcp
        ) == .drop)
    }

    @Test("heartbeat loss during an emergency pass preserves the pass until expiry")
    func heartbeatLossPreservesEmergencyPass() async throws {
        let clock = ManualMonotonicClock(startingAt: 0)
        let daemon = EnforcementDaemon(clock: clock)
        try await daemon.engageEmergencySafetyValve()
        daemon.noteClientConnected(at: 0)
        daemon.noteClientDisconnected(at: 1)
        daemon.evaluateWatchdogs(at: 1)

        #expect(daemon.currentPolicy.mode == .soft)
        #expect(try await daemon.queryStatus().activePassKind == .emergency)

        clock.set(1800)
        daemon.evaluateWatchdogs(at: clock.nowSeconds())
        #expect(daemon.currentPolicy.mode == .hard)
        #expect(try await daemon.queryStatus().isLockedDown)
    }

    @Test("silent client for 5 seconds fail-closes custom policy back to lockdown")
    func heartbeatTimeoutRelocks() async throws {
        let clock = ManualMonotonicClock(startingAt: 0)
        let daemon = EnforcementDaemon(clock: clock)
        daemon.applyPolicy(
            EnforcementPolicy(domainRules: DomainFilterRules(blacklistedSuffixes: []))
        )
        #expect(daemon.currentPolicy.flowVerdict(
            hostname: "youtube.com",
            port: 443,
            transport: .tcp
        ) == .allow)

        daemon.noteClientConnected(at: 0)
        clock.advance(by: 4.999)
        daemon.evaluateWatchdogs(at: clock.nowSeconds())
        #expect(daemon.currentPolicy.flowVerdict(
            hostname: "youtube.com",
            port: 443,
            transport: .tcp
        ) == .allow)

        clock.advance(by: 0.001)
        daemon.evaluateWatchdogs(at: clock.nowSeconds())
        #expect(daemon.currentPolicy.flowVerdict(
            hostname: "youtube.com",
            port: 443,
            transport: .tcp
        ) == .drop)
        #expect(daemon.currentPolicy.mode == .hard)
    }

    @Test("end-to-end valve confirm grants a daemon-local pass and records debt")
    func coordinatorDrivesDaemon() async throws {
        let clock = ManualMonotonicClock(startingAt: 0)
        let daemon = EnforcementDaemon(clock: clock)
        let debts = InMemoryPendingDebtStore()
        let mailer = RecordingMailer()
        let coordinator = EmergencySafetyValveCoordinator(
            clock: clock,
            debtStore: debts,
            mailer: mailer,
            dispatcher: daemon
        )

        coordinator.press(at: 0)
        coordinator.release(at: 3)
        #expect(coordinator.state.phase == .cancelled)
        #expect(try await daemon.queryStatus().isLockedDown)

        coordinator.press(at: 10)
        coordinator.tick(at: 15)
        try await coordinator.confirm()

        #expect(try await daemon.queryStatus().activePassKind == .emergency)
        #expect(debts.totalSignedCreditsPendingReconciliation() == -2.0)
        #expect(mailer.reports.count == 1)
    }
}

private final class RecordingDispatcher: EmergencySafetyValveDispatching, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var engagements = 0

    func engageEmergencySafetyValve() async throws {
        increment()
    }

    private func increment() {
        lock.lock()
        engagements += 1
        lock.unlock()
    }
}

private final class RecordingMailer: EmergencyIncidentAlerting, @unchecked Sendable {
    var recipient: String
    private let lock = NSLock()
    private(set) var reports: [EmergencyIncidentReport] = []

    init(recipient: String = "alerts@mavoid.com") {
        self.recipient = recipient
    }

    func dispatchEmergencyIncident(_ report: EmergencyIncidentReport) async throws {
        append(report)
    }

    private func append(_ report: EmergencyIncidentReport) {
        lock.lock()
        reports.append(report)
        lock.unlock()
    }
}

private final class ValveTestProcessRuntime: ProcessRuntimeControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [RunningProcess]
    private var processGroups: [Int32: Int32]
    private(set) var sentSignals: [Int32: [Int32]] = [:]
    private(set) var sentGroupSignals: [Int32: [Int32]] = [:]

    init(processes: [RunningProcess], processGroups: [Int32: Int32] = [:]) {
        self.processes = processes
        self.processGroups = processGroups
    }

    func listRunningProcesses() -> [RunningProcess] {
        lock.lock()
        defer { lock.unlock() }
        return processes
    }

    func terminate(pid: Int32, signal: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        sentSignals[pid, default: []].append(signal)
        return true
    }

    func processGroupID(for pid: Int32) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return processGroups[pid] ?? pid
    }

    func terminateProcessGroup(pgid: Int32, signal: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        sentGroupSignals[pgid, default: []].append(signal)
        return true
    }
}
