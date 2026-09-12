import Foundation
import NetworkExtension
import Testing
import ZoidLockInCore
import ZoidLockInEnforcer
import ZoidLockInFilterExtension

@Suite("Slice 2 adversarial hardening")
struct Slice2HardeningTests {
    @Test("content filter relaxes drops during an emergency pass and relocks on expiry")
    func contentFilterFollowsDaemonPass() async throws {
        let hub = FilterPolicyHub()
        let clock = ManualMonotonicClock(startingAt: 0)
        let daemon = EnforcementDaemon(
            clock: clock,
            filterPolicyHub: hub,
            incidentStore: InMemoryEmergencyIncidentStore(),
            bootSessionUUID: "boot-filter"
        )
        let engine = ContentFilterEngine(statusReader: hub)

        #expect(engine.verdict(hostname: "youtube.com", port: 443, transport: .tcp) == .drop)
        #expect(engine.verdict(hostname: "talabat.com", port: 443, transport: .tcp) == .drop)
        #expect(engine.verdict(hostname: nil, port: 443, transport: .udp) == .drop)
        #expect(
            isDropVerdict(
                ContentFilterProvider.networkVerdict(
                    hostname: "youtube.com",
                    port: 443,
                    transport: .tcp,
                    snapshot: hub.currentFilterSnapshot()
                )
            )
        )

        try await daemon.engageEmergencySafetyValve()

        let active = hub.currentFilterSnapshot()
        #expect(active.isPassActive)
        #expect(active.activePassKind == .emergency)
        #expect(!active.isLockedDown)
        #expect(engine.verdict(hostname: "youtube.com", port: 443, transport: .tcp) == .allow)
        #expect(engine.verdict(hostname: "www.talabat.com", port: 443, transport: .tcp) == .allow)
        #expect(engine.verdict(hostname: nil, port: 443, transport: .udp) == .allow)
        #expect(
            !isDropVerdict(
                ContentFilterProvider.networkVerdict(
                    hostname: "youtube.com",
                    port: 443,
                    transport: .tcp,
                    snapshot: active
                )
            )
        )
        #expect(
            !isDropVerdict(
                ContentFilterProvider.networkVerdict(
                    hostname: nil,
                    port: 443,
                    transport: .udp,
                    snapshot: active
                )
            )
        )

        clock.advance(by: 1_799)
        daemon.evaluateWatchdogs(at: clock.nowSeconds())
        #expect(engine.verdict(hostname: "youtube.com", port: 443, transport: .tcp) == .allow)

        clock.advance(by: 1)
        daemon.evaluateWatchdogs(at: clock.nowSeconds())

        #expect(hub.currentFilterSnapshot().isLockedDown)
        #expect(!hub.currentFilterSnapshot().isPassActive)
        #expect(engine.verdict(hostname: "youtube.com", port: 443, transport: .tcp) == .drop)
        #expect(engine.verdict(hostname: "talabat.com", port: 443, transport: .tcp) == .drop)
        #expect(engine.verdict(hostname: nil, port: 443, transport: .udp) == .drop)
        #expect(daemon.currentPolicy.mode == .hard)
    }

    @Test("emergency valve rejects back-to-back activations and enforces a 24-hour cooldown")
    func emergencyCooldownRejectsRefresh() async throws {
        let clock = ManualMonotonicClock(startingAt: 10)
        let wall = FixedWallClock(Date(timeIntervalSince1970: 2_000_000_000))
        let daemon = EnforcementDaemon(
            clock: clock,
            wallClock: wall,
            incidentStore: InMemoryEmergencyIncidentStore(),
            bootSessionUUID: "boot-cooldown"
        )

        try await daemon.engageEmergencySafetyValve()
        #expect(try await daemon.queryStatus().activePassKind == .emergency)

        do {
            try await daemon.engageEmergencySafetyValve()
            Issue.record("second engage while the pass is active must not refresh")
        } catch let error as EnforcementControlError {
            #expect(error == .passAlreadyActive)
        } catch {
            Issue.record("unexpected error \(error)")
        }

        do {
            try await daemon.openPass(kind: .emergency, durationSeconds: 99, nonce: "n1")
            Issue.record("openPass(.emergency) must not refresh an active pass")
        } catch let error as EnforcementControlError {
            #expect(error == .passAlreadyActive)
        } catch {
            Issue.record("unexpected error \(error)")
        }

        clock.advance(by: DaemonLocalPass.emergencyDurationSeconds)
        daemon.evaluateWatchdogs(at: clock.nowSeconds())
        #expect(try await daemon.queryStatus().isLockedDown)

        do {
            try await daemon.engageEmergencySafetyValve()
            Issue.record("engage immediately after expiry must still be in cooldown")
        } catch let error as EnforcementControlError {
            guard case .emergencyCooldownActive(let remaining) = error else {
                Issue.record("expected cooldown, got \(error)")
                return
            }
            #expect(remaining > 0)
            #expect(remaining <= DaemonPassController.emergencyCooldownSeconds)
        } catch {
            Issue.record("unexpected error \(error)")
        }

        clock.advance(by: DaemonPassController.emergencyCooldownSeconds)
        try await daemon.engageEmergencySafetyValve()
        #expect(try await daemon.queryStatus().activePassKind == .emergency)
        #expect(daemon.incidents().count == 2)
    }

    @Test("openPass(.emergency) is identical to the valve including incident write")
    func openPassEmergencyWritesIncident() async throws {
        let store = InMemoryEmergencyIncidentStore()
        let daemon = EnforcementDaemon(
            clock: ManualMonotonicClock(),
            wallClock: FixedWallClock(Date(timeIntervalSince1970: 1_700_000_000)),
            incidentStore: store,
            bootSessionUUID: "boot-open"
        )
        try await daemon.openPass(kind: .emergency, durationSeconds: 9_999, nonce: UUID().uuidString)
        #expect(try await daemon.queryStatus().remainingPassSeconds == 1_800)
        #expect(store.allIncidents().count == 1)
        #expect(store.allIncidents()[0].signedDebtCredits == -2.0)
        #expect(store.allIncidents()[0].passDurationSeconds == 1_800)
    }

    @Test("incident records and -2.0 debt survive simulated UI death")
    func durableIncidentSurvivesUIDeath() async throws {
        let directory = FileEmergencyIncidentStore.makeIsolatedDirectory()
        let clock = ManualMonotonicClock(startingAt: 50)
        let utc = Date(timeIntervalSince1970: 1_700_000_123)
        let store = FileEmergencyIncidentStore(directory: directory)
        let daemon = EnforcementDaemon(
            clock: clock,
            wallClock: FixedWallClock(utc),
            incidentStore: store,
            bootSessionUUID: "boot-durable"
        )
        let debts = IncidentProjectingPendingDebtStore(incidents: store)
        let coordinator = EmergencySafetyValveCoordinator(
            clock: clock,
            wallClock: FixedWallClock(utc),
            debtStore: debts,
            mailer: SilentMailer(),
            dispatcher: daemon
        )

        coordinator.press(at: 50)
        coordinator.tick(at: 55)
        try await coordinator.confirm()

        let written = store.allIncidents()
        #expect(written.count == 1)
        #expect(written[0].utcTimestamp == utc)
        #expect(written[0].monotonicStartedAtSeconds == 50)
        #expect(written[0].passDurationSeconds == 1_800)
        #expect(written[0].signedDebtCredits == -2.0)
        #expect(debts.totalSignedCreditsPendingReconciliation() == -2.0)

        let revivedStore = FileEmergencyIncidentStore(directory: directory)
        let revivedDebts = IncidentProjectingPendingDebtStore(incidents: revivedStore)
        #expect(revivedStore.allIncidents().count == 1)
        #expect(revivedStore.allIncidents()[0].id == written[0].id)
        #expect(revivedDebts.totalSignedCreditsPendingReconciliation() == -2.0)
        #expect(revivedDebts.recordsPendingReconciliation()[0].incidentID == written[0].id)
        #expect(revivedDebts.recordsPendingReconciliation()[0].utcTimestamp == utc)

        let revivedDaemon = EnforcementDaemon(
            clock: clock,
            wallClock: FixedWallClock(utc),
            incidentStore: revivedStore,
            bootSessionUUID: "boot-durable"
        )
        do {
            try await revivedDaemon.engageEmergencySafetyValve()
            Issue.record("respawned daemon must honor persisted cooldown")
        } catch let error as EnforcementControlError {
            guard case .emergencyCooldownActive = error else {
                Issue.record("expected cooldown after UI death, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(try await revivedDaemon.queryStatus().isLockedDown)
        #expect(revivedDaemon.incidents().count == 1)
    }

    @Test("continuous monotonic clock advances across simulated sleep so the pass expires")
    func continuousClockAdvancesAcrossSleep() async throws {
        let clock = SleepSimulationClock(startingAt: 0)
        let daemon = EnforcementDaemon(
            clock: clock,
            incidentStore: InMemoryEmergencyIncidentStore(),
            bootSessionUUID: "boot-sleep"
        )

        try await daemon.engageEmergencySafetyValve()
        #expect(try await daemon.queryStatus().activePassKind == .emergency)

        clock.simulateSleep(for: 8 * 3_600)
        #expect(clock.uptimeNowSeconds() == 0)
        #expect(clock.continuousNowSeconds() == 8 * 3_600)
        #expect(clock.nowSeconds() == clock.continuousNowSeconds())

        daemon.evaluateWatchdogs(at: clock.nowSeconds())
        let status = try await daemon.queryStatus()
        #expect(status.isLockedDown)
        #expect(status.activePassKind == nil)
        #expect(
            daemon.currentPolicy.flowVerdict(hostname: "youtube.com", port: 443, transport: .tcp)
                == .drop
        )

        let uptimeClock = MachUptimeClock()
        let continuousClock = MachContinuousTimeClock()
        #expect(continuousClock.nowSeconds() > 0)
        #expect(uptimeClock.nowSeconds() >= 0)
    }

    @Test("applyPolicy rejects empty, unmonitored, and killer policy snapshots")
    func applyPolicyRejectsMaliciousSnapshots() async throws {
        let daemon = EnforcementDaemon(
            incidentStore: InMemoryEmergencyIncidentStore(),
            bootSessionUUID: "boot-policy"
        )

        let emptyTargets = EnforcementPolicySnapshot(processTargetNames: [])
        await #expect(throws: EnforcementControlError.self) {
            try await daemon.applyPolicy(emptyTargets)
        }

        let windowServer = EnforcementPolicySnapshot(processTargetNames: ["WindowServer"])
        await #expect(throws: EnforcementControlError.self) {
            try await daemon.applyPolicy(windowServer)
        }

        let missingPorts = EnforcementPolicySnapshot(inspectedPorts: [22, 53])
        await #expect(throws: EnforcementControlError.self) {
            try await daemon.applyPolicy(missingPorts)
        }

        let emptyBlacklist = EnforcementPolicySnapshot(blacklistedSuffixes: [])
        await #expect(throws: EnforcementControlError.self) {
            try await daemon.applyPolicy(emptyBlacklist)
        }

        try await daemon.applyPolicy(EnforcementPolicySnapshot())
        #expect(daemon.currentPolicy.mode == .hard)
        #expect(daemon.currentPolicy.shouldInspect(port: 443))
        #expect(!daemon.currentPolicy.processMatcher.targetNames.isEmpty)
    }

    @Test("amenity openPass is gated until a Slice 4 voucher exists")
    func amenityOpenPassRequiresVoucher() async throws {
        let daemon = EnforcementDaemon(
            incidentStore: InMemoryEmergencyIncidentStore(),
            bootSessionUUID: "boot-amenity"
        )
        await #expect(throws: EnforcementControlError.amenityPassRequiresVoucher) {
            try await daemon.openPass(kind: .food, durationSeconds: 1_800, nonce: "food-1")
        }
        await #expect(throws: EnforcementControlError.amenityPassRequiresVoucher) {
            try await daemon.openPass(kind: .streaming, durationSeconds: 3_600, nonce: "stream-1")
        }
        #expect(try await daemon.queryStatus().isLockedDown)
        #expect(!AmenityPassVoucher().isVerified)
    }

    @Test("Team ID strings are sanitized and SecCodeCopySelf falls back cleanly")
    func teamIdentifierSanitization() {
        #expect(CodeRequirement.sanitizedTeamIdentifier("ABCD123456") == "ABCD123456")
        #expect(CodeRequirement.sanitizedTeamIdentifier("TEAMID") == "TEAMID")
        #expect(CodeRequirement.sanitizedTeamIdentifier("ABCD123456\" or identifier \"evil") == nil)
        #expect(CodeRequirement.sanitizedTeamIdentifier("teamid") == nil)
        #expect(CodeRequirement.sanitizedTeamIdentifier("ABC") == nil)

        let injected = CodeRequirement(
            teamID: "ABCD123456\" or identifier \"com.evil",
            identifier: "com.mavoid.zoidlockin\"; or identifier \"x"
        )
        #expect(!injected.requirementString.contains(" or "))
        #expect(injected.requirementString.contains("INVALID") || injected.requirementString.contains("invalid"))
        #expect(!CodeRequirement.isTeamIDPinned(injected.requirementString))

        let pinned = CodeRequirement(teamID: "ABCD123456", identifier: "com.mavoid.zoidlockin")
        #expect(CodeRequirement.isTeamIDPinned(pinned.requirementString))
        #expect(
            !CodeRequirement.isTeamIDPinned(
                "anchor apple generic and certificate leaf[subject.OU] = \"ABCD123456\" or identifier \"com.evil\""
            )
        )

        let resolvedEvil = ZoidLockInIdentity.resolvedTeamIdentifier(
            environment: [
                ZoidLockInIdentity.teamIdentifierEnvironmentVariable:
                    "ABCD123456\" or identifier \"com.evil",
            ],
            queryOwnSignature: false
        )
        #expect(resolvedEvil == ZoidLockInIdentity.teamIdentifierPlaceholder)
        #expect(!resolvedEvil.contains("or"))

        let resolvedReal = ZoidLockInIdentity.resolvedTeamIdentifier(
            environment: [ZoidLockInIdentity.teamIdentifierEnvironmentVariable: "ABCD123456"],
            queryOwnSignature: false
        )
        #expect(resolvedReal == "ABCD123456")

        let signed = ZoidLockInIdentity.resolvedTeamIdentifier(
            environment: [:],
            ownTeamIdentifier: "ZXCVBN1234",
            queryOwnSignature: false
        )
        #expect(signed == "ZXCVBN1234")

        let own = ZoidLockInIdentity.teamIdentifierFromOwnCodeSignature()
        if let own {
            #expect(CodeRequirement.sanitizedTeamIdentifier(own) == own)
        }

        let unsignedFallback = ZoidLockInIdentity.resolvedTeamIdentifier(
            environment: [:],
            queryOwnSignature: true
        )
        if own == nil {
            #expect(unsignedFallback == ZoidLockInIdentity.teamIdentifierPlaceholder)
        }
    }
}

private func isDropVerdict(_ verdict: NEFilterNewFlowVerdict) -> Bool {
    (verdict.value(forKey: "drop") as? Bool) ?? false
}

private final class SilentMailer: EmergencyIncidentAlerting, @unchecked Sendable {
    var recipient: String = "alerts@mavoid.com"

    func dispatchEmergencyIncident(_ report: EmergencyIncidentReport) async throws {
        _ = report
    }
}
