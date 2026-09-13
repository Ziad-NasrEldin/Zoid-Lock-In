import Foundation

public enum ExchangeEngineError: Error, Equatable, Sendable {
    case clockTampered(skewSeconds: TimeInterval)
    case focusAlreadyActive
    case noActiveFocus
    case sessionAbandoned
    case insufficientCredits(need: Double, have: Double)
    case curfew
    case alreadyReconciled
}

/// Deterministic daily economy. All minting, grace, curfew, Friday rest,
/// midnight reconciliation, and emergency netting converge here.
public final class ExchangeEngine: @unchecked Sendable {
    public let ledger: any EconomicLedger
    public let incidentStore: any EmergencyIncidentStoring
    public let catalog: AmenityCatalog
    public let civilClock: LocalCivilClock

    private let clock: any MonotonicTimeProviding
    private let focusClock: any MonotonicTimeProviding
    private let wallClock: any WallClockProviding
    private let activityDetector: any ActivityDetecting
    private let timeTravel: TimeTravelGuard
    private let lock = NSRecursiveLock()

    private var liveSession: FocusSessionRecord?
    private var lastTickMonotonic: TimeInterval?

    public init(
        ledger: any EconomicLedger,
        incidentStore: any EmergencyIncidentStoring = InMemoryEmergencyIncidentStore(),
        clock: any MonotonicTimeProviding = MachContinuousTimeClock(),
        focusClock: (any MonotonicTimeProviding)? = nil,
        wallClock: any WallClockProviding = SystemWallClock(),
        activityDetector: any ActivityDetecting = CGEventIdleMonitor(),
        timeTravel: TimeTravelGuard = TimeTravelGuard(),
        timeZone: TimeZone = .current,
        catalog: AmenityCatalog = .standard
    ) {
        self.ledger = ledger
        self.incidentStore = incidentStore
        self.clock = clock
        self.focusClock = focusClock ?? MachUptimeClock()
        self.wallClock = wallClock
        self.activityDetector = activityDetector
        self.timeTravel = timeTravel
        self.civilClock = LocalCivilClock(timeZone: timeZone)
        self.catalog = catalog
        restoreLiveSession()
    }

    public var walletBalance: Double {
        withLock { (try? ledger.latestBalance()) ?? 0 }
    }

    public var spendableBalance: Double {
        CreditMath.spendable(walletBalance)
    }

    public var isClockTampered: Bool {
        timeTravel.isTampered
    }

    public var activeFocusSession: FocusSessionRecord? {
        withLock { liveSession }
    }

    public func snapshot() throws -> MenuBarTickerSnapshot {
        try withLock {
            _ = timeTravel.observe(wall: wallClock.now(), monotonic: clock.nowSeconds())
            return try makeSnapshotLocked()
        }
    }

    @discardableResult
    public func tick() throws -> MenuBarTickerSnapshot {
        try withLock {
            try observeClocksLocked()
            try reconcileIfNeededLocked()
            try syncFocusLocked()
            return try makeSnapshotLocked()
        }
    }

    @discardableResult
    public func startFocus(id: UUID = UUID()) throws -> FocusSessionRecord {
        try withLock {
            try observeClocksLocked()
            try ensureWritableLocked()
            try reconcileIfNeededLocked()
            if let liveSession, liveSession.state == .active || liveSession.state == .pausedGrace {
                throw ExchangeEngineError.focusAlreadyActive
            }
            if FocusMinting.presence(idleSeconds: activityDetector.secondsSinceLastPhysicalEvent())
                == .abandoned {
                throw ExchangeEngineError.sessionAbandoned
            }

            let nowWall = wallClock.now()
            let nowMono = focusClock.nowSeconds()
            let idle = activityDetector.secondsSinceLastPhysicalEvent()
            let session = FocusSessionRecord(
                id: id,
                startTime: nowWall,
                elapsedSeconds: 0,
                state: FocusMinting.presence(idleSeconds: idle) == .grace ? .pausedGrace : .active
            )
            liveSession = session
            lastTickMonotonic = nowMono
            try ledger.upsertFocusSession(session)
            return session
        }
    }

    @discardableResult
    public func completeFocus() throws -> FocusSessionRecord {
        try withLock {
            try observeClocksLocked()
            try ensureWritableLocked()
            try syncFocusLocked()
            guard var session = liveSession else {
                throw ExchangeEngineError.noActiveFocus
            }
            if session.state == .abandoned {
                throw ExchangeEngineError.sessionAbandoned
            }

            let nowWall = wallClock.now()
            session.endTime = nowWall
            session.state = .completed
            try mintUnpaidLocked(&session)
            try applyMorningMomentumIfNeededLocked(&session, completedAt: nowWall)
            try ledger.upsertFocusSession(session)
            liveSession = nil
            lastTickMonotonic = nil
            return session
        }
    }

    @discardableResult
    public func purchase(_ kind: AmenityKind) throws -> WalletTransaction {
        try withLock {
            try observeClocksLocked()
            try ensureWritableLocked()
            try reconcileIfNeededLocked()

            let now = wallClock.now()
            if civilClock.isCurfew(now) && catalog.isBlockedByCurfew(kind) {
                throw ExchangeEngineError.curfew
            }

            let friday = civilClock.isFriday(now)
            let cost = catalog.cost(of: kind, fridayRestMode: friday)
            return try ledger.performAtomically {
                let balance = try ledger.latestBalance()
                let spendable = CreditMath.spendable(balance)
                if cost > spendable {
                    throw ExchangeEngineError.insufficientCredits(need: cost, have: spendable)
                }

                let next = CreditMath.normalize(balance - cost)
                let transaction = WalletTransaction(
                    timestamp: now,
                    amount: -cost,
                    balanceAfter: next,
                    transactionType: .spend,
                    referenceID: kind.rawValue,
                    description: purchaseDescription(kind, cost: cost, fridayRestMode: friday)
                )
                try ledger.appendTransaction(transaction)
                return transaction
            }
        }
    }

    @discardableResult
    public func reconcileIfNeeded() throws -> DailyReconciliationRecord? {
        try withLock {
            try observeClocksLocked()
            try ensureWritableLocked()
            return try reconcileIfNeededLocked()
        }
    }

    @discardableResult
    public func reconcile(forLocalDay day: String) throws -> DailyReconciliationRecord {
        try withLock {
            try observeClocksLocked()
            try ensureWritableLocked()
            return try reconcileLocked(day: day)
        }
    }

    private func restoreLiveSession() {
        let sessions = (try? ledger.allFocusSessions()) ?? []
        liveSession = sessions.last(where: { $0.state == .active || $0.state == .pausedGrace })
        lastTickMonotonic = focusClock.nowSeconds()
    }

    @discardableResult
    private func reconcileIfNeededLocked() throws -> DailyReconciliationRecord? {
        let now = wallClock.now()
        let yesterday = civilClock.dayKey(civilClock.previousDay(now))
        guard let startDay = try firstUnreconciledDay(through: yesterday) else {
            return nil
        }

        var last: DailyReconciliationRecord?
        var day = startDay
        while day <= yesterday {
            if try ledger.reconciliation(onDay: day) == nil {
                last = try reconcileLocked(day: day)
            }
            guard let next = civilClock.nextDayKey(day) else { break }
            day = next
        }
        return last
    }

    private func firstUnreconciledDay(through yesterday: String) throws -> String? {
        if let latest = try ledger.latestReconciliationDay() {
            guard let next = civilClock.nextDayKey(latest), next <= yesterday else {
                return nil
            }
            return next
        }

        var days: [String] = []
        days.append(contentsOf: try ledger.allTransactions().map { civilClock.dayKey($0.timestamp) })
        days.append(contentsOf: try ledger.allFocusSessions().map { civilClock.dayKey($0.startTime) })
        days.append(contentsOf: incidentStore.allIncidents().map { civilClock.dayKey($0.utcTimestamp) })
        let earliest = days.filter { $0 <= yesterday }.min()
        return earliest
    }

    private func reconcileLocked(day: String) throws -> DailyReconciliationRecord {
        if try ledger.reconciliation(onDay: day) != nil {
            throw ExchangeEngineError.alreadyReconciled
        }

        return try ledger.performAtomically {
            try finalizeOpenSessionLocked(forDay: day)

            let dayTransactions = try ledger.transactions(onLocalDay: day, clock: civilClock)
            let earned = CreditMath.normalize(
                dayTransactions
                    .filter { $0.transactionType == .mint }
                    .reduce(0) { $0 + $1.amount }
            )
            let spent = CreditMath.normalize(
                dayTransactions
                    .filter { $0.transactionType == .spend }
                    .reduce(0) { $0 + abs($1.amount) }
            )

            var vault = try ledger.loadVault()
            var balance = try ledger.latestBalance()
            var swept: Double = 0
            let friday = isFriday(dayKey: day)
            let closeTime = closeTimestamp(forDay: day)

            if balance > 0 {
                swept = balance
                balance = 0
                try ledger.appendTransaction(
                    WalletTransaction(
                        timestamp: closeTime,
                        amount: -swept,
                        balanceAfter: 0,
                        transactionType: .surplusTransfer,
                        referenceID: day,
                        description: "Midnight surplus sweep \(day)"
                    )
                )
                vault.totalSurplusCredits = CreditMath.normalize(vault.totalSurplusCredits + swept)
            } else if balance == 0 {
                try ledger.appendTransaction(
                    WalletTransaction(
                        timestamp: closeTime,
                        amount: 0,
                        balanceAfter: 0,
                        transactionType: .reset,
                        referenceID: day,
                        description: "Midnight reset \(day)"
                    )
                )
            }

            var deficitApplied = false
            if !friday && earned < FocusMinting.dailyTargetCredits {
                deficitApplied = true
                vault.currentStreak = 0
                balance = CreditMath.normalize(balance + FocusMinting.deficitStrikeCredits)
                try ledger.appendTransaction(
                    WalletTransaction(
                        timestamp: closeTime,
                        amount: FocusMinting.deficitStrikeCredits,
                        balanceAfter: balance,
                        transactionType: .penalty,
                        referenceID: "deficit:\(day)",
                        description: "Deficit strike −1.0 (earned \(CreditMath.normalize(earned)) < 3.0)"
                    )
                )
            } else if earned >= FocusMinting.dailyTargetCredits {
                vault.currentStreak += 1
                vault.highestStreak = max(vault.highestStreak, vault.currentStreak)
            }

            let levied = try ledger.leviedIncidentIDs()
            let unlevied = incidentStore.unleviedIncidents()
            for incident in unlevied {
                if levied.contains(incident.id.uuidString) {
                    try incidentStore.markLevied(id: incident.id)
                    continue
                }
                let penalty = PendingDebtRecord.emergencyPenaltyCredits
                balance = CreditMath.normalize(balance + penalty)
                try ledger.appendTransaction(
                    WalletTransaction(
                        timestamp: closeTime,
                        amount: penalty,
                        balanceAfter: balance,
                        transactionType: .penalty,
                        referenceID: incident.id.uuidString,
                        description: "Emergency safety valve −2.0 credit debt"
                    )
                )
                try incidentStore.markLevied(id: incident.id)
            }

            let record = DailyReconciliationRecord(
                date: day,
                earnedCredits: earned,
                spentCredits: spent,
                sweptToVault: swept,
                victoryStreakCount: vault.currentStreak,
                deficitStrikeApplied: deficitApplied,
                fridayRestMode: friday
            )
            try ledger.insertReconciliation(record)
            try ledger.saveVault(vault)
            return record
        }
    }

    private func finalizeOpenSessionLocked(forDay day: String) throws {
        guard let session = liveSession else { return }
        guard civilClock.dayKey(session.startTime) == day else { return }
        if session.state == .abandoned { return }

        try syncFocusLocked()
        guard var current = liveSession, current.state != .abandoned else { return }

        let close = closeTimestamp(forDay: day)
        current.endTime = close
        current.state = .completed
        try mintUnpaidLocked(&current)
        try applyMorningMomentumIfNeededLocked(&current, completedAt: close)
        try ledger.upsertFocusSession(current)
        liveSession = nil
        lastTickMonotonic = nil
    }

    private func observeClocksLocked() throws {
        timeTravel.observe(wall: wallClock.now(), monotonic: clock.nowSeconds())
        try ensureWritableLocked()
    }

    private func ensureWritableLocked() throws {
        do {
            try timeTravel.ensureWritable()
        } catch let TimeTravelError.clockTampered(skew) {
            throw ExchangeEngineError.clockTampered(skewSeconds: skew)
        }
    }

    private func syncFocusLocked() throws {
        guard var session = liveSession else { return }
        if session.state == .completed || session.state == .abandoned {
            return
        }

        let nowMono = focusClock.nowSeconds()
        let idle = activityDetector.secondsSinceLastPhysicalEvent()
        let lastTick = lastTickMonotonic ?? nowMono

        switch FocusMinting.presence(idleSeconds: idle) {
        case .abandoned:
            session.state = .abandoned
            session.endTime = wallClock.now()
            try ledger.upsertFocusSession(session)
            liveSession = session
            lastTickMonotonic = nowMono
            return
        case .grace:
            session.state = .pausedGrace
            lastTickMonotonic = nowMono
            try ledger.upsertFocusSession(session)
            liveSession = session
            return
        case .active:
            break
        }

        if session.state == .pausedGrace {
            session.state = .active
            lastTickMonotonic = nowMono
            try ledger.upsertFocusSession(session)
            liveSession = session
            return
        }

        session.elapsedSeconds += max(0, nowMono - lastTick)
        lastTickMonotonic = nowMono
        try ledger.performAtomically {
            try mintUnpaidLocked(&session)
            try ledger.upsertFocusSession(session)
        }
        liveSession = session
    }

    private func mintUnpaidLocked(_ session: inout FocusSessionRecord) throws {
        let due = FocusMinting.baseCredits(elapsedSeconds: session.elapsedSeconds)
        let already = session.creditsEarned
        let delta = CreditMath.normalize(due - already)
        guard delta > 0 else { return }
        try ensureWritableLocked()
        let balance = try ledger.latestBalance()
        let next = CreditMath.normalize(balance + delta)
        try ledger.appendTransaction(
            WalletTransaction(
                timestamp: wallClock.now(),
                amount: delta,
                balanceAfter: next,
                transactionType: .mint,
                referenceID: session.id.uuidString,
                description: "Focus mint +\(CreditMath.normalize(delta)) (\(Int(session.elapsedSeconds))s)"
            )
        )
        session.creditsEarned = CreditMath.normalize(already + delta)
    }

    private func applyMorningMomentumIfNeededLocked(
        _ session: inout FocusSessionRecord,
        completedAt: Date
    ) throws {
        let alreadyAwarded = try hasMorningMomentum(on: civilClock.dayKey(session.startTime), excluding: session.id)
        let qualifies = FocusMinting.qualifiesForMorningMomentum(
            elapsedSeconds: session.elapsedSeconds,
            startedAt: session.startTime,
            endedAt: completedAt,
            calendar: civilClock.calendar,
            alreadyAwardedToday: alreadyAwarded
        )
        guard qualifies else {
            session.multiplierApplied = FocusMinting.standardMultiplier
            return
        }

        let bonus = session.creditsEarned
        guard bonus > 0 else {
            session.multiplierApplied = FocusMinting.morningMomentumMultiplier
            return
        }

        let balance = try ledger.latestBalance()
        let next = CreditMath.normalize(balance + bonus)
        try ledger.appendTransaction(
            WalletTransaction(
                timestamp: completedAt,
                amount: bonus,
                balanceAfter: next,
                transactionType: .mint,
                referenceID: session.id.uuidString,
                description: "Morning Momentum 2.0×"
            )
        )
        session.creditsEarned = CreditMath.normalize(session.creditsEarned + bonus)
        session.multiplierApplied = FocusMinting.morningMomentumMultiplier
    }

    private func hasMorningMomentum(on day: String, excluding sessionID: UUID) throws -> Bool {
        let sessions = try ledger.allFocusSessions()
        return sessions.contains { other in
            other.id != sessionID
                && civilClock.dayKey(other.startTime) == day
                && other.multiplierApplied == FocusMinting.morningMomentumMultiplier
                && other.state == .completed
        }
    }

    private func makeSnapshotLocked() throws -> MenuBarTickerSnapshot {
        let now = wallClock.now()
        let vault = try ledger.loadVault()
        let balance = try ledger.latestBalance()
        let session = liveSession
        let elapsed = Int(session?.elapsedSeconds.rounded(.down) ?? 0)
        let chunk = FocusMinting.secondsPerHalfCredit
        let intoChunk = session.map { $0.elapsedSeconds.truncatingRemainder(dividingBy: chunk) } ?? 0
        let remaining = session == nil || session?.state == .abandoned
            ? 0
            : Int((chunk - intoChunk).rounded(.up))
        let friday = civilClock.isFriday(now)
        let curfew = civilClock.isCurfew(now)
        let tampered = timeTravel.isTampered

        let stateCaption: String
        if tampered {
            stateCaption = "Clock Tamper"
        } else if friday {
            stateCaption = "Friday Rest"
        } else if curfew {
            stateCaption = "Curfew"
        } else if session?.state == .active {
            stateCaption = civilClock.isBeforeNoon(now) ? "Morning Focus" : "Focus"
        } else if session?.state == .pausedGrace {
            stateCaption = "Grace"
        } else {
            stateCaption = "Idle"
        }

        return MenuBarTickerSnapshot(
            walletBalance: balance,
            spendableBalance: CreditMath.spendable(balance),
            focusState: session?.state,
            focusElapsedSeconds: elapsed,
            focusRemainingToNextMintSeconds: remaining,
            focusCreditsEarned: session?.creditsEarned ?? 0,
            multiplierApplied: session?.multiplierApplied ?? FocusMinting.standardMultiplier,
            currentStreak: vault.currentStreak,
            highestStreak: vault.highestStreak,
            lifetimeSurplus: vault.totalSurplusCredits,
            isFridayRest: friday,
            isCurfew: curfew,
            isClockTampered: tampered,
            localDayKey: civilClock.dayKey(now),
            weekdayCaption: civilClock.weekdayCaption(now),
            dayStateCaption: stateCaption
        )
    }

    private func isFriday(dayKey: String) -> Bool {
        guard let date = civilClock.date(fromDayKey: dayKey, hour: 12, minute: 0) else {
            return false
        }
        return civilClock.isFriday(date)
    }

    private func closeTimestamp(forDay day: String) -> Date {
        civilClock.date(fromDayKey: day, hour: 23, minute: 59, second: 59) ?? wallClock.now()
    }

    private func purchaseDescription(_ kind: AmenityKind, cost: Double, fridayRestMode: Bool) -> String {
        let label = kind.rawValue.replacingOccurrences(of: "_", with: " ")
        if fridayRestMode && catalog.isBasicComfort(kind) {
            return "Friday rest: \(label) at 0 credits"
        }
        return "Spend \(CreditMath.normalize(cost)) on \(label)"
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
