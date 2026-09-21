import Foundation
import NetworkExtension
import Testing
@testable import ZoidLockInCore
import ZoidLockInEconomy
import ZoidLockInFilterExtension

@Suite("Slice 9 adversarial remediations", .serialized)
struct Slice9AdversarialHardeningTests {
    private static let utc = TimeZone(identifier: "UTC")!

    @Test("direct SQLite tampering of calibration_state fails closed to hard")
    func sqliteTamperingFailsClosedToHard() throws {
        let url = EconomicLedgerLocation.makeIsolatedFileURL()
        let ledger = try SQLiteEconomicLedger(fileURL: url)
        let replica = FileCalibrationSealStore(
            privilegedFileURL: url.deletingLastPathComponent()
                .appendingPathComponent("privileged-calibration.json"),
            fallbackDirectory: url.deletingLastPathComponent(),
            keychainStore: InMemoryKeychainStore()
        )
        let keyProvider = InMemoryCalibrationKeyProvider()
        let wall = ManualWallClock(Self.date(2026, 3, 9, 15, 0))
        let mono = ManualMonotonicClock(startingAt: 10)
        let coordinator = CalibrationCoordinator(
            store: ledger,
            clock: mono,
            wallClock: wall,
            timeTravel: TimeTravelGuard(),
            timeZone: Self.utc,
            bootSessionUUID: "boot-s9-tamper",
            keyProvider: keyProvider,
            replicaSealStore: replica
        )

        let started = coordinator.snapshot()
        #expect(started.phase == .day1)
        #expect(started.enforcementMode == .calibration)
        #expect(try replica.loadEnvelope() != nil)

        try ledger.executeUncheckedSQL("DROP TRIGGER IF EXISTS calibration_state_guard_update;")
        try ledger.executeUncheckedSQL("DROP TRIGGER IF EXISTS calibration_state_guard_delete;")
        try ledger.executeUncheckedSQL("DROP TRIGGER IF EXISTS calibration_state_guard_insert;")
        try ledger.executeUncheckedSQL(
            """
            UPDATE calibration_state
            SET is_completed = 0,
                transition_to_hard_at = '2099-01-01T00:00:00Z',
                accrued_monotonic_elapsed = 0,
                is_tampered = 0;
            """
        )
        #expect(try ledger.loadCalibrationState()?.isCompleted == false)

        let closed = coordinator.snapshot()
        #expect(closed.phase == .hardLockdown)
        #expect(closed.enforcementMode == .hard)
        #expect(closed.isSoftModeActive == false)
        #expect(closed.bannerCaption == "FULL HARD ENFORCEMENT ACTIVE")
    }

    @Test("missing calibration_state fails closed to hard instead of minting a new window")
    func missingCalibrationStateFailsClosedToHard() throws {
        let url = EconomicLedgerLocation.makeIsolatedFileURL()
        let ledger = try SQLiteEconomicLedger(fileURL: url)
        let replica = FileCalibrationSealStore(
            privilegedFileURL: url.deletingLastPathComponent()
                .appendingPathComponent("privileged-calibration-missing.json"),
            fallbackDirectory: url.deletingLastPathComponent(),
            keychainStore: InMemoryKeychainStore()
        )
        let wall = ManualWallClock(Self.date(2026, 3, 9, 15, 0))
        let mono = ManualMonotonicClock(startingAt: 10)
        let coordinator = CalibrationCoordinator(
            store: ledger,
            clock: mono,
            wallClock: wall,
            timeTravel: TimeTravelGuard(),
            timeZone: Self.utc,
            bootSessionUUID: "boot-s9-missing",
            keyProvider: InMemoryCalibrationKeyProvider(),
            replicaSealStore: replica
        )

        let started = coordinator.snapshot()
        #expect(started.phase == .day1)
        let originalStart = try #require(try ledger.loadCalibrationState()).calibrationStartedAt

        try ledger.executeUncheckedSQL("DROP TRIGGER IF EXISTS calibration_state_guard_update;")
        try ledger.executeUncheckedSQL("DROP TRIGGER IF EXISTS calibration_state_guard_delete;")
        try ledger.executeUncheckedSQL("DROP TRIGGER IF EXISTS calibration_state_guard_insert;")
        try ledger.executeUncheckedSQL("DELETE FROM calibration_state;")
        #expect(try ledger.loadCalibrationState() == nil)

        let closed = coordinator.snapshot()
        #expect(closed.phase == .hardLockdown)
        #expect(closed.enforcementMode == .hard)
        #expect(closed.isSoftModeActive == false)
        if let restored = try ledger.loadCalibrationState() {
            #expect(restored.isCompleted)
            #expect(restored.calibrationStartedAt == originalStart || restored.isTampered)
        }
    }

    @Test("SQLite UPDATE of calibration_state without a write permit is rejected")
    func calibrationTriggersRejectUnauthorizedUpdates() throws {
        let ledger = try SQLiteEconomicLedger(fileURL: EconomicLedgerLocation.makeIsolatedFileURL())
        let coordinator = CalibrationCoordinator(
            store: ledger,
            clock: ManualMonotonicClock(startingAt: 5),
            wallClock: ManualWallClock(Self.date(2026, 3, 9, 15, 0)),
            timeTravel: TimeTravelGuard(),
            timeZone: Self.utc,
            bootSessionUUID: "boot-s9-trigger"
        )
        #expect(coordinator.snapshot().phase == .day1)

        do {
            try ledger.executeUncheckedSQL(
                "UPDATE calibration_state SET is_completed = 1;"
            )
            Issue.record("calibration_state UPDATE must be sealed")
        } catch let error as EconomicLedgerError {
            #expect(error == .sealed)
        }
        #expect(try ledger.loadCalibrationState()?.isCompleted == false)
        #expect(coordinator.snapshot().enforcementMode == .calibration)
    }

    @Test("unverified hostnames stay dropped in calibration and infractions are counted")
    func unverifiedHostnamesDropAndInfractionsAreTracked() {
        var policy = EnforcementPolicy.lockedDown
        policy.mode = .calibration
        let log = InMemorySoftInfractionLog()
        let engine = ContentFilterEngine(fallbackPolicy: policy, infractionLog: log)

        #expect(
            engine.verdict(hostname: nil, port: 443, transport: .udp) == .drop
        )
        #expect(
            engine.verdict(hostname: "", port: 443, transport: .tcp) == .drop
        )
        #expect(
            engine.verdict(hostname: "8.8.8.8", port: 443, transport: .tcp) == .drop
        )
        #expect(log.count == 0)

        #expect(
            engine.verdict(hostname: "youtube.com", port: 443, transport: .tcp) == .softInfraction
        )
        #expect(
            engine.verdict(hostname: "www.reddit.com", port: 443, transport: .tcp) == .softInfraction
        )
        #expect(log.count == 2)
        #expect(log.events.allSatisfy { $0.hostname != nil })

        let dropped = ContentFilterProvider.networkVerdict(
            hostname: nil,
            port: 443,
            transport: .udp,
            policy: policy
        )
        #expect(isNetworkDropVerdict(dropped))
        #expect(
            engine.verdict(hostname: "talabat.com", port: 443, transport: .tcp) == .softInfraction
        )
        #expect(log.count == 3)
    }

    @Test("enrolled 2FA blocks habit and price mutations while locked")
    func enrolledTwoFactorBlocksConfigurationMutations() async throws {
        let keychain = InMemoryKeychainStore()
        let wall = ManualWallClock(Date(timeIntervalSince1970: 1_700_000_000))
        let gate = SecurityGatekeeper(keychain: keychain, wallClock: wall)
        let secret = try TOTPEngine.generateSecret()
        _ = try gate.enroll(password: "Aa1!bbbbbbbb", totpSecret: secret)
        #expect(gate.isEnrolled)
        #expect(!gate.isUnlocked)

        let harness = HabitHarness(bypass: true, gatekeeper: gate)
        do {
            _ = try harness.habits.createHabit(title: "Cheat Walk")
            Issue.record("enrolled+locked 2FA must block habit creation")
        } catch let error as SecurityGatekeeperError {
            #expect(error == .notUnlocked)
        }
        do {
            _ = try harness.governance.setAmenityPrice(.food, cost: 1.0)
            Issue.record("enrolled+locked 2FA must block price mutations")
        } catch let error as SecurityGatekeeperError {
            #expect(error == .notUnlocked)
        }
        #expect(try harness.store.allHabits().isEmpty)

        let code = try TOTPEngine.code(base32Secret: secret, at: wall.now())
        _ = try await gate.unlock(password: "Aa1!bbbbbbbb", totp: code)
        #expect(gate.isUnlocked)

        let habit = try harness.habits.createHabit(title: "Make Bed")
        #expect(habit.title == "Make Bed")
        #expect(try harness.governance.setAmenityPrice(.food, cost: 1.0) == 1.0)
        #expect(try harness.store.allHabits().count == 1)
    }

    @Test("TOTP replay within the same window is rejected")
    func totpReplayWithinWindowIsRejected() async throws {
        let keychain = InMemoryKeychainStore()
        let wall = ManualWallClock(Date(timeIntervalSince1970: 1_700_000_010))
        let gate = SecurityGatekeeper(keychain: keychain, wallClock: wall)
        let secret = try TOTPEngine.generateSecret()
        _ = try gate.enroll(password: "Aa1!bbbbbbbb", totpSecret: secret)
        let code = try TOTPEngine.code(base32Secret: secret, at: wall.now())

        _ = try await gate.unlock(password: "Aa1!bbbbbbbb", totp: code)
        #expect(gate.isUnlocked)
        #expect(gate.lastUsedTOTPWindow != nil)
        gate.lockSettings()
        #expect(!gate.isUnlocked)

        do {
            _ = try await gate.unlock(password: "Aa1!bbbbbbbb", totp: code)
            Issue.record("replaying the same TOTP window must fail")
        } catch let error as SecurityGatekeeperError {
            #expect(error == .totpMismatch)
        }
        #expect(!gate.isUnlocked)
    }

    @Test("unlocked sessions expire after 10 minutes and fail closed on clock rollback")
    func unlockedSessionExpiresAndRejectsClockRollback() async throws {
        let keychain = InMemoryKeychainStore()
        let wall = ManualWallClock(Date(timeIntervalSince1970: 1_700_000_000))
        let mono = ManualMonotonicClock(startingAt: 1_000)
        let gate = SecurityGatekeeper(keychain: keychain, wallClock: wall, clock: mono)
        let secret = try TOTPEngine.generateSecret()
        _ = try gate.enroll(password: "Aa1!bbbbbbbb", totpSecret: secret)
        let code = try TOTPEngine.code(base32Secret: secret, at: wall.now())
        _ = try await gate.unlock(password: "Aa1!bbbbbbbb", totp: code)
        #expect(gate.isUnlocked)
        #expect(gate.snapshot().isUnlocked)

        wall.advance(by: SecurityGatekeeper.sessionTimeoutSeconds - 1)
        #expect(gate.isUnlocked)
        #expect(gate.snapshot().isUnlocked)

        wall.advance(by: 1)
        #expect(!gate.isUnlocked)
        #expect(!gate.snapshot().isUnlocked)
        #expect(throws: SecurityGatekeeperError.notUnlocked) {
            try gate.requireUnlocked()
        }

        wall.advance(by: 30)
        let laterCode = try TOTPEngine.code(base32Secret: secret, at: wall.now())
        _ = try await gate.unlock(password: "Aa1!bbbbbbbb", totp: laterCode)
        #expect(gate.isUnlocked)
        #expect(gate.snapshot().isUnlocked)

        wall.advance(by: -5)
        #expect(!gate.isUnlocked)
        #expect(!gate.snapshot().isUnlocked)

        wall.advance(by: 35)
        let monotonicCode = try TOTPEngine.code(base32Secret: secret, at: wall.now())
        _ = try await gate.unlock(password: "Aa1!bbbbbbbb", totp: monotonicCode)
        #expect(gate.isUnlocked)
        #expect(gate.snapshot().isUnlocked)

        mono.advance(by: SecurityGatekeeper.sessionTimeoutSeconds - 1)
        #expect(gate.isUnlocked)
        #expect(gate.snapshot().isUnlocked)

        mono.advance(by: 1)
        #expect(!gate.isUnlocked)
        #expect(!gate.snapshot().isUnlocked)
    }

    @Test("alert mail failure is audited without corrupting the unlocked session")
    func alertMailFailureIsAudited() async throws {
        let keychain = InMemoryKeychainStore()
        let wall = ManualWallClock(Date(timeIntervalSince1970: 1_700_000_000))
        let mail = FailingAdminMail()
        let gate = SecurityGatekeeper(keychain: keychain, mail: mail, wallClock: wall)
        let secret = try TOTPEngine.generateSecret()
        _ = try gate.enroll(password: "Aa1!bbbbbbbb", totpSecret: secret)
        let code = try TOTPEngine.code(base32Secret: secret, at: wall.now())

        let session = try await gate.unlock(password: "Aa1!bbbbbbbb", totp: code)
        #expect(session.recipient == SecurityGatekeeper.defaultRecipient)
        #expect(gate.isUnlocked)

        let snap = gate.snapshot()
        #expect(snap.mailDispatchFailed)
        #expect(snap.lastAuditEmailDispatched == false)
        let audit = gate.auditLog()
        #expect(audit.count == 1)
        #expect(audit[0].emailDispatched == false)
        #expect(audit[0].kind == .settingsUnlocked)
    }

    @Test("failed admin mail writes a durable audit row that survives ledger reopen")
    func failedAdminMailPersistsAcrossLedgerReopen() async throws {
        let url = EconomicLedgerLocation.makeIsolatedFileURL()
        let ledger = try SQLiteEconomicLedger(fileURL: url)
        let keychain = InMemoryKeychainStore()
        let wall = ManualWallClock(Date(timeIntervalSince1970: 1_700_000_000))
        let mail = FailingAdminMail()
        let gate = SecurityGatekeeper(
            keychain: keychain,
            mail: mail,
            wallClock: wall,
            auditStore: ledger
        )
        let secret = try TOTPEngine.generateSecret()
        _ = try gate.enroll(password: "Aa1!bbbbbbbb", totpSecret: secret)
        let code = try TOTPEngine.code(base32Secret: secret, at: wall.now())
        _ = try await gate.unlock(password: "Aa1!bbbbbbbb", totp: code)
        #expect(gate.isUnlocked)
        #expect(gate.auditLog().count == 1)
        #expect(gate.auditLog()[0].emailDispatched == false)

        let reopened = try SQLiteEconomicLedger(fileURL: url)
        let persisted = try reopened.allAdminAuditEvents()
        #expect(persisted.count == 1)
        #expect(persisted[0].kind == .settingsUnlocked)
        #expect(persisted[0].emailDispatched == false)
        #expect(persisted[0].recipient == SecurityGatekeeper.defaultRecipient)
        #expect(persisted[0].errorDescription != nil)

        let reloaded = SecurityGatekeeper(
            keychain: keychain,
            mail: mail,
            wallClock: wall,
            auditStore: reopened
        )
        #expect(reloaded.auditLog().count == 1)
        #expect(reloaded.auditLog()[0].emailDispatched == false)
        #expect(reloaded.snapshot().lastAuditEmailDispatched == false)
    }

    @MainActor
    @Test("proof PNGs render distinct calibration and hard-lock states")
    func proofPNGsRenderDistinctStates() throws {
        try DesktopDashboardProofRenderer.renderProofSet(scale: 2)
        let dashboard = try Data(contentsOf: DesktopDashboardProofRenderer.defaultProofURL)
        let calibration = try Data(contentsOf: DesktopDashboardProofRenderer.calibrationProofURL)
        #expect(dashboard.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(calibration.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(dashboard != calibration)
        #expect(CommandDashboardSnapshot.proof.bannerCaption.contains("CALIBRATION MODE"))
        #expect(CommandDashboardSnapshot.hardLockProof.bannerCaption == "FULL HARD ENFORCEMENT ACTIVE")
        #expect(CommandDashboardSnapshot.proof.healthCaption != CommandDashboardSnapshot.hardLockProof.healthCaption)
    }
}

private extension Slice9AdversarialHardeningTests {
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }
}

private struct FailingAdminMail: AdminAlertDispatching, Sendable {
    func dispatchAdminAlert(_ event: AdminAlertEvent) async throws {
        _ = event
        throw AlertMailError.httpStatus(429)
    }
}

private func isNetworkDropVerdict(_ verdict: NEFilterNewFlowVerdict) -> Bool {
    (verdict.value(forKey: "drop") as? Bool) ?? false
}
