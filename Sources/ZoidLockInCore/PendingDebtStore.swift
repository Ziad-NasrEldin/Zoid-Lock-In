import Foundation

/// Reason a next-day ledger adjustment is queued. Slice 3's reconciliation
/// consumes these records; they are not an enforcement control.
public enum PendingDebtReason: String, Sendable, Equatable, Codable {
    case emergencyPenalty
}

/// Pending wallet adjustment levied at the next midnight reconciliation.
///
/// Production records are a **projection** of daemon-owned
/// `EmergencyIncidentRecord` values. The UI must not invent incidents.
public struct PendingDebtRecord: Sendable, Equatable, Codable {
    public static let emergencyPenaltyCredits: Double = -2.0

    public var signedCredits: Double
    public var reason: PendingDebtReason
    public var levyOnNextReconciliation: Bool
    public var createdAtSeconds: TimeInterval
    public var incidentID: UUID?
    public var utcTimestamp: Date?

    public init(
        signedCredits: Double,
        reason: PendingDebtReason,
        levyOnNextReconciliation: Bool = true,
        createdAtSeconds: TimeInterval,
        incidentID: UUID? = nil,
        utcTimestamp: Date? = nil
    ) {
        self.signedCredits = signedCredits
        self.reason = reason
        self.levyOnNextReconciliation = levyOnNextReconciliation
        self.createdAtSeconds = createdAtSeconds
        self.incidentID = incidentID
        self.utcTimestamp = utcTimestamp
    }

    public static func emergencyPenalty(
        at time: TimeInterval,
        incidentID: UUID? = nil,
        utcTimestamp: Date? = nil
    ) -> PendingDebtRecord {
        PendingDebtRecord(
            signedCredits: emergencyPenaltyCredits,
            reason: .emergencyPenalty,
            levyOnNextReconciliation: true,
            createdAtSeconds: time,
            incidentID: incidentID,
            utcTimestamp: utcTimestamp
        )
    }
}

public protocol PendingDebtStoring: Sendable {
    func record(_ record: PendingDebtRecord)
    func recordsPendingReconciliation() -> [PendingDebtRecord]
    func totalSignedCreditsPendingReconciliation() -> Double
}

/// In-memory pending-debt ledger. Prefer `IncidentProjectingPendingDebtStore`
/// whenever a daemon incident log is available.
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
