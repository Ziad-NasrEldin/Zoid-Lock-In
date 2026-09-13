import Foundation

/// User-space economic store. The privileged daemon must not implement this.
public protocol EconomicLedger: Sendable {
    func performAtomically<T>(_ body: () throws -> T) throws -> T

    func appendTransaction(_ transaction: WalletTransaction) throws
    func allTransactions() throws -> [WalletTransaction]
    func latestBalance() throws -> Double

    func upsertFocusSession(_ session: FocusSessionRecord) throws
    func focusSession(id: UUID) throws -> FocusSessionRecord?
    func allFocusSessions() throws -> [FocusSessionRecord]

    func insertReconciliation(_ record: DailyReconciliationRecord) throws
    func reconciliation(onDay day: String) throws -> DailyReconciliationRecord?
    func latestReconciliationDay() throws -> String?

    func loadVault() throws -> LifetimeVaultRecord
    func saveVault(_ vault: LifetimeVaultRecord) throws
}

public extension EconomicLedger {
    func transactions(onLocalDay day: String, clock: LocalCivilClock) throws -> [WalletTransaction] {
        try allTransactions().filter { clock.dayKey($0.timestamp) == day }
    }

    func leviedIncidentIDs() throws -> Set<String> {
        try Set(
            allTransactions()
                .filter { $0.transactionType == .penalty }
                .compactMap(\.referenceID)
        )
    }
}

/// In-memory append-only ledger for `ExchangeEngine` tests that do not need WAL.
public final class InMemoryEconomicLedger: EconomicLedger, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var transactions: [WalletTransaction] = []
    private var sessions: [UUID: FocusSessionRecord] = [:]
    private var reconciliations: [String: DailyReconciliationRecord] = [:]
    private var vault = LifetimeVaultRecord.empty

    public init() {}

    public func performAtomically<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public func appendTransaction(_ transaction: WalletTransaction) throws {
        try withLock {
            if transactions.contains(where: { $0.id == transaction.id }) {
                throw EconomicLedgerError.duplicateTransaction
            }
            if transaction.transactionType == .earnedMeeting,
               let reference = transaction.referenceID,
               transactions.contains(where: {
                   $0.transactionType == .earnedMeeting && $0.referenceID == reference
               }) {
                throw EconomicLedgerError.duplicateTransaction
            }
            transactions.append(transaction)
        }
    }

    public func allTransactions() throws -> [WalletTransaction] {
        withLock { transactions }
    }

    public func latestBalance() throws -> Double {
        withLock { transactions.last?.balanceAfter ?? 0 }
    }

    public func upsertFocusSession(_ session: FocusSessionRecord) throws {
        withLock { sessions[session.id] = session }
    }

    public func focusSession(id: UUID) throws -> FocusSessionRecord? {
        withLock { sessions[id] }
    }

    public func allFocusSessions() throws -> [FocusSessionRecord] {
        withLock { Array(sessions.values).sorted { $0.startTime < $1.startTime } }
    }

    public func insertReconciliation(_ record: DailyReconciliationRecord) throws {
        try withLock {
            if reconciliations[record.date] != nil {
                throw EconomicLedgerError.duplicateReconciliation
            }
            reconciliations[record.date] = record
        }
    }

    public func reconciliation(onDay day: String) throws -> DailyReconciliationRecord? {
        withLock { reconciliations[day] }
    }

    public func latestReconciliationDay() throws -> String? {
        withLock { reconciliations.keys.max() }
    }

    public func loadVault() throws -> LifetimeVaultRecord {
        withLock { vault }
    }

    public func saveVault(_ vault: LifetimeVaultRecord) throws {
        withLock { self.vault = vault }
    }

    /// Test seam: any attempt to rewrite a posted wallet row is an invariant break.
    public func rewriteTransaction(_ transaction: WalletTransaction) throws {
        _ = transaction
        throw EconomicLedgerError.appendOnly
    }

    public func deleteAllTransactions() throws {
        throw EconomicLedgerError.appendOnly
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
