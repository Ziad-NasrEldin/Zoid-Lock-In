import Foundation

/// Persistence seam for micro-habits and completions. SQLite lives in user space only.
public protocol MicroHabitStoring: Sendable {
    func upsertHabit(_ habit: MicroHabit) throws
    func habit(id: UUID) throws -> MicroHabit?
    func allHabits() throws -> [MicroHabit]
    func insertCompletion(_ completion: MicroHabitCompletion) throws
    func completion(id: UUID) throws -> MicroHabitCompletion?
    func completions(habitID: UUID, on day: String) throws -> [MicroHabitCompletion]
    func completions(on day: String) throws -> [MicroHabitCompletion]
    func allCompletions() throws -> [MicroHabitCompletion]
    func earnedHabitCredits(fromMonotonic start: TimeInterval, through end: TimeInterval) throws -> Double
}

/// Persistence seam for the 48-hour governance lock and related config tables.
public protocol GovernanceStoring: Sendable {
    func loadGovernanceState() throws -> GovernanceState
    func saveGovernanceState(_ state: GovernanceState) throws
    func loadGovernanceEnvelope() throws -> GovernanceSealEnvelope?
    func saveGovernanceEnvelope(_ envelope: GovernanceSealEnvelope) throws
    func loadAmenityPriceOverrides() throws -> [AmenityKind: Double]
    func upsertAmenityPriceOverride(kind: AmenityKind, cost: Double, updatedAt: Date) throws
    func loadBlocklistRules() throws -> [BlocklistRule]
    func upsertBlocklistRule(_ rule: BlocklistRule) throws
    func deleteBlocklistRule(suffix: String) throws
}

public extension MicroHabitStoring {
    func earnedHabitCredits(fromMonotonic start: TimeInterval, through end: TimeInterval) throws -> Double {
        CreditMath.normalize(
            try allCompletions()
                .filter { $0.createdMonotonic > start && $0.createdMonotonic <= end }
                .reduce(0) { $0 + $1.creditsAwarded }
        )
    }
}

/// Deterministic in-memory adapter used by coordinator tests.
public final class InMemoryMicroHabitStore: MicroHabitStoring, GovernanceStoring, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var habits: [UUID: MicroHabit] = [:]
    private var completions: [UUID: MicroHabitCompletion] = [:]
    private var governance = GovernanceState.empty
    private var envelope: GovernanceSealEnvelope?
    private var prices: [AmenityKind: Double] = [:]
    private var blocklist: [String: BlocklistRule] = [:]

    public init() {}

    public func upsertHabit(_ habit: MicroHabit) throws {
        withLock { habits[habit.id] = habit }
    }

    public func habit(id: UUID) throws -> MicroHabit? {
        withLock { habits[id] }
    }

    public func allHabits() throws -> [MicroHabit] {
        withLock {
            habits.values.sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.title < rhs.title
                }
                return lhs.createdAt < rhs.createdAt
            }
        }
    }

    public func insertCompletion(_ completion: MicroHabitCompletion) throws {
        try withLock {
            if completions[completion.id] != nil {
                throw MicroHabitError.duplicateCompletion
            }
            completions[completion.id] = completion
        }
    }

    public func completion(id: UUID) throws -> MicroHabitCompletion? {
        withLock { completions[id] }
    }

    public func completions(habitID: UUID, on day: String) throws -> [MicroHabitCompletion] {
        try allCompletions().filter { $0.habitID == habitID && $0.civilDate == day }
    }

    public func completions(on day: String) throws -> [MicroHabitCompletion] {
        try allCompletions().filter { $0.civilDate == day }
    }

    public func allCompletions() throws -> [MicroHabitCompletion] {
        withLock {
            completions.values.sorted { $0.createdAt < $1.createdAt }
        }
    }

    public func loadGovernanceState() throws -> GovernanceState {
        withLock { governance }
    }

    public func saveGovernanceState(_ state: GovernanceState) throws {
        withLock { governance = state }
    }

    public func loadGovernanceEnvelope() throws -> GovernanceSealEnvelope? {
        withLock { envelope }
    }

    public func saveGovernanceEnvelope(_ envelope: GovernanceSealEnvelope) throws {
        withLock { self.envelope = envelope }
    }

    public func loadAmenityPriceOverrides() throws -> [AmenityKind: Double] {
        withLock { prices }
    }

    public func upsertAmenityPriceOverride(kind: AmenityKind, cost: Double, updatedAt: Date) throws {
        _ = updatedAt
        withLock { prices[kind] = CreditMath.normalize(cost) }
    }

    public func loadBlocklistRules() throws -> [BlocklistRule] {
        withLock {
            blocklist.values.sorted { $0.createdAt < $1.createdAt }
        }
    }

    public func upsertBlocklistRule(_ rule: BlocklistRule) throws {
        withLock { blocklist[rule.suffix] = rule }
    }

    public func deleteBlocklistRule(suffix: String) throws {
        let key = DomainFilterRules.normalize(suffix)
        withLock { _ = blocklist.removeValue(forKey: key) }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
