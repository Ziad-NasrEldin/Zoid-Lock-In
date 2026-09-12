import Foundation

/// Reason a next-day ledger adjustment is queued. Slice 3's reconciliation
/// consumes these records; they are not an enforcement control.
public enum PendingDebtReason: String, Sendable, Equatable, Codable {
    case emergencyPenalty
}

/// Pending wallet adjustment levied at the next midnight reconciliation.
public struct PendingDebtRecord: Sendable, Equatable, Codable {
    public static let emergencyPenaltyCredits: Double = -2.0

    public var signedCredits: Double
    public var reason: PendingDebtReason
    public var levyOnNextReconciliation: Bool
    public var createdAtSeconds: TimeInterval

    public init(
        signedCredits: Double,
        reason: PendingDebtReason,
        levyOnNextReconciliation: Bool = true,
        createdAtSeconds: TimeInterval
    ) {
        self.signedCredits = signedCredits
        self.reason = reason
        self.levyOnNextReconciliation = levyOnNextReconciliation
        self.createdAtSeconds = createdAtSeconds
    }

    public static func emergencyPenalty(at time: TimeInterval) -> PendingDebtRecord {
        PendingDebtRecord(
            signedCredits: emergencyPenaltyCredits,
            reason: .emergencyPenalty,
            levyOnNextReconciliation: true,
            createdAtSeconds: time
        )
    }
}

public protocol PendingDebtStoring: Sendable {
    func record(_ record: PendingDebtRecord)
    func recordsPendingReconciliation() -> [PendingDebtRecord]
    func totalSignedCreditsPendingReconciliation() -> Double
}

/// In-memory pending-debt ledger. Slice 3 will persist this in SQLite.
public final class InMemoryPendingDebtStore: PendingDebtStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [PendingDebtRecord] = []

    public init() {}

    public func record(_ record: PendingDebtRecord) {
        lock.lock()
        records.append(record)
        lock.unlock()
    }

    public func recordsPendingReconciliation() -> [PendingDebtRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.filter(\.levyOnNextReconciliation)
    }

    public func totalSignedCreditsPendingReconciliation() -> Double {
        recordsPendingReconciliation().reduce(0) { $0 + $1.signedCredits }
    }
}
