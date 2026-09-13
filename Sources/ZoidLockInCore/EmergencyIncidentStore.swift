import Foundation

/// Durable, daemon-owned record of an emergency safety-valve activation.
///
/// User-space SQLite must never be the source of truth for whether an incident
/// exists. Slice 3's ledger consumes these records by UUID over authenticated XPC.
public struct EmergencyIncidentRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var kind: PassKind
    public var monotonicStartedAtSeconds: TimeInterval
    public var utcTimestamp: Date
    public var passDurationSeconds: TimeInterval
    public var signedDebtCredits: Double
    public var bootSessionUUID: String
    public var isLevied: Bool

    public init(
        id: UUID = UUID(),
        kind: PassKind = .emergency,
        monotonicStartedAtSeconds: TimeInterval,
        utcTimestamp: Date,
        passDurationSeconds: TimeInterval = DaemonLocalPass.emergencyDurationSeconds,
        signedDebtCredits: Double = PendingDebtRecord.emergencyPenaltyCredits,
        bootSessionUUID: String,
        isLevied: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.monotonicStartedAtSeconds = monotonicStartedAtSeconds
        self.utcTimestamp = utcTimestamp
        self.passDurationSeconds = passDurationSeconds
        self.signedDebtCredits = signedDebtCredits
        self.bootSessionUUID = bootSessionUUID
        self.isLevied = isLevied
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
            bootSessionUUID: bootSessionUUID,
            isLevied: false
        )
    }

    public var pendingDebt: PendingDebtRecord {
        PendingDebtRecord(
            signedCredits: PendingDebtRecord.emergencyPenaltyCredits,
            reason: .emergencyPenalty,
            levyOnNextReconciliation: !isLevied,
            createdAtSeconds: monotonicStartedAtSeconds,
            incidentID: id,
            utcTimestamp: utcTimestamp
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case monotonicStartedAtSeconds
        case utcTimestamp
        case passDurationSeconds
        case signedDebtCredits
        case bootSessionUUID
        case isLevied
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(PassKind.self, forKey: .kind) ?? .emergency
        monotonicStartedAtSeconds = try container.decode(TimeInterval.self, forKey: .monotonicStartedAtSeconds)
        utcTimestamp = try container.decode(Date.self, forKey: .utcTimestamp)
        passDurationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .passDurationSeconds)
            ?? DaemonLocalPass.emergencyDurationSeconds
        signedDebtCredits = try container.decodeIfPresent(Double.self, forKey: .signedDebtCredits)
            ?? PendingDebtRecord.emergencyPenaltyCredits
        bootSessionUUID = try container.decode(String.self, forKey: .bootSessionUUID)
        isLevied = try container.decodeIfPresent(Bool.self, forKey: .isLevied) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(monotonicStartedAtSeconds, forKey: .monotonicStartedAtSeconds)
        try container.encode(utcTimestamp, forKey: .utcTimestamp)
        try container.encode(passDurationSeconds, forKey: .passDurationSeconds)
        try container.encode(signedDebtCredits, forKey: .signedDebtCredits)
        try container.encode(bootSessionUUID, forKey: .bootSessionUUID)
        try container.encode(isLevied, forKey: .isLevied)
    }
}

public enum EmergencyIncidentStoreError: Error, Equatable, Sendable {
    case userSpaceCannotInventIncidents
}

public protocol EmergencyIncidentStoring: Sendable {
    func append(_ record: EmergencyIncidentRecord) throws
    func allIncidents() -> [EmergencyIncidentRecord]
    func unleviedIncidents() -> [EmergencyIncidentRecord]
    func markLevied(id: UUID) throws
}

public extension EmergencyIncidentStoring {
    func unleviedIncidents() -> [EmergencyIncidentRecord] {
        allIncidents().filter { !$0.isLevied && $0.kind == .emergency }
    }
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

    public func unleviedIncidents() -> [EmergencyIncidentRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.filter { !$0.isLevied && $0.kind == .emergency }
    }

    public func markLevied(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index].isLevied = true
        }
    }
}

/// User-space cache of daemon incidents received over authenticated XPC.
///
/// Never reads `/var/db/zoidlockin`. `append` is refused so the UI cannot
/// invent an emergency penalty. Levy marks are queued for the client to push
/// back to the daemon after the wallet nets −2.0.
public final class CachedEmergencyIncidentStore: EmergencyIncidentStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [EmergencyIncidentRecord] = []
    private var pendingLevyMarks: [UUID] = []

    public init() {}

    public func replaceUnlevied(_ incidents: [EmergencyIncidentRecord]) {
        lock.lock()
        records = incidents
        lock.unlock()
    }

    public func takePendingLevyMarks() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        let pending = pendingLevyMarks
        pendingLevyMarks = []
        return pending
    }

    public func append(_ record: EmergencyIncidentRecord) throws {
        _ = record
        throw EmergencyIncidentStoreError.userSpaceCannotInventIncidents
    }

    public func allIncidents() -> [EmergencyIncidentRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    public func unleviedIncidents() -> [EmergencyIncidentRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.filter { !$0.isLevied && $0.kind == .emergency }
    }

    public func markLevied(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index].isLevied = true
        }
        if !pendingLevyMarks.contains(id) {
            pendingLevyMarks.append(id)
        }
    }
}

/// Root-owned (production) or local-daemon-directory JSON log.
///
/// Default production path: `/var/db/zoidlockin/emergency_incidents.json`.
/// Writes are atomic (temp file + replace) and files are mode `0600`.
/// Unprivileged processes must not use this type against the default path;
/// they query incidents over authenticated XPC instead.
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

    /// Production path when `/var/db/zoidlockin` is writable; otherwise a
    /// user-space directory for tests and unsigned local runs.
    public static func resolvedDirectory(fileManager: FileManager = .default) -> URL {
        let privileged = defaultPrivilegedDirectory
        if canWrite(to: privileged, fileManager: fileManager) {
            return privileged
        }
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let fallback = root
            .appendingPathComponent(EconomicLedgerLocation.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("privileged", isDirectory: true)
        try? fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fallback.path)
        return fallback
    }

    public static func makeIsolatedDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("zoidlockin-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private static func canWrite(to directory: URL, fileManager: FileManager) -> Bool {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let probe = directory.appendingPathComponent(".zoidlockin-write-probe-\(UUID().uuidString)")
            try Data().write(to: probe)
            try fileManager.removeItem(at: probe)
            return true
        } catch {
            return false
        }
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

    public func unleviedIncidents() -> [EmergencyIncidentRecord] {
        allIncidents().filter { !$0.isLevied && $0.kind == .emergency }
    }

    public func markLevied(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        var records = (try? loadLocked()) ?? []
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            return
        }
        records[index].isLevied = true
        try persistLocked(records)
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
/// reconciles by UUID against `unleviedIncidents()`.
public final class IncidentProjectingPendingDebtStore: PendingDebtStoring, @unchecked Sendable {
    private let incidents: any EmergencyIncidentStoring

    public init(incidents: any EmergencyIncidentStoring) {
        self.incidents = incidents
    }

    public func record(_ record: PendingDebtRecord) {
        _ = record
    }

    public func recordsPendingReconciliation() -> [PendingDebtRecord] {
        incidents.unleviedIncidents().map(\.pendingDebt)
    }

    public func totalSignedCreditsPendingReconciliation() -> Double {
        recordsPendingReconciliation().reduce(0) { $0 + $1.signedCredits }
    }
}
