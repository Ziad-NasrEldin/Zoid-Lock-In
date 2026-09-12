import Foundation

/// Durable, daemon-owned record of an emergency safety-valve activation.
///
/// User-space SQLite must never be the source of truth for whether an incident
/// exists. Slice 3's ledger consumes these records by UUID.
public struct EmergencyIncidentRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var kind: PassKind
    public var monotonicStartedAtSeconds: TimeInterval
    public var utcTimestamp: Date
    public var passDurationSeconds: TimeInterval
    public var signedDebtCredits: Double
    public var bootSessionUUID: String

    public init(
        id: UUID = UUID(),
        kind: PassKind = .emergency,
        monotonicStartedAtSeconds: TimeInterval,
        utcTimestamp: Date,
        passDurationSeconds: TimeInterval = DaemonLocalPass.emergencyDurationSeconds,
        signedDebtCredits: Double = PendingDebtRecord.emergencyPenaltyCredits,
        bootSessionUUID: String
    ) {
        self.id = id
        self.kind = kind
        self.monotonicStartedAtSeconds = monotonicStartedAtSeconds
        self.utcTimestamp = utcTimestamp
        self.passDurationSeconds = passDurationSeconds
        self.signedDebtCredits = signedDebtCredits
        self.bootSessionUUID = bootSessionUUID
    }

    public static func emergency(
        id: UUID = UUID(),
        monotonicStartedAtSeconds: TimeInterval,
        utcTimestamp: Date,
        bootSessionUUID: String
    ) -> EmergencyIncidentRecord {
        EmergencyIncidentRecord(
            id: id,
            kind: .emergency,
            monotonicStartedAtSeconds: monotonicStartedAtSeconds,
            utcTimestamp: utcTimestamp,
            passDurationSeconds: DaemonLocalPass.emergencyDurationSeconds,
            signedDebtCredits: PendingDebtRecord.emergencyPenaltyCredits,
            bootSessionUUID: bootSessionUUID
        )
    }

    public var pendingDebt: PendingDebtRecord {
        PendingDebtRecord(
            signedCredits: signedDebtCredits,
            reason: .emergencyPenalty,
            levyOnNextReconciliation: true,
            createdAtSeconds: monotonicStartedAtSeconds,
            incidentID: id,
            utcTimestamp: utcTimestamp
        )
    }
}

public protocol EmergencyIncidentStoring: Sendable {
    func append(_ record: EmergencyIncidentRecord) throws
    func allIncidents() -> [EmergencyIncidentRecord]
}

/// In-memory incident log for tests that do not need a reboot survival story.
public final class InMemoryEmergencyIncidentStore: EmergencyIncidentStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [EmergencyIncidentRecord] = []

    public init() {}

    public func append(_ record: EmergencyIncidentRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        if records.contains(where: { $0.id == record.id }) {
            return
        }
        records.append(record)
    }

    public func allIncidents() -> [EmergencyIncidentRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}

/// Root-owned (production) or local-daemon-directory JSON log.
///
/// Default production path: `/var/db/zoidlockin/emergency_incidents.json`.
/// Writes are atomic (temp file + replace) and files are mode `0600`.
public final class FileEmergencyIncidentStore: EmergencyIncidentStoring, @unchecked Sendable {
    public static let defaultDirectoryPath = "/var/db/zoidlockin"
    public static let defaultFileName = "emergency_incidents.json"

    public let directoryURL: URL
    public let fileURL: URL
    private let lock = NSLock()
    private let fileManager: FileManager

    public init(
        directory: URL,
        fileName: String = FileEmergencyIncidentStore.defaultFileName,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directory
        self.fileURL = directory.appendingPathComponent(fileName)
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public static var defaultPrivilegedDirectory: URL {
        URL(fileURLWithPath: defaultDirectoryPath, isDirectory: true)
    }

    public static func makeIsolatedDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("zoidlockin-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func append(_ record: EmergencyIncidentRecord) throws {
        lock.lock()
        defer { lock.unlock() }

        var records = (try? loadLocked()) ?? []
        if records.contains(where: { $0.id == record.id }) {
            return
        }
        records.append(record)
        try persistLocked(records)
    }

    public func allIncidents() -> [EmergencyIncidentRecord] {
        lock.lock()
        defer { lock.unlock() }
        return (try? loadLocked()) ?? []
    }

    private struct LogFile: Codable {
        var version: Int
        var incidents: [EmergencyIncidentRecord]
    }

    private func loadLocked() throws -> [EmergencyIncidentRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let log = try decoder.decode(LogFile.self, from: data)
        return log.incidents
    }

    private func persistLocked(_ incidents: [EmergencyIncidentRecord]) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(LogFile(version: 1, incidents: incidents))
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

/// Pending-debt projection of the daemon incident log.
///
/// `record(_:)` is a no-op: the UI cannot invent an emergency penalty. Slice 3
/// reconciles by UUID against `allIncidents()`.
public final class IncidentProjectingPendingDebtStore: PendingDebtStoring, @unchecked Sendable {
    private let incidents: any EmergencyIncidentStoring

    public init(incidents: any EmergencyIncidentStoring) {
        self.incidents = incidents
    }

    public func record(_ record: PendingDebtRecord) {
        _ = record
    }

    public func recordsPendingReconciliation() -> [PendingDebtRecord] {
        incidents.allIncidents().map(\.pendingDebt)
    }

    public func totalSignedCreditsPendingReconciliation() -> Double {
        recordsPendingReconciliation().reduce(0) { $0 + $1.signedCredits }
    }
}
