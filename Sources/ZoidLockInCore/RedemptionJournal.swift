import Foundation

/// Privileged record of a redeemed amenity voucher.
///
/// Survives helper `KeepAlive` restarts so a captured ticket cannot grant a
/// second pass. Pass restoration uses `bootUUID` + remaining monotonic time;
/// a reboot (new boot UUID) fails closed.
public struct RedemptionJournalEntry: Sendable, Equatable, Codable {
    public var nonce: String
    public var transactionID: UUID
    public var kind: PassKind
    public var monotonicStart: TimeInterval
    public var durationSeconds: TimeInterval
    public var bootUUID: String
    public var issuedAt: Date

    public init(
        nonce: String,
        transactionID: UUID,
        kind: PassKind,
        monotonicStart: TimeInterval,
        durationSeconds: TimeInterval,
        bootUUID: String,
        issuedAt: Date
    ) {
        self.nonce = nonce
        self.transactionID = transactionID
        self.kind = kind
        self.monotonicStart = monotonicStart
        self.durationSeconds = durationSeconds
        self.bootUUID = bootUUID
        self.issuedAt = issuedAt
    }

    public func remainingSeconds(at time: TimeInterval) -> TimeInterval {
        max(0, monotonicStart + durationSeconds - time)
    }

    public func isRestorable(bootUUID: String, at time: TimeInterval) -> Bool {
        self.bootUUID == bootUUID && remainingSeconds(at: time) > 0
    }
}

public protocol RedemptionJournaling: Sendable {
    func record(_ entry: RedemptionJournalEntry) throws
    func allEntries() -> [RedemptionJournalEntry]
    func contains(nonce: String) -> Bool
    func contains(transactionID: UUID) -> Bool
}

/// In-memory journal for tests that do not need helper-restart durability.
public final class InMemoryRedemptionJournal: RedemptionJournaling, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [RedemptionJournalEntry] = []

    public init() {}

    public func record(_ entry: RedemptionJournalEntry) throws {
        lock.lock()
        defer { lock.unlock() }
        if entries.contains(where: { $0.nonce == entry.nonce || $0.transactionID == entry.transactionID }) {
            return
        }
        entries.append(entry)
        pruneLocked(now: entry.issuedAt)
    }

    public func allEntries() -> [RedemptionJournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func contains(nonce: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.contains { $0.nonce == nonce }
    }

    public func contains(transactionID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.contains { $0.transactionID == transactionID }
    }

    private func pruneLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-AmenityVoucherPolicy.replayRetentionSeconds)
        entries.removeAll { $0.issuedAt < cutoff }
    }
}

/// Root-owned (production) or isolated-directory JSON journal.
///
/// Default production path: `/var/db/zoidlockin/redemption_journal.json`.
/// Writes are atomic (temp file + replace) and files are mode `0600`.
public final class FileRedemptionJournal: RedemptionJournaling, @unchecked Sendable {
    public static let defaultFileName = "redemption_journal.json"

    public let directoryURL: URL
    public let fileURL: URL
    private let lock = NSLock()
    private let fileManager: FileManager

    public init(
        directory: URL,
        fileName: String = FileRedemptionJournal.defaultFileName,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directory
        self.fileURL = directory.appendingPathComponent(fileName)
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public func record(_ entry: RedemptionJournalEntry) throws {
        lock.lock()
        defer { lock.unlock() }

        var entries = (try? loadLocked()) ?? []
        if entries.contains(where: { $0.nonce == entry.nonce || $0.transactionID == entry.transactionID }) {
            return
        }
        entries.append(entry)
        try persistLocked(Self.pruned(entries, now: entry.issuedAt))
    }

    public func allEntries() -> [RedemptionJournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        return (try? loadLocked()) ?? []
    }

    public func contains(nonce: String) -> Bool {
        allEntries().contains { $0.nonce == nonce }
    }

    public func contains(transactionID: UUID) -> Bool {
        allEntries().contains { $0.transactionID == transactionID }
    }

    private struct LogFile: Codable {
        var version: Int
        var entries: [RedemptionJournalEntry]
    }

    private func loadLocked() throws -> [RedemptionJournalEntry] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let log = try decoder.decode(LogFile.self, from: data)
        return log.entries
    }

    private func persistLocked(_ entries: [RedemptionJournalEntry]) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(LogFile(version: 1, entries: entries))
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func pruned(_ entries: [RedemptionJournalEntry], now: Date) -> [RedemptionJournalEntry] {
        let cutoff = now.addingTimeInterval(-AmenityVoucherPolicy.replayRetentionSeconds)
        return entries.filter { $0.issuedAt >= cutoff }
    }
}
