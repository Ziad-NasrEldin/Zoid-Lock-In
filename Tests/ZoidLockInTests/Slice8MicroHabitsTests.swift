import AppKit
import Foundation
import Testing
@testable import ZoidLockInCore
import ZoidLockInEconomy

@Suite("Slice 8 micro-habits and 48-hour governance", .serialized)
struct Slice8MicroHabitsTests {
    @Test("CreditMath keeps hundredths so +0.25 habits stay exact")
    func creditMathKeepsHundredths() {
        #expect(CreditMath.normalize(0.25) == 0.25)
        #expect(CreditMath.normalize(0.50) == 0.5)
        #expect(CreditMath.normalize(1.5) == 1.5)
        #expect(CreditMath.displayString(0.25) == "0.25")
        #expect(CreditMath.displayString(0.5) == "0.5")
        #expect(CreditMath.feedbackCaption(0.25) == "+0.25c")
        #expect(HabitCreditMinting.walletReference(completionID: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!) == "habit:AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")
        #expect(HabitCreditMinting.dailyCreditCap == 1.5)
        #expect(GovernanceLockPolicy.cooldownSeconds == 172_800)
        #expect(GovernanceLockPolicy.formattedCountdown(47 * 3600 + 59 * 60 + 12) == "47:59:12")
    }

    @Test("habit creation, frequency capping, and completion credit minting")
    func habitCreationFrequencyAndMinting() throws {
        let harness = HabitHarness(bypass: true)
        let teeth = try harness.habits.createHabit(
            title: "Brushing Teeth / Dental Routine",
            rewardCredits: 0.25,
            dailyFrequencyLimit: 2
        )
        #expect(teeth.rewardCredits == 0.25)
        #expect(teeth.dailyFrequencyLimit == 2)
        #expect(teeth.isEnabled)

        let first = try harness.habits.complete(habitID: teeth.id)
        #expect(first.creditsMinted == 0.25)
        #expect(first.feedbackCaption == "+0.25c")
        #expect(first.transaction.transactionType == .earnedHabit)
        #expect(first.transaction.referenceID == HabitCreditMinting.walletReference(completionID: first.completion.id))
        #expect(first.transaction.description.contains("EARNED_HABIT"))
        #expect(harness.engine.walletBalance == 0.25)

        let second = try harness.habits.complete(habitID: teeth.id)
        #expect(second.creditsMinted == 0.25)
        #expect(harness.engine.walletBalance == 0.5)
        #expect(try harness.store.completions(habitID: teeth.id, on: harness.dayKey()).count == 2)

        do {
            _ = try harness.habits.complete(habitID: teeth.id)
            Issue.record("third completion must fail the daily frequency cap")
        } catch let error as MicroHabitError {
            #expect(error == .dailyFrequencyReached)
        }
        #expect(harness.engine.walletBalance == 0.5)
        #expect(try harness.engine.earnedHabitCredits(onLocalDay: harness.dayKey()) == 0.5)
    }

    @Test("hard 1.5 daily credit ceiling cannot be exceeded even with multiple habits")
    func hardDailyCreditCeiling() throws {
        let harness = HabitHarness(bypass: true)
        var created: [MicroHabit] = []
        for index in 1...7 {
            created.append(
                try harness.habits.createHabit(
                    title: "Habit \(index)",
                    rewardCredits: 0.25,
                    dailyFrequencyLimit: 1
                )
            )
        }

        for habit in created.prefix(6) {
            let outcome = try harness.habits.complete(habitID: habit.id)
            #expect(outcome.creditsMinted == 0.25)
        }
        #expect(harness.engine.walletBalance == 1.5)
        #expect(try harness.engine.earnedHabitCredits(onLocalDay: harness.dayKey()) == 1.5)

        do {
            _ = try harness.habits.complete(habitID: created[6].id)
            Issue.record("seventh 0.25 habit must fail the 1.5 ceiling")
        } catch let error as MicroHabitError {
            #expect(error == .dailyCreditCeilingReached)
        }
        #expect(harness.engine.walletBalance == 1.5)
        #expect(try harness.store.completions(on: harness.dayKey()).count == 6)

        let stretching = try harness.habits.createHabit(
            title: "Physical Movement / Stretching (15m)",
            rewardCredits: 0.5,
            dailyFrequencyLimit: 1
        )
        do {
            _ = try harness.habits.complete(habitID: stretching.id)
            Issue.record("0.50 habit must not mint once 1.5 is already earned")
        } catch let error as MicroHabitError {
            #expect(error == .dailyCreditCeilingReached)
        }
    }

    @Test("48-hour mutation lock activates on any habit or config modification")
    func mutationLockActivates() throws {
        let harness = HabitHarness()
        #expect(harness.governance.snapshot().isLocked == false)
        #expect(harness.governance.snapshot().bannerCaption == "CONFIG UNLOCKED · EDITABLE")

        let habit = try harness.habits.createHabit(title: "Making Bed / Room Reset")
        let snap = harness.governance.snapshot()
        #expect(snap.isLocked)
        #expect(snap.remainingSeconds > 172_700)
        #expect(snap.remainingSeconds <= 172_800)
        #expect(snap.bannerCaption.contains("CONFIG LOCKED"))
        #expect(snap.bannerCaption.contains("REMAINING"))
        #expect(try harness.store.loadGovernanceState().lastConfigurationMutationAt != nil)
        #expect(habit.title == "Making Bed / Room Reset")
    }

    @Test("attempting to edit or add a habit during 48h cooldown fails closed")
    func cooldownRejectsEdits() throws {
        let harness = HabitHarness()
        let habit = try harness.habits.createHabit(title: "Daily Hydration Goal (2L Water)")

        do {
            _ = try harness.habits.createHabit(title: "Evening Walk")
            Issue.record("second create during cooldown must fail")
        } catch let GovernanceLockError.cooldownActive(remaining) {
            #expect(remaining > 172_000)
        }

        do {
            _ = try harness.habits.updateHabit(id: habit.id, title: "Hydration")
            Issue.record("edit during cooldown must fail")
        } catch let GovernanceLockError.cooldownActive(remaining) {
            #expect(remaining > 172_000)
        }

        do {
            _ = try harness.habits.setEnabled(id: habit.id, isEnabled: false)
            Issue.record("disable during cooldown must fail")
        } catch is GovernanceLockError {
            ()
        }

        let stored = try #require(try harness.store.habit(id: habit.id))
        #expect(stored.title == "Daily Hydration Goal (2L Water)")
        #expect(stored.isEnabled)
        #expect(try harness.store.allHabits().count == 1)
    }

    @Test("cooldown bypass flag allows test modifications")
    func cooldownBypassAllowsEdits() throws {
        let harness = HabitHarness(bypass: true)
        _ = try harness.habits.createHabit(title: "One")
        let two = try harness.habits.createHabit(title: "Two", rewardCredits: 0.5, dailyFrequencyLimit: 2)
        _ = try harness.habits.updateHabit(id: two.id, title: "Two Updated")
        #expect(try harness.store.allHabits().count == 2)
        #expect(harness.governance.snapshot().isLocked == false)
        #expect(harness.governance.snapshot().bannerCaption == "CONFIG UNLOCKED · EDITABLE")
        #expect(harness.governance.isCooldownBypassEnabled)
    }

    @Test("ZOID_BYPASS_GOVERNANCE_COOLDOWN is debug-only; injected test hooks remain the test seam")
    func environmentBypassFlag() throws {
        let harness = HabitHarness(environment: ["ZOID_BYPASS_GOVERNANCE_COOLDOWN": "1"])
        #expect(
            GovernanceLockPolicy.isEnvironmentBypassEnabled(["ZOID_BYPASS_GOVERNANCE_COOLDOWN": "1"])
                == GovernanceLockPolicy.isCompileTimeBypassAllowed
        )
        #if DEBUG
        _ = try harness.habits.createHabit(title: "Env One")
        _ = try harness.habits.createHabit(title: "Env Two")
        #expect(try harness.store.allHabits().count == 2)
        #expect(harness.governance.isCooldownBypassEnabled)
        #else
        #expect(harness.governance.isCooldownBypassEnabled == false)
        _ = try harness.habits.createHabit(title: "Env One")
        do {
            _ = try harness.habits.createHabit(title: "Env Two")
            Issue.record("release builds must ignore ZOID_BYPASS_GOVERNANCE_COOLDOWN")
        } catch is GovernanceLockError {
            ()
        }
        #endif
    }

    @Test("monotonic / time travel resistance: advancing wall clock cannot expire the lock")
    func monotonicTimeTravelResistance() throws {
        let harness = HabitHarness()
        _ = try harness.habits.createHabit(title: "Make Bed")
        #expect(harness.governance.snapshot().isLocked)

        harness.wall.advance(by: GovernanceLockPolicy.cooldownSeconds)
        do {
            _ = try harness.habits.createHabit(title: "Cheat Walk")
            Issue.record("wall-only 48h jump must not unlock configuration")
        } catch is GovernanceLockError {
            ()
        }
        #expect(harness.governance.snapshot().isLocked)
        #expect(harness.governance.snapshot().remainingSeconds > 172_000)
        #expect(harness.timeTravel.isTampered)

        do {
            _ = try harness.habits.complete(habitID: try #require(try harness.store.allHabits().first).id)
            Issue.record("tampered clock must fail-close habit minting")
        } catch let error as MicroHabitError {
            guard case .clockTampered = error else {
                Issue.record("expected clockTampered, got \(error)")
                return
            }
        }
    }

    @Test("honest 48-hour monotonic wait unlocks configuration")
    func honestCooldownExpiry() throws {
        let harness = HabitHarness()
        _ = try harness.habits.createHabit(title: "Make Bed")
        harness.advance(GovernanceLockPolicy.cooldownSeconds)
        let snap = harness.governance.snapshot()
        #expect(snap.isLocked == false)
        #expect(snap.bannerCaption == "CONFIG UNLOCKED · EDITABLE")
        let second = try harness.habits.createHabit(title: "Stretch")
        #expect(second.title == "Stretch")
        #expect(harness.governance.snapshot().isLocked)
    }

    @Test("completions remain allowed while configuration is locked")
    func completionsAreNotMutations() throws {
        let harness = HabitHarness()
        let habit = try harness.habits.createHabit(title: "Make Bed")
        #expect(harness.governance.snapshot().isLocked)
        let outcome = try harness.habits.complete(habitID: habit.id)
        #expect(outcome.creditsMinted == 0.25)
        #expect(harness.engine.walletBalance == 0.25)
        #expect(harness.governance.snapshot().isLocked)
    }

    @Test("amenity price and blocklist mutations start the 48-hour lock")
    func configMutationsStartLock() throws {
        let harness = HabitHarness()
        #expect(try harness.governance.setAmenityPrice(.food, cost: 1.0) == 1.0)
        #expect(try harness.governance.amenityPriceOverrides()[.food] == 1.0)
        #expect(harness.governance.snapshot().isLocked)

        do {
            _ = try harness.governance.addBlocklistSuffix("cheat-site.example")
            Issue.record("blocklist mutation during cooldown must fail")
        } catch let GovernanceLockError.cooldownActive(remaining) {
            #expect(remaining > 172_000)
        }

        let bypass = HabitHarness(bypass: true)
        let rule = try bypass.governance.addBlocklistSuffix("cheat-site.example")
        #expect(rule.suffix == "cheat-site.example")
        let rules = try bypass.governance.composedDomainRules()
        #expect(rules.shouldBlock(hostname: "www.cheat-site.example"))
        try bypass.governance.setAmenityPrice(.gaming, cost: 2.0)
        #expect(try bypass.governance.amenityPriceOverrides()[.gaming] == 2.0)
    }

    @Test("SQLite persists habits, completions, and last_configuration_mutation_at")
    func sqlitePersistence() throws {
        let url = EconomicLedgerLocation.makeIsolatedFileURL()
        let ledger = try SQLiteEconomicLedger(fileURL: url)
        let harness = HabitHarness(bypass: true, sqlite: ledger)
        let habit = try harness.habits.createHabit(title: "Make Bed")
        let completion = try harness.habits.complete(habitID: habit.id)
        #expect(try ledger.journalMode() == "wal")
        #expect(try ledger.allHabits().count == 1)
        #expect(try ledger.allCompletions().count == 1)
        #expect(try ledger.completion(id: completion.completion.id)?.creditsAwarded == 0.25)
        #expect(try ledger.loadGovernanceState().lastConfigurationMutationAt != nil)

        let reopened = try SQLiteEconomicLedger(fileURL: url)
        #expect(try reopened.allHabits().first?.title == "Make Bed")
        #expect(try reopened.allCompletions().count == 1)
        #expect(try reopened.loadGovernanceState().lastConfigurationMutationAt != nil)
        #expect(try reopened.allTransactions().contains { $0.transactionType == .earnedHabit })
    }

    @Test("civil date frequency resets the next local day")
    func frequencyResetsNextCivilDay() throws {
        let harness = HabitHarness(bypass: true)
        let habit = try harness.habits.createHabit(title: "Make Bed")
        _ = try harness.habits.complete(habitID: habit.id)
        do {
            _ = try harness.habits.complete(habitID: habit.id)
            Issue.record("same-day second complete at limit 1 must fail")
        } catch let error as MicroHabitError {
            #expect(error == .dailyFrequencyReached)
        }

        harness.jumpTo(year: 2026, month: 9, day: 11, hour: 10, minute: 0)
        let next = try harness.habits.complete(habitID: habit.id)
        #expect(next.completion.civilDate == "2026-09-11")
        #expect(next.creditsMinted == 0.25)
        #expect(try harness.engine.earnedHabitCredits(onLocalDay: "2026-09-11") == 0.25)
    }

    @Test("proof snapshot exposes locked banner, +0.25c feedback, and disabled editor")
    func proofSnapshotCaptions() {
        let proof = MicroHabitsSnapshot.proof
        #expect(proof.governance.bannerCaption == "CONFIG LOCKED · 47:59:12 REMAINING")
        #expect(proof.governance.remainingCaption == "47:59:12")
        #expect(proof.editorIsLocked)
        #expect(proof.lastFeedback == "+0.25c")
        #expect(proof.habits.contains { $0.statusCaption == "DONE" })
        #expect(proof.habits.contains { $0.statusCaption == "OFF" })
        #expect(proof.habits.contains { $0.canComplete && $0.lastFeedback == "+0.25c" })
        #expect(proof.formattedDailyCredits == "0.5 / 1.5")
        #expect(proof.editorFieldsDisabled)
        #expect(proof.editorReadOnlyCaption == MicroHabitsSnapshot.editorReadOnlyCaptionText)
        #expect(proof.editorAllowsHitTesting == false)
        #expect(proof.editorFieldOpacity < 1)
    }

    @MainActor
    @Test("renders a high-resolution SUMI-E micro-habits proof PNG")
    func microHabitsProofPNG() throws {
        let url = MicroHabitsProofRenderer.defaultProofURL
        try MicroHabitsProofRenderer.renderPNG(snapshot: .proof, to: url, scale: 3)

        #expect(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        #expect(data.count > 12_000)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        let image = NSImage(data: data)
        #expect(image != nil)
        #expect((image?.size.width ?? 0) >= 440)
        #expect((image?.size.height ?? 0) >= 780)
        #expect(url.lastPathComponent == "micro_habits_proof.png")
        #expect(url.path.contains("/screenshots/"))

        let proof = MicroHabitsSnapshot.proof
        #expect(proof.governance.bannerCaption.contains("CONFIG LOCKED"))
        #expect(proof.editorIsLocked)
        #expect(proof.lastFeedback == "+0.25c")
    }
}

@Suite("Slice 8 adversarial hardening", .serialized)
struct Slice8AdversarialHardeningTests {
    @Test("EARNED_HABIT mint is idempotent for the same completion reference")
    func earnedHabitMintIsIdempotent() throws {
        let ledger = try SQLiteEconomicLedger(fileURL: EconomicLedgerLocation.makeIsolatedFileURL())
        let harness = HabitHarness(bypass: true, sqlite: ledger)
        let habit = try harness.habits.createHabit(title: "Make Bed")
        let completionID = UUID()
        let first = try harness.engine.mintEarnedHabit(
            completionID: completionID,
            amount: 0.25,
            habitTitle: habit.title
        )
        #expect(first.creditsMinted == 0.25)
        #expect(first.transaction?.referenceID == HabitCreditMinting.walletReference(completionID: completionID))

        let second = try harness.engine.mintEarnedHabit(
            completionID: completionID,
            amount: 0.5,
            habitTitle: habit.title
        )
        #expect(second.creditsMinted == 0.25)
        #expect(second.transaction?.id == first.transaction?.id)
        #expect(try ledger.allTransactions().filter { $0.transactionType == .earnedHabit }.count == 1)
        #expect(try ledger.latestBalance() == 0.25)

        do {
            try ledger.appendTransaction(
                WalletTransaction(
                    timestamp: harness.wall.now(),
                    amount: 0.25,
                    balanceAfter: 0.5,
                    transactionType: .earnedHabit,
                    referenceID: HabitCreditMinting.walletReference(completionID: completionID),
                    description: "duplicate"
                )
            )
            Issue.record("duplicate EARNED_HABIT reference must fail unique index")
        } catch let error as EconomicLedgerError {
            #expect(error == .duplicateTransaction)
        }
    }

    @Test("engine clips a habit mint that would exceed the 1.5 daily ceiling")
    func engineClipsHabitCeiling() throws {
        let harness = HabitHarness(bypass: true)
        for index in 1...5 {
            let habit = try harness.habits.createHabit(title: "H\(index)")
            _ = try harness.habits.complete(habitID: habit.id)
        }
        #expect(try harness.engine.earnedHabitCredits(onLocalDay: harness.dayKey()) == 1.25)

        let clipped = try harness.engine.mintEarnedHabit(
            completionID: UUID(),
            amount: 0.5,
            habitTitle: "Overflow"
        )
        #expect(clipped.creditsMinted == 0.25)
        #expect(clipped.clipped)
        #expect(clipped.dailyEarnedAfter == 1.5)

        let refused = try harness.engine.mintEarnedHabit(
            completionID: UUID(),
            amount: 0.25,
            habitTitle: "Over"
        )
        #expect(refused.creditsMinted == 0)
        #expect(refused.transaction == nil)
        #expect(try harness.engine.earnedHabitCredits(onLocalDay: harness.dayKey()) == 1.5)
    }

    @Test("disabled habits cannot complete")
    func disabledHabitCannotComplete() throws {
        let harness = HabitHarness(bypass: true)
        let habit = try harness.habits.createHabit(title: "Evening Journal")
        _ = try harness.habits.setEnabled(id: habit.id, isEnabled: false)
        do {
            _ = try harness.habits.complete(habitID: habit.id)
            Issue.record("disabled habit must not complete")
        } catch let error as MicroHabitError {
            #expect(error == .habitDisabled)
        }
        #expect(harness.engine.walletBalance == 0)
    }

    @Test("invalid habit payloads fail closed without starting the lock")
    func invalidHabitPayloads() throws {
        let harness = HabitHarness()
        do {
            _ = try harness.habits.createHabit(title: "   ")
            Issue.record("blank title must fail")
        } catch let error as MicroHabitError {
            #expect(error == .invalidTitle)
        }
        do {
            _ = try harness.habits.createHabit(title: "OK", rewardCredits: 0.10)
            Issue.record("reward below 0.25 must fail")
        } catch let error as MicroHabitError {
            #expect(error == .invalidReward)
        }
        do {
            _ = try harness.habits.createHabit(title: "OK", dailyFrequencyLimit: 3)
            Issue.record("frequency 3 must fail")
        } catch let error as MicroHabitError {
            #expect(error == .invalidFrequency)
        }
        #expect(harness.governance.snapshot().isLocked == false)
        #expect(try harness.store.allHabits().isEmpty)
    }

    @Test("reboot plus wall-clock advance cannot expire an active cooldown")
    func rebootAndWallAdvanceFailClosed() throws {
        let store = InMemoryMicroHabitStore()
        let first = HabitHarness(store: store, boot: "boot-a")
        _ = try first.habits.createHabit(title: "Make Bed")
        #expect(first.governance.snapshot().isLocked)

        let wall = ManualWallClock(first.wall.now().addingTimeInterval(GovernanceLockPolicy.cooldownSeconds + 60))
        let mono = ManualMonotonicClock(startingAt: 0)
        let timeTravel = TimeTravelGuard()
        let engine = ExchangeEngine(
            ledger: first.ledger,
            clock: mono,
            focusClock: mono,
            wallClock: wall,
            timeTravel: timeTravel,
            timeZone: SliceTestCivil.timeZone
        )
        let governance = GovernanceLockCoordinator(
            store: store,
            clock: mono,
            wallClock: wall,
            timeTravel: timeTravel,
            bootSessionUUID: "boot-b",
            environment: [:],
            keyProvider: first.keyProvider
        )
        let habits = MicroHabitCoordinator(
            store: store,
            engine: engine,
            governance: governance,
            wallClock: wall,
            timeZone: SliceTestCivil.timeZone
        )
        do {
            _ = try habits.createHabit(title: "Cheat")
            Issue.record("reboot + wall advance must fail closed")
        } catch is GovernanceLockError {
            ()
        }
        #expect(governance.snapshot().isLocked)
    }

    @Test("SQLite schema exposes micro_habits, completions, and governance_state")
    func sqliteTablesExist() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ledger = try SQLiteEconomicLedger(fileURL: EconomicLedgerLocation.makeIsolatedFileURL())
        let habit = MicroHabit(
            title: "Make Bed",
            createdAt: now,
            updatedAt: now
        )
        try ledger.upsertHabit(habit)
        try ledger.insertCompletion(
            MicroHabitCompletion(
                habitID: habit.id,
                civilDate: "2023-11-14",
                creditsAwarded: 0.25,
                createdAt: now
            )
        )
        try ledger.saveGovernanceState(
            GovernanceState(
                lastConfigurationMutationAt: now,
                lastConfigurationMutationMonotonic: 10,
                mutationBootSessionUUID: "boot-test",
                lastObservedWall: now,
                lastObservedMonotonic: 10,
                lastObservedBootSessionUUID: "boot-test",
                accruedMonotonicElapsed: 12
            )
        )
        try ledger.upsertAmenityPriceOverride(kind: .food, cost: 1.0, updatedAt: now)
        try ledger.upsertBlocklistRule(BlocklistRule(suffix: "example.com", createdAt: now))
        #expect(try ledger.allHabits().count == 1)
        #expect(try ledger.allCompletions().count == 1)
        #expect(try ledger.loadGovernanceState().lastConfigurationMutationAt != nil)
        #expect(try ledger.loadGovernanceState().accruedMonotonicElapsed == 12)
        #expect(try ledger.loadAmenityPriceOverrides()[.food] == 1.0)
        #expect(try ledger.loadBlocklistRules().map(\.suffix) == ["example.com"])
    }
}

final class HabitHarness: @unchecked Sendable {
    let civil: LocalCivilClock
    let wall: ManualWallClock
    let mono: ManualMonotonicClock
    let timeTravel: TimeTravelGuard
    let ledger: any EconomicLedger
    let store: any MicroHabitStoring & GovernanceStoring
    let engine: ExchangeEngine
    let governance: GovernanceLockCoordinator
    let habits: MicroHabitCoordinator
    let keyProvider: InMemoryGovernanceKeyProvider

    init(
        year: Int = 2026,
        month: Int = 9,
        day: Int = 10,
        hour: Int = 10,
        minute: Int = 0,
        bypass: Bool = false,
        environment: [String: String] = [:],
        sqlite: SQLiteEconomicLedger? = nil,
        store: (any MicroHabitStoring & GovernanceStoring)? = nil,
        ledger: (any EconomicLedger)? = nil,
        boot: String = "boot-test",
        timeZone: TimeZone = SliceTestCivil.timeZone,
        wall: ManualWallClock? = nil,
        mono: ManualMonotonicClock? = nil,
        timeTravel: TimeTravelGuard? = nil,
        keyProvider: InMemoryGovernanceKeyProvider? = nil,
        replicaSealStore: (any GovernanceSealPersisting)? = nil
    ) {
        let civil = LocalCivilClock(timeZone: timeZone)
        let start = civil.date(year: year, month: month, day: day, hour: hour, minute: minute)
        self.wall = wall ?? ManualWallClock(start)
        self.mono = mono ?? ManualMonotonicClock()
        self.timeTravel = timeTravel ?? TimeTravelGuard()
        self.keyProvider = keyProvider ?? InMemoryGovernanceKeyProvider()

        if let sqlite {
            self.ledger = sqlite
            self.store = sqlite
        } else if let store {
            self.ledger = ledger ?? InMemoryEconomicLedger()
            self.store = store
        } else {
            self.ledger = ledger ?? InMemoryEconomicLedger()
            self.store = InMemoryMicroHabitStore()
        }

        let testConfiguration = bypass ? GovernanceLockTestConfiguration(bypassCooldown: true) : nil
        self.governance = GovernanceLockCoordinator(
            store: self.store,
            clock: self.mono,
            wallClock: self.wall,
            timeTravel: self.timeTravel,
            bootSessionUUID: boot,
            environment: environment,
            keyProvider: self.keyProvider,
            replicaSealStore: replicaSealStore,
            pinnedTimeZone: timeZone,
            testConfiguration: testConfiguration
        )
        let pinned = self.governance.pinnedTimeZone
        self.civil = LocalCivilClock(timeZone: pinned)
        self.engine = ExchangeEngine(
            ledger: self.ledger,
            clock: self.mono,
            focusClock: self.mono,
            wallClock: self.wall,
            timeTravel: self.timeTravel,
            timeZone: pinned,
            habitWindow: self.store
        )
        self.habits = MicroHabitCoordinator(
            store: self.store,
            engine: engine,
            governance: governance,
            wallClock: self.wall,
            timeZone: pinned
        )
    }

    func dayKey() -> String {
        civil.dayKey(wall.now())
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
