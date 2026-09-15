import Foundation

/// Micro-habit CRUD and completion. Config writes go through the 48-hour lock;
/// completions mint `EARNED_HABIT` into the wallet immediately.
public final class MicroHabitCoordinator: @unchecked Sendable {
    public let store: any MicroHabitStoring
    public let engine: ExchangeEngine
    public let governance: GovernanceLockCoordinator
    public let civilClock: LocalCivilClock

    private let wallClock: any WallClockProviding
    private let lock = NSLock()
    private var lastError: String?
    private var lastFeedback: String?
    private var lastCompletedID: UUID?

    public init(
        store: any MicroHabitStoring,
        engine: ExchangeEngine,
        governance: GovernanceLockCoordinator,
        wallClock: (any WallClockProviding)? = nil,
        timeZone: TimeZone = .current
    ) {
        self.store = store
        self.engine = engine
        self.governance = governance
        self.wallClock = wallClock ?? SystemWallClock()
        let pinned = governance.ensurePinnedTimeZone()
        _ = timeZone
        self.civilClock = LocalCivilClock(timeZone: pinned)
        governance.bind(engine: engine)
    }

    public var lastErrorMessage: String? {
        withLock { lastError }
    }

    public var lastFeedbackCaption: String? {
        withLock { lastFeedback }
    }

    @discardableResult
    public func createHabit(
        title: String,
        rewardCredits: Double = HabitCreditMinting.defaultReward,
        dailyFrequencyLimit: Int = HabitCreditMinting.minDailyFrequency,
        isEnabled: Bool = true,
        id: UUID = UUID()
    ) throws -> MicroHabit {
        let habit = try makeHabit(
            id: id,
            title: title,
            rewardCredits: rewardCredits,
            dailyFrequencyLimit: dailyFrequencyLimit,
            isEnabled: isEnabled,
            createdAt: wallClock.now(),
            updatedAt: wallClock.now()
        )
        do {
            try governance.performMutation {
                try store.upsertHabit(habit)
            }
            rememberSuccess()
            return habit
        } catch {
            remember(error)
            throw error
        }
    }

    @discardableResult
    public func updateHabit(
        id: UUID,
        title: String? = nil,
        rewardCredits: Double? = nil,
        dailyFrequencyLimit: Int? = nil,
        isEnabled: Bool? = nil
    ) throws -> MicroHabit {
        do {
            return try governance.performMutation {
                guard var habit = try store.habit(id: id) else {
                    throw MicroHabitError.habitNotFound
                }
                if let title {
                    guard let sanitized = HabitCreditMinting.sanitizedTitle(title) else {
                        throw MicroHabitError.invalidTitle
                    }
                    habit.title = sanitized
                }
                if let rewardCredits {
                    guard let reward = HabitCreditMinting.validatedReward(rewardCredits) else {
                        throw MicroHabitError.invalidReward
                    }
                    habit.rewardCredits = reward
                }
                if let dailyFrequencyLimit {
                    guard let frequency = HabitCreditMinting.validatedFrequency(dailyFrequencyLimit) else {
                        throw MicroHabitError.invalidFrequency
                    }
                    habit.dailyFrequencyLimit = frequency
                }
                if let isEnabled {
                    habit.isEnabled = isEnabled
                }
                habit.updatedAt = wallClock.now()
                try store.upsertHabit(habit)
                return habit
            }
        } catch {
            remember(error)
            throw error
        }
    }

    @discardableResult
    public func setEnabled(id: UUID, isEnabled: Bool) throws -> MicroHabit {
        try updateHabit(id: id, isEnabled: isEnabled)
    }

    @discardableResult
    public func complete(habitID: UUID, completionID: UUID = UUID()) throws -> HabitCompletionOutcome {
        do {
            try ensureWritable()
            return try withLock {
                try ensureWritableLocked()
                guard let habit = try store.habit(id: habitID) else {
                    throw MicroHabitError.habitNotFound
                }
                guard habit.isEnabled else {
                    throw MicroHabitError.habitDisabled
                }

                let now = wallClock.now()
                let nowMono = governance.clock.nowSeconds()
                let day = civilClock.dayKey(now)
                let already = try store.completions(habitID: habit.id, on: day)
                if already.count >= habit.dailyFrequencyLimit {
                    throw MicroHabitError.dailyFrequencyReached
                }

                let earnedCivil = try engine.earnedHabitCredits(onLocalDay: day)
                let windowStart = nowMono - HabitCreditMinting.rollingWindowSeconds
                let earnedRolling = try store.earnedHabitCredits(
                    fromMonotonic: windowStart,
                    through: nowMono
                )
                let earnedToday = HabitCreditMinting.cappedEarned(
                    civilDay: earnedCivil,
                    rollingWindow: earnedRolling
                )
                let remaining = HabitCreditMinting.remainingDailyBudget(earnedToday: earnedToday)
                if remaining <= 0 {
                    throw MicroHabitError.dailyCreditCeilingReached
                }

                let amount = HabitCreditMinting.clippedCredits(
                    requested: habit.rewardCredits,
                    earnedToday: earnedToday
                )
                guard amount > 0 else {
                    throw MicroHabitError.dailyCreditCeilingReached
                }

                let completion = MicroHabitCompletion(
                    id: completionID,
                    habitID: habit.id,
                    civilDate: day,
                    creditsAwarded: amount,
                    createdAt: now,
                    createdMonotonic: nowMono
                )

                let outcome = try engine.mintEarnedHabitAndThen(
                    completionID: completion.id,
                    amount: amount,
                    habitTitle: habit.title
                ) { mint in
                    guard mint.transaction != nil, mint.creditsMinted > 0 else {
                        throw MicroHabitError.dailyCreditCeilingReached
                    }
                    try store.insertCompletion(completion)
                    return mint
                }

                guard let transaction = outcome.transaction, outcome.creditsMinted > 0 else {
                    throw MicroHabitError.dailyCreditCeilingReached
                }

                let result = HabitCompletionOutcome(
                    completion: completion,
                    transaction: transaction,
                    creditsMinted: outcome.creditsMinted,
                    dailyHabitCreditsAfter: outcome.dailyEarnedAfter,
                    clipped: outcome.clipped
                )
                lastError = nil
                lastFeedback = result.feedbackCaption
                lastCompletedID = habit.id
                return result
            }
        } catch let ExchangeEngineError.clockTampered(skew) {
            let mapped = MicroHabitError.clockTampered(skewSeconds: skew)
            remember(mapped)
            throw mapped
        } catch {
            remember(error)
            throw error
        }
    }

    public func snapshot(ticker: MenuBarTickerSnapshot? = nil) -> MicroHabitsSnapshot {
        let lockSnap = governance.snapshot()
        let now = wallClock.now()
        let nowMono = governance.clock.nowSeconds()
        let day = civilClock.dayKey(now)
        let habits = (try? store.allHabits()) ?? []
        let earnedCivil = (try? engine.earnedHabitCredits(onLocalDay: day)) ?? 0
        let earnedRolling = (try? store.earnedHabitCredits(
            fromMonotonic: nowMono - HabitCreditMinting.rollingWindowSeconds,
            through: nowMono
        )) ?? 0
        let earned = HabitCreditMinting.cappedEarned(civilDay: earnedCivil, rollingWindow: earnedRolling)
        let remainingBudget = HabitCreditMinting.remainingDailyBudget(earnedToday: earned)
        let captured = withLock { (lastError, lastFeedback, lastCompletedID) }
        let tickerSnap = ticker ?? ((try? engine.snapshot()) ?? .proof)

        let rows: [MicroHabitRowSnapshot] = habits.map { habit in
            let count = (try? store.completions(habitID: habit.id, on: day).count) ?? 0
            let frequencyReached = count >= habit.dailyFrequencyLimit
            let capReached = remainingBudget <= 0
            let canComplete = habit.isEnabled && !frequencyReached && !capReached
            let status: String
            if !habit.isEnabled {
                status = "OFF"
            } else if capReached && !frequencyReached {
                status = "CAP"
            } else if frequencyReached {
                status = "DONE"
            } else {
                status = "\(count) / \(habit.dailyFrequencyLimit)"
            }
            return MicroHabitRowSnapshot(
                id: habit.id,
                title: habit.title,
                rewardCredits: habit.rewardCredits,
                dailyFrequencyLimit: habit.dailyFrequencyLimit,
                completionsToday: count,
                isEnabled: habit.isEnabled,
                canComplete: canComplete,
                statusCaption: status,
                lastFeedback: captured.2 == habit.id ? captured.1 : nil
            )
        }

        return MicroHabitsSnapshot(
            habits: rows,
            dailyHabitCredits: earned,
            dailyCap: HabitCreditMinting.dailyCreditCap,
            governance: lockSnap,
            lastFeedback: captured.1,
            lastError: captured.0,
            spendableBalance: tickerSnap.spendableBalance,
            weekdayCaption: tickerSnap.weekdayCaption,
            localDayKey: tickerSnap.localDayKey,
            editorIsLocked: (lockSnap.isLocked && !lockSnap.isBypassEnabled) || lockSnap.integrityFailed
        )
    }

    private func makeHabit(
        id: UUID,
        title: String,
        rewardCredits: Double,
        dailyFrequencyLimit: Int,
        isEnabled: Bool,
        createdAt: Date,
        updatedAt: Date
    ) throws -> MicroHabit {
        guard let sanitized = HabitCreditMinting.sanitizedTitle(title) else {
            throw MicroHabitError.invalidTitle
        }
        guard let reward = HabitCreditMinting.validatedReward(rewardCredits) else {
            throw MicroHabitError.invalidReward
        }
        guard let frequency = HabitCreditMinting.validatedFrequency(dailyFrequencyLimit) else {
            throw MicroHabitError.invalidFrequency
        }
        return MicroHabit(
            id: id,
            title: sanitized,
            rewardCredits: reward,
            dailyFrequencyLimit: frequency,
            isEnabled: isEnabled,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func ensureWritable() throws {
        do {
            try engine.ensureEconomyWritable()
        } catch let ExchangeEngineError.clockTampered(skew) {
            throw MicroHabitError.clockTampered(skewSeconds: skew)
        }
    }

    private func ensureWritableLocked() throws {
        do {
            try engine.ensureEconomyWritable()
        } catch let ExchangeEngineError.clockTampered(skew) {
            throw MicroHabitError.clockTampered(skewSeconds: skew)
        }
    }

    private func rememberSuccess() {
        withLock {
            lastError = nil
        }
    }

    private func remember(_ error: Error) {
        withLock {
            if let habit = error as? MicroHabitError, let description = habit.errorDescription {
                lastError = description
            } else if let lock = error as? GovernanceLockError, let description = lock.errorDescription {
                lastError = description
            } else {
                lastError = error.localizedDescription
            }
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
