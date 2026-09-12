import Foundation
import Testing
import ZoidLockInCore
import ZoidLockInEconomy

@Suite("ExchangeEngine")
struct ExchangeEngineTests {
    @Test("90-minute morning block mints 3.0; afternoon mints 1.5")
    func morningMomentumVersusAfternoon() throws {
        let morning = EngineHarness(hour: 8, minute: 0)
        try morning.engine.startFocus()
        morning.advance(FocusMinting.morningBlockSeconds)
        let finished = try morning.engine.completeFocus()
        #expect(finished.multiplierApplied == 2.0)
        #expect(finished.creditsEarned == 3.0)
        #expect(morning.engine.walletBalance == 3.0)

        let afternoon = EngineHarness(hour: 13, minute: 0)
        try afternoon.engine.startFocus()
        afternoon.advance(FocusMinting.morningBlockSeconds)
        let later = try afternoon.engine.completeFocus()
        #expect(later.multiplierApplied == 1.0)
        #expect(later.creditsEarned == 1.5)
        #expect(afternoon.engine.walletBalance == 1.5)
    }

    @Test("30-minute milestones mint 0.5 at the standard rate before completion")
    func halfHourMilestones() throws {
        let harness = EngineHarness(hour: 14, minute: 0)
        try harness.engine.startFocus()
        harness.advance(1_800)
        try harness.engine.tick()
        #expect(harness.engine.walletBalance == 0.5)
        harness.advance(1_800)
        try harness.engine.tick()
        #expect(harness.engine.walletBalance == 1.0)
    }

    @Test("interruptions under 300 seconds preserve elapsed progress")
    func graceWindowPreservesProgress() throws {
        let harness = EngineHarness(hour: 8, minute: 0)
        try harness.engine.startFocus()
        harness.advance(1_800)
        try harness.engine.tick()
        #expect(harness.engine.walletBalance == 0.5)

        harness.activity.setIdleSeconds(299)
        try harness.engine.tick()
        #expect(harness.engine.activeFocusSession?.state == .pausedGrace)
        #expect(harness.engine.activeFocusSession?.elapsedSeconds ?? 0 >= 1_800)

        harness.activity.setIdleSeconds(0)
        try harness.engine.tick()
        #expect(harness.engine.activeFocusSession?.state == .active)

        harness.advance(3_600)
        let completed = try harness.engine.completeFocus()
        #expect(completed.state == .completed)
        #expect(completed.elapsedSeconds >= 5_400)
        #expect(completed.creditsEarned == 3.0)
        #expect(harness.engine.walletBalance == 3.0)
    }

    @Test("interruptions of 300 seconds abandon the block without a morning bonus")
    func graceExpiryAbandons() throws {
        let harness = EngineHarness(hour: 8, minute: 0)
        try harness.engine.startFocus()
        harness.advance(1_800)
        try harness.engine.tick()
        #expect(harness.engine.walletBalance == 0.5)

        harness.activity.setIdleSeconds(300)
        try harness.engine.tick()
        #expect(harness.engine.activeFocusSession?.state == .abandoned)

        do {
            _ = try harness.engine.completeFocus()
            Issue.record("abandoned sessions cannot complete")
        } catch let error as ExchangeEngineError {
            #expect(error == .sessionAbandoned)
        }
        #expect(harness.engine.walletBalance == 0.5)
    }

    @Test("event-clock idle detector reports seconds since the last physical event")
    func mockableEventClock() {
        let eventClock = ManualMonotonicClock(startingAt: 10)
        let detector = ManualActivityDetector(eventClock: eventClock, lastEventAt: 10)
        #expect(detector.secondsSinceLastPhysicalEvent() == 0)
        eventClock.advance(by: 299)
        #expect(detector.secondsSinceLastPhysicalEvent() == 299)
        eventClock.advance(by: 1)
        #expect(detector.secondsSinceLastPhysicalEvent() == 300)
        detector.recordPhysicalEvent(at: eventClock.nowSeconds())
        #expect(detector.secondsSinceLastPhysicalEvent() == 0)
    }

    @Test("CGEvent idle monitor uses the injected seconds-since-event source")
    func cgEventMonitorIsMockable() {
        let monitor = CGEventIdleMonitor { _ in 42 }
        #expect(monitor.secondsSinceLastPhysicalEvent() == 42)
    }

    @Test("curfew at 22:00 blocks entertainment purchases but allows bed")
    func curfewBlocksPurchases() throws {
        let harness = EngineHarness(hour: 8, minute: 0)
        try harness.engine.startFocus()
        harness.advance(FocusMinting.morningBlockSeconds)
        try harness.engine.completeFocus()
        #expect(harness.engine.walletBalance == 3.0)

        harness.jumpTo(year: 2026, month: 9, day: 10, hour: 21, minute: 59, second: 59)
        try harness.engine.purchase(.food)
        #expect(harness.engine.walletBalance == 0.5)

        harness.jumpTo(year: 2026, month: 9, day: 10, hour: 22, minute: 0)
        do {
            _ = try harness.engine.purchase(.food)
            Issue.record("food should be blocked at 22:00")
        } catch let error as ExchangeEngineError {
            #expect(error == .curfew)
        }
        do {
            _ = try harness.engine.purchase(.streaming)
            Issue.record("streaming should be blocked at 22:00")
        } catch let error as ExchangeEngineError {
            #expect(error == .curfew)
        }
        #expect(harness.engine.walletBalance == 0.5)

        let beforeBed = EngineHarness(hour: 8, minute: 0)
        try beforeBed.engine.startFocus()
        beforeBed.advance(FocusMinting.morningBlockSeconds)
        try beforeBed.engine.completeFocus()
        beforeBed.jumpTo(year: 2026, month: 9, day: 10, hour: 22, minute: 30)
        try beforeBed.engine.purchase(.bed)
        #expect(beforeBed.engine.walletBalance == 0)
    }

    @Test("midnight reconciliation sweeps surplus, increments streak, and resets the wallet")
    func midnightSurplusAndStreak() throws {
        let harness = EngineHarness(hour: 8, minute: 0)
        try harness.engine.startFocus()
        harness.advance(FocusMinting.morningBlockSeconds)
        try harness.engine.completeFocus()
        #expect(harness.engine.walletBalance == 3.0)

        harness.jumpTo(year: 2026, month: 9, day: 11, hour: 0, minute: 0, second: 1)
        let recon = try harness.engine.reconcileIfNeeded()
        let record = try #require(recon)
        #expect(record.date == "2026-09-10")
        #expect(record.earnedCredits == 3.0)
        #expect(record.sweptToVault == 3.0)
        #expect(record.victoryStreakCount == 1)
        #expect(record.deficitStrikeApplied == false)
        #expect(record.fridayRestMode == false)
        #expect(harness.engine.walletBalance == 0)
        #expect(try harness.ledger.loadVault().totalSurplusCredits == 3.0)
        #expect(try harness.ledger.loadVault().currentStreak == 1)
        #expect(try harness.ledger.loadVault().highestStreak == 1)
    }

    @Test("earning below 3.0 on a non-Friday applies a -1.0 deficit strike")
    func deficitStrike() throws {
        let harness = EngineHarness(hour: 14, minute: 0)
        try harness.engine.startFocus()
        harness.advance(1_800)
        try harness.engine.completeFocus()
        #expect(harness.engine.walletBalance == 0.5)

        harness.jumpTo(year: 2026, month: 9, day: 11, hour: 0, minute: 0, second: 1)
        let recon = try #require(try harness.engine.reconcileIfNeeded())
        #expect(recon.deficitStrikeApplied)
        #expect(recon.date == "2026-09-10")
        #expect(recon.earnedCredits == 0.5)
        #expect(recon.sweptToVault == 0.5)
        #expect(recon.deficitStrikeApplied)
        #expect(recon.victoryStreakCount == 0)
        #expect(harness.engine.walletBalance == -1.0)
        #expect(try harness.ledger.loadVault().currentStreak == 0)
    }

    @Test("unlevied emergency incidents net -2.0 at reconciliation")
    func emergencyIncidentNetting() throws {
        let harness = EngineHarness(hour: 8, minute: 0)
        let incident = EmergencyIncidentRecord.emergency(
            monotonicStartedAtSeconds: 0,
            utcTimestamp: harness.wall.now(),
            bootSessionUUID: "boot-economy"
        )
        try harness.incidents.append(incident)
        try harness.engine.startFocus()
        harness.advance(FocusMinting.morningBlockSeconds)
        try harness.engine.completeFocus()

        harness.jumpTo(year: 2026, month: 9, day: 11, hour: 0, minute: 0, second: 1)
        let recon = try #require(try harness.engine.reconcileIfNeeded())
        #expect(recon.earnedCredits == 3.0)
        #expect(recon.victoryStreakCount == 1)
        #expect(harness.engine.walletBalance == -2.0)

        let penalties = try harness.ledger.allTransactions().filter { $0.transactionType == .penalty }
        #expect(penalties.count == 1)
        #expect(penalties[0].amount == -2.0)
        #expect(penalties[0].referenceID == incident.id.uuidString)

        let again = try harness.engine.reconcileIfNeeded()
        #expect(again == nil)
        #expect(harness.engine.walletBalance == -2.0)
        #expect(try harness.ledger.allTransactions().filter { $0.transactionType == .penalty }.count == 1)
    }

    @Test("Friday rest zeros basic comforts and skips deficit strikes")
    func fridayRestMode() throws {
        let friday = EngineHarness(year: 2026, month: 9, day: 11, hour: 10, minute: 0)
        #expect(friday.civil.isFriday(friday.wall.now()))
        try friday.engine.purchase(.food)
        #expect(friday.engine.walletBalance == 0)
        try friday.engine.purchase(.bed)
        #expect(friday.engine.walletBalance == 0)
        try friday.engine.purchase(.phone)
        #expect(friday.engine.walletBalance == 0)

        do {
            _ = try friday.engine.purchase(.outing)
            Issue.record("outing still costs 5.0 on Friday")
        } catch let error as ExchangeEngineError {
            guard case .insufficientCredits(let need, let have) = error else {
                Issue.record("expected insufficient credits, got \(error)")
                return
            }
            #expect(need == 5.0)
            #expect(have == 0)
        }

        friday.jumpTo(year: 2026, month: 9, day: 12, hour: 0, minute: 0, second: 1)
        let recon = try #require(try friday.engine.reconcileIfNeeded())
        #expect(recon.fridayRestMode)
        #expect(recon.deficitStrikeApplied == false)
        #expect(recon.earnedCredits == 0)
        #expect(friday.engine.walletBalance == 0)
    }

    @Test("wall-clock jumps against the monotonic baseline lock credit writes")
    func antiTimeTravel() throws {
        let harness = EngineHarness(hour: 8, minute: 0)
        try harness.engine.startFocus()
        harness.advance(10)
        try harness.engine.tick()

        harness.wall.advance(by: 3 * 3_600)
        do {
            _ = try harness.engine.tick()
            Issue.record("tampered clock must lock writes")
        } catch let error as ExchangeEngineError {
            guard case .clockTampered(let skew) = error else {
                Issue.record("expected clockTampered, got \(error)")
                return
            }
            #expect(abs(skew) > TimeTravelGuard.maxSkewSeconds)
        }
        #expect(harness.engine.isClockTampered)
        do {
            _ = try harness.engine.purchase(.rest)
            Issue.record("purchases must lock after tamper")
        } catch let error as ExchangeEngineError {
            guard case .clockTampered = error else {
                Issue.record("expected clockTampered, got \(error)")
                return
            }
        }
    }

    @Test("SQLite ledger is interchangeable with the in-memory engine store")
    func sqliteBackedMorningBlock() throws {
        let ledger = try SQLiteEconomicLedger(fileURL: EconomicLedgerLocation.makeIsolatedFileURL())
        let harness = EngineHarness(hour: 8, minute: 0, ledger: ledger)
        try harness.engine.startFocus()
        harness.advance(FocusMinting.morningBlockSeconds)
        try harness.engine.completeFocus()
        #expect(try ledger.latestBalance() == 3.0)
        #expect(try ledger.allTransactions().contains { $0.description.contains("Morning Momentum") })
    }

    @Test("victory streak increments across two target days then resets on deficit")
    func streakProgression() throws {
        let harness = EngineHarness(hour: 8, minute: 0)
        try harness.engine.startFocus()
        harness.advance(FocusMinting.morningBlockSeconds)
        try harness.engine.completeFocus()
        harness.jumpTo(year: 2026, month: 9, day: 11, hour: 0, minute: 0, second: 1)
        _ = try harness.engine.reconcileIfNeeded()
        #expect(try harness.ledger.loadVault().currentStreak == 1)

        harness.jumpTo(year: 2026, month: 9, day: 12, hour: 8, minute: 0)
        try harness.engine.startFocus()
        harness.advance(FocusMinting.morningBlockSeconds)
        try harness.engine.completeFocus()
        harness.jumpTo(year: 2026, month: 9, day: 13, hour: 0, minute: 0, second: 1)
        let second = try #require(try harness.engine.reconcileIfNeeded())
        #expect(second.date == "2026-09-12")
        #expect(second.victoryStreakCount == 2)
        #expect(try harness.ledger.loadVault().highestStreak == 2)
    }
}

final class EngineHarness: @unchecked Sendable {
    let civil: LocalCivilClock
    let wall: ManualWallClock
    let mono: ManualMonotonicClock
    let activity: ManualActivityDetector
    let ledger: any EconomicLedger
    let incidents: InMemoryEmergencyIncidentStore
    let engine: ExchangeEngine

    init(
        year: Int = 2026,
        month: Int = 9,
        day: Int = 10,
        hour: Int,
        minute: Int,
        ledger: any EconomicLedger = InMemoryEconomicLedger()
    ) {
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let civil = LocalCivilClock(timeZone: timeZone)
        let start = civil.date(year: year, month: month, day: day, hour: hour, minute: minute)
        self.civil = civil
        self.wall = ManualWallClock(start)
        self.mono = ManualMonotonicClock()
        self.activity = ManualActivityDetector(idleSeconds: 0)
        self.ledger = ledger
        self.incidents = InMemoryEmergencyIncidentStore()
        self.engine = ExchangeEngine(
            ledger: ledger,
            incidentStore: incidents,
            clock: mono,
            wallClock: wall,
            activityDetector: activity,
            timeZone: timeZone
        )
    }

    func advance(_ seconds: TimeInterval) {
        mono.advance(by: seconds)
        wall.advance(by: seconds)
    }

    func jumpTo(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int = 0) {
        let target = civil.date(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        let delta = target.timeIntervalSince(wall.now())
        wall.set(target)
        mono.advance(by: delta)
    }
}
