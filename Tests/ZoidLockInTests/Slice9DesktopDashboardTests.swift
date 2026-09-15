import AppKit
import Darwin
import Foundation
import NetworkExtension
import SwiftUI
import Testing
@testable import ZoidLockInCore
import ZoidLockInEconomy
import ZoidLockInEnforcer
import ZoidLockInFilterExtension

@Suite("Slice 9 desktop dashboard, calibration, and 2FA gate", .serialized)
struct Slice9DesktopDashboardTests {
    private static let utc = TimeZone(identifier: "UTC")!

    @Test("calibration starts on first snapshot and persists the SQLite contract columns")
    func calibrationStartsAndPersists() throws {
        let ledger = try SQLiteEconomicLedger()
        let wall = ManualWallClock(Self.date(2026, 3, 9, 15, 0))
        let mono = ManualMonotonicClock(startingAt: 40)
        let coordinator = CalibrationCoordinator(
            store: ledger,
            clock: mono,
            wallClock: wall,
            timeTravel: TimeTravelGuard(),
            timeZone: Self.utc,
            bootSessionUUID: "boot-cal-1"
        )

        let snap = coordinator.snapshot()
        #expect(snap.phase == .day1)
        #expect(snap.currentDay == 1)
        #expect(snap.isSoftModeActive)
        #expect(snap.bannerCaption == "CALIBRATION MODE · DAY 1 OF 3 · SOFT WARNINGS ONLY")
        #expect(snap.enforcementMode == .calibration)
        #expect(coordinator.isSoftModeActive())

        let stored = try #require(try ledger.loadCalibrationState())
        #expect(stored.isCompleted == false)
        #expect(stored.bootSessionUUID == "boot-cal-1")
        #expect(stored.calibrationStartedMonotonic == 40)
        #expect(stored.transitionToHardAt == Self.date(2026, 3, 12, 0, 0))
        #expect(try ledger.journalMode() == "wal" || ledger.fileURL == nil)
    }

    @Test("Days 1-3 stay in soft audit mode and Day 4 00:00 transitions to hard lockdown")
    func calibrationLifecycleDays() {
        let harness = CalibrationHarness(start: Self.date(2026, 3, 9, 15, 0))
        #expect(harness.coordinator.snapshot().phase == .day1)

        harness.advance(wall: 24 * 3600, mono: 24 * 3600)
        #expect(harness.coordinator.snapshot().phase == .day2)
        #expect(harness.coordinator.snapshot().bannerCaption.contains("DAY 2 OF 3"))

        harness.advance(wall: 24 * 3600, mono: 24 * 3600)
        #expect(harness.coordinator.snapshot().phase == .day3)
        #expect(harness.coordinator.isSoftModeActive())

        harness.advance(wall: 9 * 3600, mono: 9 * 3600)
        let hard = harness.coordinator.snapshot()
        #expect(hard.phase == .hardLockdown)
        #expect(hard.bannerCaption == "FULL HARD ENFORCEMENT ACTIVE")
        #expect(hard.isSoftModeActive == false)
        #expect(hard.enforcementMode == .hard)
        #expect(harness.store.state?.isCompleted == true)
    }

    @Test("72-hour monotonic backstop engages hard lockdown even if civil day is stalled")
    func monotonicBackstop() {
        let harness = CalibrationHarness(start: Self.date(2026, 3, 9, 15, 0))
        harness.advance(wall: 0, mono: CalibrationCoordinator.softModeDuration)
        let snap = harness.coordinator.snapshot()
        #expect(snap.phase == .hardLockdown)
        #expect(snap.enforcementMode == .hard)
    }

    @Test("jumping the wall clock forward cannot skip calibration before 72h monotonic")
    func clockTamperDoesNotExpireEarly() {
        let harness = CalibrationHarness(start: Self.date(2026, 3, 9, 15, 0))
        harness.wall.set(Self.date(2026, 3, 13, 0, 0))
        harness.mono.advance(by: 1)
        let stillSoft = harness.coordinator.snapshot()
        #expect(stillSoft.isClockTampered)
        #expect(stillSoft.isSoftModeActive)
        #expect(stillSoft.phase != .hardLockdown)

        harness.mono.advance(by: CalibrationCoordinator.softModeDuration)
        harness.wall.advance(by: CalibrationCoordinator.softModeDuration)
        let hard = harness.coordinator.snapshot()
        #expect(hard.phase == .hardLockdown)
        #expect(hard.enforcementMode == .hard)
    }

    @Test("soft calibration remaps socket drops to warnings and does not kill processes")
    func softModeAllowsFlowsAndSkipsKills() async throws {
        var policy = EnforcementPolicy.lockedDown
        policy.mode = .calibration
        #expect(
            policy.flowVerdict(hostname: "youtube.com", port: 443, transport: .tcp) == .softInfraction
        )
        #expect(
            policy.flowVerdict(hostname: nil, port: 443, transport: .udp) == .softInfraction
        )
        #expect(
            policy.flowVerdict(hostname: "apple.com", port: 443, transport: .tcp) == .allow
        )
        #expect(!policy.flowVerdict(hostname: "netflix.com", port: 443, transport: .udp).dropsPackets)

        let network = ContentFilterProvider.networkVerdict(
            hostname: "youtube.com",
            port: 443,
            transport: .tcp,
            policy: policy
        )
        #expect(!isDropVerdict(network))

        let runtime = Slice9ProcessRuntime(
            processes: [RunningProcess(pid: 202, name: "Steam")]
        )
        let sentinel = ProcessSentinel(runtime: runtime, mode: .calibration)
        #expect(sentinel.scanAndTerminate().isEmpty)
        #expect(runtime.sentSignals.isEmpty)

        let hub = FilterPolicyHub()
        let daemon = EnforcementDaemon(
            policy: policy,
            processSentinel: ProcessSentinel(runtime: runtime, mode: .calibration),
            filterPolicyHub: hub,
            incidentStore: InMemoryEmergencyIncidentStore(),
            bootSessionUUID: "boot-soft"
        )
        #expect(daemon.currentPolicy.mode == .calibration)
        #expect(hub.currentFilterSnapshot().isLockedDown == false)
        #expect(
            ContentFilterEngine(statusReader: hub).verdict(
                hostname: "talabat.com",
                port: 443,
                transport: .tcp
            ) == .softInfraction
        )
        #expect(daemon.processSentinel.scanAndTerminate().isEmpty)

        try await daemon.applyPolicy(EnforcementPolicySnapshot(policy.applying(calibrationMode: .hard)))
        #expect(daemon.currentPolicy.mode == .hard)
        #expect(
            ContentFilterEngine(statusReader: hub).verdict(
                hostname: "youtube.com",
                port: 443,
                transport: .tcp
            ) == .drop
        )
    }

    @Test("password hasher rejects short secrets and verifies a 12+ character hash")
    func passwordValidation() throws {
        do {
            _ = try PasswordHasher.hash("short")
            Issue.record("passwords under 12 characters must be rejected")
        } catch let error as PasswordHashingError {
            #expect(error == .tooShort(minimum: 12))
        }

        let password = "correct-horse"
        #expect(password.count == 13)
        let stored = try PasswordHasher.hash(password, iterations: 2_000)
        #expect(stored.hasPrefix("pbkdf2-sha256$"))
        #expect(PasswordHasher.verify(password, against: stored))
        #expect(!PasswordHasher.verify("correct-horse!", against: stored))
        #expect(!PasswordHasher.verify("short", against: stored))
    }

    @Test("RFC 6238 SHA-1 TOTP matches published test vectors")
    func rfc6238TOTP() throws {
        let secret = Data("12345678901234567890".utf8)
        #expect(
            TOTPEngine.code(
                secretBytes: secret,
                at: Date(timeIntervalSince1970: 59),
                digits: 8
            ) == "94287082"
        )
        #expect(
            TOTPEngine.code(
                secretBytes: secret,
                at: Date(timeIntervalSince1970: 59),
                digits: 6
            ) == "287082"
        )
        #expect(
            TOTPEngine.code(
                secretBytes: secret,
                at: Date(timeIntervalSince1970: 1_111_111_109),
                digits: 8
            ) == "07081804"
        )
        #expect(
            TOTPEngine.verify(
                code: "287082",
                secretBytes: secret,
                at: Date(timeIntervalSince1970: 59),
                allowedWindows: 0
            )
        )
        #expect(
            !TOTPEngine.verify(
                code: "000000",
                secretBytes: secret,
                at: Date(timeIntervalSince1970: 59),
                allowedWindows: 0
            )
        )

        let base32 = Base32.encode(Array(secret))
        let decoded = try Base32.decode(base32)
        #expect(decoded == Array(secret))
        #expect(try TOTPEngine.code(base32Secret: base32, at: Date(timeIntervalSince1970: 59)) == "287082")
    }

    @Test("SecurityGatekeeper enrolls, rejects bad factors, and dispatches Resend alert mail on unlock")
    func gatekeeperAndAlertMail() async throws {
        let keychain = InMemoryKeychainStore()
        let mail = RecordingAdminMail()
        let wall = ManualWallClock(Date(timeIntervalSince1970: 1_700_000_000))
        let gate = SecurityGatekeeper(keychain: keychain, mail: mail, wallClock: wall)
        let secret = try TOTPEngine.generateSecret()

        do {
            _ = try gate.enroll(password: "too-short", totpSecret: secret)
            Issue.record("enrollment must reject short passwords")
        } catch let error as SecurityGatekeeperError {
            #expect(error == .passwordTooShort(minimum: 12))
        }

        let enrollment = try gate.enroll(
            password: "twelve chars+",
            totpSecret: secret,
            recipient: "founder@mavoid.com"
        )
        #expect(enrollment.otpAuthURL.contains("otpauth://totp/"))
        #expect(gate.isEnrolled)
        #expect(!gate.isUnlocked)
        #expect(gate.verifyPassword("twelve chars+"))
        #expect(!gate.verifyPassword("twelve char"))

        let now = wall.now()
        let code = try TOTPEngine.code(base32Secret: secret, at: now)
        do {
            _ = try await gate.unlock(password: "wrong-password-long", totp: code, at: now)
            Issue.record("wrong password must fail")
        } catch {
            #expect(error as? SecurityGatekeeperError == .passwordMismatch)
        }
        do {
            _ = try await gate.unlock(password: "twelve chars+", totp: "000000", at: now)
            Issue.record("wrong TOTP must fail")
        } catch {
            #expect(error as? SecurityGatekeeperError == .totpMismatch)
        }

        let session = try await gate.unlock(password: "twelve chars+", totp: code, at: now)
        #expect(session.recipient == "founder@mavoid.com")
        #expect(gate.isUnlocked)
        #expect(mail.events.count == 1)
        #expect(mail.events[0].kind == .settingsUnlocked)
        #expect(mail.events[0].recipient == "founder@mavoid.com")

        let transport = RecordingHTTPTransport()
        let service = AlertMailService(
            configuration: AlertMailConfiguration(
                apiKey: "re_test_key",
                recipient: "founder@mavoid.com"
            ),
            transport: transport,
            environment: [:],
            secrets: EmptySecrets()
        )
        try await service.dispatchAdminAlert(mail.events[0])
        #expect(transport.requests.count == 1)
        let body = try #require(transport.requests[0].httpBody)
        let payload = try JSONDecoder().decode(ResendEmailPayload.self, from: body)
        #expect(payload.subject.contains("Admin settings unlocked"))
        #expect(payload.text.contains("ADMIN_LOGIN"))
    }

    @Test("transaction ledger paginates, filters by type, and searches text")
    func ledgerPaginationFilterSearch() {
        let transactions = CommandDashboardSnapshot.proof.transactions
        let all = TransactionLedgerQuery.page(from: transactions, pageSize: 3)
        #expect(all.totalItems == 8)
        #expect(all.totalPages == 3)
        #expect(all.items.count == 3)
        #expect(all.hasNext)
        #expect(!all.hasPrevious)

        let page2 = TransactionLedgerQuery.page(from: transactions, page: 2, pageSize: 3)
        #expect(page2.page == 2)
        #expect(page2.items.count == 3)
        #expect(page2.hasPrevious)

        let mint = TransactionLedgerQuery.page(from: transactions, filter: .mint, pageSize: 10)
        #expect(mint.totalItems == 3)
        #expect(mint.items.allSatisfy { $0.transactionType == .mint })

        let habit = TransactionLedgerQuery.page(from: transactions, filter: .habit)
        #expect(habit.totalItems == 1)
        #expect(habit.items[0].transactionType == .earnedHabit)

        let emergency = TransactionLedgerQuery.page(from: transactions, filter: .emergency)
        #expect(emergency.totalItems == 1)
        #expect(emergency.items[0].description.contains("Emergency"))

        let search = TransactionLedgerQuery.page(from: transactions, search: "momentum")
        #expect(search.totalItems == 1)
        #expect(search.items[0].description.contains("Momentum"))
    }

    @Test("dashboard assemble surfaces lifetime vault, victory streak, and deficit strike history")
    func vaultAndStreakAssemble() throws {
        let ledger = InMemoryEconomicLedger()
        try ledger.saveVault(
            LifetimeVaultRecord(totalSurplusCredits: 42.5, currentStreak: 7, highestStreak: 12)
        )
        try ledger.insertReconciliation(
            DailyReconciliationRecord(
                date: "2026-09-08",
                earnedCredits: 1.0,
                spentCredits: 0,
                sweptToVault: 0,
                victoryStreakCount: 0,
                deficitStrikeApplied: true,
                fridayRestMode: false
            )
        )
        try ledger.insertReconciliation(
            DailyReconciliationRecord(
                date: "2026-09-11",
                earnedCredits: 4.0,
                spentCredits: 1.0,
                sweptToVault: 3.0,
                victoryStreakCount: 7,
                deficitStrikeApplied: false,
                fridayRestMode: false
            )
        )

        let vault = try ledger.loadVault()
        let snapshot = CommandDashboardSnapshot.assemble(
            ticker: .proof,
            calibration: .proof,
            vault: vault,
            reconciliations: try ledger.allReconciliations(),
            transactions: [],
            security: .lockedProof,
            governance: GovernanceLockSnapshot(
                isLocked: false,
                remainingSeconds: 0,
                isBypassEnabled: true,
                lastConfigurationMutationAt: nil,
                isClockTampered: false
            )
        )
        #expect(snapshot.vault.totalSurplusCredits == 42.5)
        #expect(snapshot.vault.currentStreak == 7)
        #expect(snapshot.vault.highestStreak == 12)
        #expect(snapshot.deficitStrikeCount == 1)
        #expect(snapshot.deficitStrikeLog[0].date == "2026-09-08")
        #expect(snapshot.bannerCaption.contains("DAY 2 OF 3"))
        #expect(snapshot.todayFocusMinutes == 72)
        #expect(try ledger.deficitStrikeRecords().count == 1)
    }

    @MainActor
    @Test("renders the SUMI-E command dashboard and calibration proof PNGs")
    func desktopDashboardProofPNG() throws {
        try DesktopDashboardProofRenderer.renderProofSet(scale: 2)
        let url = DesktopDashboardProofRenderer.defaultProofURL
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: DesktopDashboardProofRenderer.calibrationProofURL.path))

        let data = try Data(contentsOf: url)
        #expect(data.count > 20_000)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let image = NSImage(data: data)
        #expect(image != nil)
        #expect((image?.size.width ?? 0) >= 1200)
        #expect((image?.size.height ?? 0) >= 800)

        let view = CommandDashboardView(snapshot: .proof)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: CGSize(width: 1200, height: 800))
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.bounds.width == 1200)
        #expect(hosting.bounds.height == 800)
        #expect(CommandDashboardSnapshot.proof.bannerCaption.contains("CALIBRATION MODE"))
        #expect(CommandDashboardSnapshot.hardLockProof.bannerCaption == "FULL HARD ENFORCEMENT ACTIVE")
    }
}

private struct CalibrationHarness {
    let wall: ManualWallClock
    let mono: ManualMonotonicClock
    let store: InMemoryCalibrationStore
    let coordinator: CalibrationCoordinator

    var storeState: CalibrationState? { storeStateBox() }

    init(start: Date) {
        wall = ManualWallClock(start)
        mono = ManualMonotonicClock(startingAt: 10)
        store = InMemoryCalibrationStore()
        coordinator = CalibrationCoordinator(
            store: store,
            clock: mono,
            wallClock: wall,
            timeTravel: TimeTravelGuard(),
            timeZone: TimeZone(identifier: "UTC")!,
            bootSessionUUID: "boot-harness"
        )
        _ = coordinator.snapshot()
    }

    func advance(wall wallDelta: TimeInterval, mono monoDelta: TimeInterval) {
        if wallDelta != 0 { wall.advance(by: wallDelta) }
        if monoDelta != 0 { mono.advance(by: monoDelta) }
    }

    private func storeStateBox() -> CalibrationState? {
        try? store.loadCalibrationState()
    }
}

extension InMemoryCalibrationStore {
    var state: CalibrationState? { try? loadCalibrationState() }
}

private enum Slice9Helpers {
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

private extension Slice9DesktopDashboardTests {
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Slice9Helpers.date(year, month, day, hour, minute)
    }
}

private final class Slice9ProcessRuntime: ProcessRuntimeControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [RunningProcess]
    private(set) var sentSignals: [Int32: [Int32]] = [:]

    init(processes: [RunningProcess]) {
        self.processes = processes
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

    func processGroupID(for pid: Int32) -> Int32? { pid }

    func terminateProcessGroup(pgid: Int32, signal: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        sentSignals[pgid, default: []].append(signal)
        return true
    }
}

private final class RecordingAdminMail: AdminAlertDispatching, @unchecked Sendable {
    private let mutex = NSLock()
    private(set) var events: [AdminAlertEvent] = []

    func dispatchAdminAlert(_ event: AdminAlertEvent) async throws {
        remember(event)
    }

    private func remember(_ event: AdminAlertEvent) {
        mutex.lock()
        events.append(event)
        mutex.unlock()
    }
}

private struct EmptySecrets: SecretProviding {
    func secret(service: String, account: String) -> String? { nil }
}

private final class RecordingHTTPTransport: HTTPTransporting, @unchecked Sendable {
    private let mutex = NSLock()
    private(set) var requests: [URLRequest] = []

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        remember(request)
        let response = HTTPURLResponse(
            url: request.url ?? AlertMailConfiguration.defaultEndpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data("{}".utf8), response)
    }

    private func remember(_ request: URLRequest) {
        mutex.lock()
        requests.append(request)
        mutex.unlock()
    }
}

private func isDropVerdict(_ verdict: NEFilterNewFlowVerdict) -> Bool {
    (verdict.value(forKey: "drop") as? Bool) ?? false
}
