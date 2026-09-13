import Darwin
import Foundation
import Testing
import ZoidLockInCore
import ZoidLockInEconomy
import ZoidLockInEnforcer
import ZoidLockInFilterExtension
import ZoidLockInIPC

@Suite("Slice 3 adversarial hardening")
struct Slice3AdversarialHardeningTests {
    @Test("food pass unblocks food but drops YouTube and kills Steam")
    func foodPassIsCategorical() async throws {
        let runtime = HardeningProcessRuntime(
            processes: [RunningProcess(pid: 202, name: "Steam")]
        )
        let hub = FilterPolicyHub()
        let daemon = EnforcementDaemon(
            processSentinel: ProcessSentinel(runtime: runtime, scanInterval: 1.5),
            filterPolicyHub: hub,
            incidentStore: InMemoryEmergencyIncidentStore(),
            bootSessionUUID: "boot-food"
        )
        daemon.commitKindScopedPass(kind: .food, durationSeconds: 1_800)

        let engine = ContentFilterEngine(statusReader: hub)
        #expect(engine.verdict(hostname: "talabat.com", port: 443, transport: .tcp) == .allow)
        #expect(engine.verdict(hostname: "www.ubereats.com", port: 443, transport: .tcp) == .allow)
        #expect(engine.verdict(hostname: "deliveroo.com", port: 443, transport: .tcp) == .allow)
        #expect(engine.verdict(hostname: "youtube.com", port: 443, transport: .tcp) == .drop)
        #expect(engine.verdict(hostname: "netflix.com", port: 443, transport: .tcp) == .drop)
        #expect(engine.verdict(hostname: nil, port: 443, transport: .udp) == .drop)

        let foodEvaluator = FilterFlowEvaluator(policy: .lockedDown, activePassKind: .food)
        #expect(
            foodEvaluator.verdict(
                for: FilterFlowRequest(hostname: "talabat.com", port: 443, transport: .tcp)
            ) == .allow
        )
        #expect(
            foodEvaluator.verdict(
                for: FilterFlowRequest(hostname: "youtube.com", port: 443, transport: .tcp)
            ) == .drop
        )

        let killed = daemon.processSentinel.scanAndTerminate()
        #expect(killed.map(\.pid).contains(202))
        #expect(runtime.sentSignals[202] == [SIGSTOP, SIGKILL])
        #expect(try await daemon.queryStatus().activePassKind == .food)
        #expect(daemon.currentPolicy.mode == .hard)
    }

    @Test("gaming pass unblocks Steam but drops Talabat")
    func gamingPassIsCategorical() async throws {
        let runtime = HardeningProcessRuntime(
            processes: [
                RunningProcess(pid: 202, name: "Steam"),
                RunningProcess(pid: 303, name: "Discord"),
            ]
        )
        let hub = FilterPolicyHub()
        let daemon = EnforcementDaemon(
            processSentinel: ProcessSentinel(runtime: runtime, scanInterval: 1.5),
            filterPolicyHub: hub,
            incidentStore: InMemoryEmergencyIncidentStore(),
            bootSessionUUID: "boot-gaming"
        )
        daemon.commitKindScopedPass(kind: .gaming, durationSeconds: 1_800)

        let engine = ContentFilterEngine(statusReader: hub)
        #expect(engine.verdict(hostname: "talabat.com", port: 443, transport: .tcp) == .drop)
        #expect(engine.verdict(hostname: "youtube.com", port: 443, transport: .tcp) == .drop)
        #expect(engine.verdict(hostname: "netflix.com", port: 443, transport: .tcp) == .drop)

        #expect(daemon.processSentinel.scanAndTerminate().isEmpty)
        #expect(runtime.sentSignals.isEmpty)
        #expect(daemon.currentPolicy.mode == .soft)
        #expect(try await daemon.queryStatus().activePassKind == .gaming)
    }

    @Test("phone pass relaxes WhatsApp and Telegram only; streaming pass relaxes YouTube")
    func phoneAndStreamingPassScopes() {
        let phone = FilterFlowEvaluator(policy: .lockedDown, activePassKind: .phone)
        #expect(
            phone.verdict(
                for: FilterFlowRequest(hostname: "web.whatsapp.com", port: 443, transport: .tcp)
            ) == .allow
        )
        #expect(
            phone.verdict(
                for: FilterFlowRequest(hostname: "telegram.org", port: 443, transport: .tcp)
            ) == .allow
        )
        #expect(
            phone.verdict(
                for: FilterFlowRequest(hostname: "youtube.com", port: 443, transport: .tcp)
            ) == .drop
        )
        #expect(
            phone.verdict(
                for: FilterFlowRequest(hostname: "talabat.com", port: 443, transport: .tcp)
            ) == .drop
        )

        let streaming = FilterFlowEvaluator(policy: .lockedDown, activePassKind: .streaming)
        #expect(
            streaming.verdict(
                for: FilterFlowRequest(hostname: "youtube.com", port: 443, transport: .tcp)
            ) == .allow
        )
        #expect(
            streaming.verdict(
                for: FilterFlowRequest(hostname: "netflix.com", port: 443, transport: .tcp)
            ) == .allow
        )
        #expect(
            streaming.verdict(
                for: FilterFlowRequest(hostname: "twitch.tv", port: 443, transport: .tcp)
            ) == .allow
        )
        #expect(
            streaming.verdict(
                for: FilterFlowRequest(hostname: "talabat.com", port: 443, transport: .tcp)
            ) == .drop
        )

        let locked = FilterFlowEvaluator(policy: .lockedDown, activePassKind: nil)
        #expect(
            locked.verdict(
                for: FilterFlowRequest(hostname: "talabat.com", port: 443, transport: .tcp)
            ) == .drop
        )
    }

    @Test("authenticated incident query feeds the UI ledger without reading /var/db")
    func xpcIncidentQueryReachesWallet() async throws {
        let harness = EngineHarness(hour: 8, minute: 0)
        let privileged = InMemoryEmergencyIncidentStore()
        let daemon = EnforcementDaemon(
            clock: ManualMonotonicClock(),
            wallClock: FixedWallClock(harness.wall.now()),
            incidentStore: privileged,
            bootSessionUUID: "boot-incidents"
        )
        try await daemon.engageEmergencySafetyValve()
        let wire = try JSONEncoder().encode(try await daemon.queryUnleviedEmergencyIncidents())
        let transmitted = try JSONDecoder().decode([EmergencyIncidentRecord].self, from: wire)
        #expect(transmitted.count == 1)
        #expect(transmitted[0].isLevied == false)

        let cache = CachedEmergencyIncidentStore()
        do {
            try cache.append(transmitted[0])
            Issue.record("user-space cache must refuse invented incidents")
        } catch EmergencyIncidentStoreError.userSpaceCannotInventIncidents {
            ()
        }

        let engine = ExchangeEngine(
            ledger: harness.ledger,
            incidentStore: cache,
            clock: harness.mono,
            focusClock: harness.mono,
            wallClock: harness.wall,
            activityDetector: harness.activity,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        try engine.startFocus()
        harness.advance(FocusMinting.morningBlockSeconds)
        try engine.completeFocus()
        #expect(engine.walletBalance == 3.0)

        let coordinator = EconomyTickCoordinator(engine: engine, incidentCache: cache)
        harness.jumpTo(year: 2026, month: 9, day: 11, hour: 0, minute: 0, second: 1)
        let snapshot = await coordinator.reconcileIncidentsAndTick(
            fetchIncidents: { try await daemon.queryUnleviedEmergencyIncidents() },
            markLevied: { try await daemon.markEmergencyIncidentLevied(uuid: $0) }
        )
        #expect(snapshot.walletBalance == -2.0)
        #expect(try await daemon.queryUnleviedEmergencyIncidents().isEmpty)
        #expect(privileged.unleviedIncidents().isEmpty)
        #expect(coordinator.queueLabel == "zoidlockin.economy")

        let privilegedPath = FileEmergencyIncidentStore(
            directory: FileEmergencyIncidentStore.defaultPrivilegedDirectory
        )
        #expect(privilegedPath.allIncidents().isEmpty)

        let appSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("ZoidLockInApp")
            .appendingPathComponent("ZoidLockInApp.swift")
        let appText = try String(contentsOf: appSource, encoding: .utf8)
        #expect(!appText.contains("defaultPrivilegedDirectory"))
        #expect(appText.contains("queryUnleviedEmergencyIncidents"))
        #expect(appText.contains("CachedEmergencyIncidentStore"))
        #expect(appText.contains("zoidlockin.economy"))
    }

    @Test("human typing pauses of 30s stay active; longer pauses grace then abandon")
    func presenceWindowAllowsHumanTyping() throws {
        #expect(FocusMinting.presence(idleSeconds: 0) == .active)
        #expect(FocusMinting.presence(idleSeconds: 0.4) == .active)
        #expect(FocusMinting.presence(idleSeconds: 30) == .active)
        #expect(FocusMinting.presence(idleSeconds: 30.001) == .grace)
        #expect(FocusMinting.presence(idleSeconds: 299) == .grace)
        #expect(FocusMinting.presence(idleSeconds: 300) == .abandoned)

        let typing = EngineHarness(hour: 14, minute: 0)
        try typing.engine.startFocus()
        typing.advance(1_800)
        typing.activity.setIdleSeconds(0.4)
        try typing.engine.tick()
        #expect(typing.engine.activeFocusSession?.state == .active)
        #expect(typing.engine.walletBalance == 0.5)

        typing.activity.setIdleSeconds(30)
        typing.advance(1_800)
        try typing.engine.tick()
        #expect(typing.engine.activeFocusSession?.state == .active)
        #expect(typing.engine.walletBalance == 1.0)

        typing.activity.setIdleSeconds(30.001)
        try typing.engine.tick()
        #expect(typing.engine.activeFocusSession?.state == .pausedGrace)
        #expect(typing.engine.walletBalance == 1.0)

        typing.activity.setIdleSeconds(300)
        try typing.engine.tick()
        #expect(typing.engine.activeFocusSession?.state == .abandoned)
    }

    @Test("simulated sleep does not mint focus credits")
    func uptimeClockIgnoresSleep() throws {
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let civil = LocalCivilClock(timeZone: timeZone)
        let start = civil.date(year: 2026, month: 9, day: 10, hour: 8, minute: 0)
        let sleepClock = SleepSimulationClock()
        let wall = ManualWallClock(start)
        let activity = ManualActivityDetector(idleSeconds: 0)
        let ledger = InMemoryEconomicLedger()
        let engine = ExchangeEngine(
            ledger: ledger,
            incidentStore: InMemoryEmergencyIncidentStore(),
            clock: sleepClock,
            focusClock: sleepClock.uptimeClock,
            wallClock: wall,
            activityDetector: activity,
            timeZone: timeZone
        )

        try engine.startFocus()
        sleepClock.advanceAwake(by: 1_800)
        wall.advance(by: 1_800)
        try engine.tick()
        #expect(engine.walletBalance == 0.5)
        let elapsedBeforeSleep = engine.activeFocusSession?.elapsedSeconds ?? 0

        sleepClock.simulateSleep(for: 8 * 3_600)
        wall.advance(by: 8 * 3_600)
        try engine.tick()
        #expect(engine.walletBalance == 0.5)
        #expect(engine.activeFocusSession?.elapsedSeconds ?? 0 == elapsedBeforeSleep)
        #expect(engine.isClockTampered == false)
    }

    @Test("multi-day catch-up walks Friday rest then weekend deficits")
    func multiDayCatchUp() throws {
        let harness = EngineHarness(hour: 8, minute: 0)
        try harness.engine.startFocus()
        harness.advance(FocusMinting.morningBlockSeconds)
        try harness.engine.completeFocus()
        #expect(harness.engine.walletBalance == 3.0)

        harness.jumpTo(year: 2026, month: 9, day: 14, hour: 9, minute: 0)
        let last = try #require(try harness.engine.reconcileIfNeeded())
        #expect(last.date == "2026-09-13")

        let thursday = try #require(try harness.ledger.reconciliation(onDay: "2026-09-10"))
        let friday = try #require(try harness.ledger.reconciliation(onDay: "2026-09-11"))
        let saturday = try #require(try harness.ledger.reconciliation(onDay: "2026-09-12"))
        let sunday = try #require(try harness.ledger.reconciliation(onDay: "2026-09-13"))

        #expect(thursday.earnedCredits == 3.0)
        #expect(thursday.deficitStrikeApplied == false)
        #expect(thursday.victoryStreakCount == 1)
        #expect(friday.fridayRestMode)
        #expect(friday.deficitStrikeApplied == false)
        #expect(saturday.deficitStrikeApplied)
        #expect(sunday.deficitStrikeApplied)
        #expect(harness.engine.walletBalance == -2.0)
        #expect(try harness.ledger.loadVault().currentStreak == 0)
        #expect(try harness.ledger.loadVault().totalSurplusCredits == 3.0)
    }

    @Test("BEGIN IMMEDIATE serializes two writers so food cannot be double-spent")
    func beginImmediateSerializesDoubleSpend() async throws {
        let url = EconomicLedgerLocation.makeIsolatedFileURL()
        let ledgerA = try SQLiteEconomicLedger(fileURL: url)
        let ledgerB = try SQLiteEconomicLedger(fileURL: url)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let civil = LocalCivilClock(timeZone: timeZone)
        let start = civil.date(year: 2026, month: 9, day: 10, hour: 10, minute: 0)
        try ledgerA.appendTransaction(
            WalletTransaction(
                timestamp: start,
                amount: 2.5,
                balanceAfter: 2.5,
                transactionType: .mint,
                description: "seed"
            )
        )
        #expect(try ledgerB.latestBalance() == 2.5)

        func makeEngine(_ ledger: SQLiteEconomicLedger) -> ExchangeEngine {
            ExchangeEngine(
                ledger: ledger,
                clock: ManualMonotonicClock(),
                focusClock: ManualMonotonicClock(),
                wallClock: ManualWallClock(start),
                activityDetector: ManualActivityDetector(idleSeconds: 0),
                timeZone: timeZone
            )
        }

        let engineA = makeEngine(ledgerA)
        let engineB = makeEngine(ledgerB)

        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            group.addTask {
                do {
                    _ = try engineA.purchase(.food)
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                do {
                    _ = try engineB.purchase(.food)
                    return true
                } catch {
                    return false
                }
            }
            var collected: [Bool] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        #expect(outcomes.filter { $0 }.count == 1)
        #expect(try ledgerA.latestBalance() == 0)
        let spends = try ledgerA.allTransactions().filter { $0.transactionType == .spend }
        #expect(spends.count == 1)
    }

    @Test("economy ticks run on the serial economy queue")
    func ticksRunOffCaller() async throws {
        let harness = EngineHarness(hour: 8, minute: 0)
        try harness.engine.startFocus()
        let coordinator = EconomyTickCoordinator(engine: harness.engine)
        harness.advance(1_800)
        let snapshot = await coordinator.tick()
        #expect(snapshot.walletBalance == 0.5)
        #expect(coordinator.queueLabel == "zoidlockin.economy")
    }
}

private final class HardeningProcessRuntime: ProcessRuntimeControlling, @unchecked Sendable {
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
        if signal == SIGKILL {
            processes.removeAll { $0.pid == pid }
        }
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
