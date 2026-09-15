import Foundation
import Testing
@testable import ZoidLockInCore
import ZoidLockInEconomy
import ZoidLockInEnforcer

@Suite("Slice 8 adversarial remediations", .serialized)
struct Slice8AdversarialRemediationTests {
    @Test("production-shaped policy never honors ZOID_BYPASS_GOVERNANCE_COOLDOWN outside DEBUG")
    func productionBuildsRejectEnvironmentBypass() throws {
        let environment = [GovernanceLockPolicy.bypassEnvironmentKey: "1"]
        #expect(
            GovernanceLockPolicy.isEnvironmentBypassEnabled(environment)
                == GovernanceLockPolicy.isCompileTimeBypassAllowed
        )

        let store = InMemoryMicroHabitStore()
        let publicAPI = GovernanceLockCoordinator(store: store, environment: environment)
        #if DEBUG
        #expect(publicAPI.isCooldownBypassEnabled)
        #else
        #expect(publicAPI.isCooldownBypassEnabled == false)
        let harness = HabitHarness(environment: environment)
        _ = try harness.habits.createHabit(title: "One")
        do {
            _ = try harness.habits.createHabit(title: "Two")
            Issue.record("release builds must ignore the environment cooldown bypass")
        } catch is GovernanceLockError {
            ()
        }
        #endif

        let injected = HabitHarness(bypass: true, environment: [:])
        #expect(injected.governance.isCooldownBypassEnabled)
        _ = try injected.habits.createHabit(title: "Hook One")
        _ = try injected.habits.createHabit(title: "Hook Two")
        #expect(try injected.store.allHabits().count == 2)
    }

    @Test("SQLite UPDATE of governance_state without a write permit is rejected")
    func governanceTriggersRejectUnauthorizedUpdates() throws {
        let ledger = try SQLiteEconomicLedger(fileURL: EconomicLedgerLocation.makeIsolatedFileURL())
        let harness = HabitHarness(sqlite: ledger)
        _ = try harness.habits.createHabit(title: "Make Bed")
        #expect(harness.governance.snapshot().isLocked)

        do {
            try ledger.executeUncheckedSQL(
                "UPDATE governance_state SET last_configuration_mutation_at = NULL;"
            )
            Issue.record("governance_state UPDATE must be sealed")
        } catch let error as EconomicLedgerError {
            #expect(error == .sealed)
        }
        #expect(try ledger.loadGovernanceState().lastConfigurationMutationAt != nil)
        #expect(harness.governance.snapshot().isLocked)
    }

    @Test("direct SQLite tampering of governance_state fails closed into a 48-hour lock")
    func sqliteTamperingFailsClosed() throws {
        let url = EconomicLedgerLocation.makeIsolatedFileURL()
        let ledger = try SQLiteEconomicLedger(fileURL: url)
        let replica = FileGovernanceSealStore(
            privilegedFileURL: url.deletingLastPathComponent()
                .appendingPathComponent("privileged-governance.json"),
            fallbackDirectory: url.deletingLastPathComponent(),
            keychainStore: InMemoryKeychainStore()
        )
        let harness = HabitHarness(sqlite: ledger, replicaSealStore: replica)
        _ = try harness.habits.createHabit(title: "Make Bed")
        #expect(harness.governance.snapshot().isLocked)
        #expect(try replica.loadEnvelope()?.payload.hasMutation == true)

        try ledger.executeUncheckedSQL("DROP TRIGGER IF EXISTS governance_state_guard_update;")
        try ledger.executeUncheckedSQL("DROP TRIGGER IF EXISTS governance_state_guard_delete;")
        try ledger.executeUncheckedSQL("DROP TRIGGER IF EXISTS governance_state_guard_insert;")
        try ledger.executeUncheckedSQL(
            "UPDATE governance_state SET last_configuration_mutation_at = NULL, accrued_monotonic_elapsed = 172800;"
        )
        #expect(try ledger.loadGovernanceState().lastConfigurationMutationAt == nil)

        let snap = harness.governance.snapshot()
        #expect(snap.isLocked)
        #expect(snap.integrityFailed)
        #expect(snap.remainingSeconds == GovernanceLockPolicy.cooldownSeconds)

        do {
            _ = try harness.habits.createHabit(title: "Cheat Walk")
            Issue.record("tampered governance_state must fail closed")
        } catch let error as GovernanceLockError {
            switch error {
            case .integrityFailed, .cooldownActive:
                ()
            default:
                Issue.record("expected integrityFailed or cooldownActive, got \(error)")
            }
        }
        #expect(try ledger.allHabits().count == 1)
    }

    @Test("timezone hopping cannot mint a second 1.5 credit budget inside 24 monotonic hours")
    func timezoneHoppingCannotBypassCreditCeiling() throws {
        let kiritimati = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
        let gmtMinus12 = try #require(TimeZone(identifier: "Etc/GMT+12"))
        let first = HabitHarness(bypass: true, timeZone: kiritimati)
        var created: [MicroHabit] = []
        for index in 1...6 {
            created.append(try first.habits.createHabit(title: "H\(index)"))
            _ = try first.habits.complete(habitID: created[index - 1].id)
        }
        #expect(try first.engine.earnedHabitCredits(onLocalDay: first.dayKey()) == 1.5)
        #expect(first.governance.pinnedTimeZone.identifier == kiritimati.identifier)

        let hopped = HabitHarness(
            bypass: true,
            store: first.store,
            ledger: first.ledger,
            timeZone: gmtMinus12,
            wall: first.wall,
            mono: first.mono,
            timeTravel: first.timeTravel,
            keyProvider: first.keyProvider
        )
        #expect(hopped.governance.pinnedTimeZone.identifier == kiritimati.identifier)
        #expect(hopped.civil.calendar.timeZone.identifier == kiritimati.identifier)

        do {
            _ = try hopped.habits.complete(habitID: created[0].id)
            Issue.record("pinned timezone plus rolling window must refuse a second 1.5 budget")
        } catch let error as MicroHabitError {
            #expect(error == .dailyCreditCeilingReached || error == .dailyFrequencyReached)
        }

        let foreignEngine = ExchangeEngine(
            ledger: first.ledger,
            clock: first.mono,
            focusClock: first.mono,
            wallClock: first.wall,
            timeTravel: first.timeTravel,
            timeZone: gmtMinus12,
            habitWindow: first.store
        )
        let refused = try foreignEngine.mintEarnedHabit(
            completionID: UUID(),
            amount: 0.25,
            habitTitle: "TZ hop"
        )
        #expect(refused.creditsMinted == 0)
        #expect(refused.transaction == nil)
        #expect(try first.store.earnedHabitCredits(fromMonotonic: -1, through: first.mono.nowSeconds()) == 1.5)
    }

    @Test("mutated amenity prices and blocklist suffixes reach the engine and filter")
    func mutatedSettingsPropagateToEngineAndFilter() async throws {
        let harness = HabitHarness(bypass: true)
        #expect(try harness.governance.setAmenityPrice(.food, cost: 1.0) == 1.0)
        #expect(harness.engine.catalog.standardCost(of: .food) == 1.0)
        #expect(harness.engine.catalog.cost(of: .food, fridayRestMode: false) == 1.0)

        var created: [MicroHabit] = []
        for index in 1...4 {
            created.append(try harness.habits.createHabit(title: "Fuel \(index)"))
        }
        for habit in created {
            _ = try harness.habits.complete(habitID: habit.id)
        }
        let purchase = try harness.engine.purchaseAmenity(.food)
        #expect(purchase.cost == 1.0)
        #expect(purchase.transaction.amount == -1.0)

        let rule = try harness.governance.addBlocklistSuffix("cheat-site.example")
        #expect(rule.suffix == "cheat-site.example")
        let policy = try harness.governance.composedEnforcementPolicy()
        #expect(policy.domainRules.shouldBlock(hostname: "www.cheat-site.example"))
        #expect(policy.domainRules.shouldBlock(hostname: "youtube.com"))

        #expect(policy.flowVerdict(hostname: "www.cheat-site.example", port: 443, transport: .tcp) == .drop)
        #expect(policy.flowVerdict(hostname: "github.com", port: 443, transport: .tcp) == .allow)

        let filter = ContentFilterEngine(fallbackPolicy: policy)
        #expect(filter.verdict(hostname: "www.cheat-site.example", port: 443, transport: .tcp) == .drop)
        #expect(filter.verdict(hostname: "github.com", port: 443, transport: .tcp) == .allow)

        let daemon = EnforcementDaemon(
            incidentStore: InMemoryEmergencyIncidentStore(),
            bootSessionUUID: "boot-slice8-policy"
        )
        try await daemon.applyPolicy(EnforcementPolicySnapshot(policy))
        #expect(daemon.currentPolicy.domainRules.shouldBlock(hostname: "www.cheat-site.example"))
        #expect(daemon.currentPolicy.domainRules.shouldBlock(hostname: "youtube.com"))
    }

    @Test("habit editor fields are disabled with a read-only indicator while configuration is locked")
    func inputFieldsDisabledInLockedState() throws {
        let unlocked = HabitHarness().habits.snapshot()
        #expect(unlocked.editorIsLocked == false)
        #expect(unlocked.editorFieldsDisabled == false)
        #expect(unlocked.editorAllowsHitTesting)
        #expect(unlocked.editorReadOnlyCaption == nil)
        #expect(unlocked.editorFieldOpacity == 1)

        let harness = HabitHarness()
        _ = try harness.habits.createHabit(title: "Make Bed")
        let locked = harness.habits.snapshot()
        #expect(locked.governance.isLocked)
        #expect(locked.editorIsLocked)
        #expect(locked.editorFieldsDisabled)
        #expect(locked.editorAllowsHitTesting == false)
        #expect(locked.editorReadOnlyCaption == MicroHabitsSnapshot.editorReadOnlyCaptionText)
        #expect(locked.editorFieldOpacity == 0.55)
        #expect(locked.governance.bannerCaption.contains("CONFIG LOCKED"))
    }
}
