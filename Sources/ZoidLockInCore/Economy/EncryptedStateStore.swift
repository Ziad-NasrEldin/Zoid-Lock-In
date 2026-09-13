import CryptoKit
import Foundation

public enum EncryptedStateStoreError: Error, Equatable, Sendable {
    case sealFailed
    case malformedEnvelope
    case unsupportedAlgorithm(String)
    case unsupportedVersion(Int)
    case integrityFailed
    case writeFailed
}

extension EncryptedStateStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sealFailed:
            return "AES-GCM seal failed"
        case .malformedEnvelope:
            return "Encrypted state envelope is malformed"
        case .unsupportedAlgorithm(let algorithm):
            return "Unsupported state encryption algorithm: \(algorithm)"
        case .unsupportedVersion(let version):
            return "Unsupported encrypted state version: \(version)"
        case .integrityFailed:
            return "Encrypted state failed AES-GCM integrity verification"
        case .writeFailed:
            return "Failed to write encrypted state.json"
        }
    }
}

/// AES-GCM envelope stored as `state.json` (ciphertext, never plaintext).
public struct EncryptedStateEnvelope: Sendable, Equatable, Codable {
    public static let currentVersion = 1
    public static let algorithmAESGCM = "AES-GCM"

    public var version: Int
    public var algorithm: String
    public var combined: String

    public init(
        version: Int = EncryptedStateEnvelope.currentVersion,
        algorithm: String = EncryptedStateEnvelope.algorithmAESGCM,
        combined: String
    ) {
        self.version = version
        self.algorithm = algorithm
        self.combined = combined
    }
}

public enum MobileShieldSecrets: Sendable {
    public static let context = "com.mavoid.zoidlockin.mobile-shield.v1"

    public static func derivedKey(
        teamID: String = ZoidLockInIdentity.resolvedTeamIdentifier()
    ) -> SymmetricKey {
        let material = Data("\(context)|\(teamID)".utf8)
        return SymmetricKey(data: Data(SHA256.hash(data: material)))
    }
}

public protocol UbiquityContainerResolving: Sendable {
    func url(forUbiquityContainerIdentifier identifier: String?) -> URL?
}

public struct FileManagerUbiquityResolver: UbiquityContainerResolving {
    public init() {}

    public func url(forUbiquityContainerIdentifier identifier: String?) -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: identifier)
    }
}

/// AES-GCM `state.json` store. Prefers the ubiquitous iCloud container and
/// falls back to a local directory for offline / headless environments.
public final class EncryptedStateStore: @unchecked Sendable {
    public static let fileName = "state.json"

    public let directoryURL: URL
    public let fileURL: URL
    public let usesUbiquitousContainer: Bool
    public let key: SymmetricKey

    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        fallbackDirectory: URL,
        ubiquityIdentifier: String? = ZoidLockInIdentity.ubiquityContainerIdentifier,
        ubiquity: any UbiquityContainerResolving = FileManagerUbiquityResolver(),
        fileManager: FileManager = .default,
        key: SymmetricKey = MobileShieldSecrets.derivedKey()
    ) {
        self.fileManager = fileManager
        self.key = key
        if let ubiquityIdentifier,
           let container = ubiquity.url(forUbiquityContainerIdentifier: ubiquityIdentifier) {
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            self.directoryURL = documents
            self.usesUbiquitousContainer = true
        } else {
            self.directoryURL = fallbackDirectory
            self.usesUbiquitousContainer = false
        }
        self.fileURL = directoryURL.appendingPathComponent(Self.fileName)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    public static func makeIsolatedDirectory(fileManager: FileManager = .default) -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("zoidlockin-mobile-shield-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func encrypt(_ state: MobileShieldState) throws -> Data {
        try Self.encrypt(state, key: key)
    }

    public func decrypt(_ data: Data) throws -> MobileShieldState {
        try Self.decrypt(data, key: key)
    }

    public static func encrypt(_ state: MobileShieldState, key: SymmetricKey) throws -> Data {
        let plaintext = try MobileShieldCoding.makeEncoder().encode(state)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plaintext, using: key)
        } catch {
            throw EncryptedStateStoreError.sealFailed
        }
        guard let combined = sealed.combined else {
            throw EncryptedStateStoreError.sealFailed
        }
        let envelope = EncryptedStateEnvelope(combined: combined.base64EncodedString())
        return try MobileShieldCoding.makeEncoder().encode(envelope)
    }

    public static func decrypt(_ data: Data, key: SymmetricKey) throws -> MobileShieldState {
        let envelope: EncryptedStateEnvelope
        do {
            envelope = try MobileShieldCoding.makeDecoder().decode(EncryptedStateEnvelope.self, from: data)
        } catch {
            throw EncryptedStateStoreError.malformedEnvelope
        }
        guard envelope.version == EncryptedStateEnvelope.currentVersion else {
            throw EncryptedStateStoreError.unsupportedVersion(envelope.version)
        }
        guard envelope.algorithm == EncryptedStateEnvelope.algorithmAESGCM else {
            throw EncryptedStateStoreError.unsupportedAlgorithm(envelope.algorithm)
        }
        guard let combined = Data(base64Encoded: envelope.combined), !combined.isEmpty else {
            throw EncryptedStateStoreError.malformedEnvelope
        }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(box, using: key)
            return try MobileShieldCoding.makeDecoder().decode(MobileShieldState.self, from: plaintext)
        } catch let error as EncryptedStateStoreError {
            throw error
        } catch {
            throw EncryptedStateStoreError.integrityFailed
        }
    }

    public func load() throws -> MobileShieldState? {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    /// Last-Write-Wins persist. A stale incoming snapshot does not clobber a newer file.
    @discardableResult
    public func persist(_ incoming: MobileShieldState) throws -> MobileShieldState {
        lock.lock()
        defer { lock.unlock() }
        let existing = try loadLocked()
        let winner = MobileShieldState.resolve(local: incoming, remote: existing) ?? incoming
        if winner != existing {
            try writeLocked(winner)
        }
        return winner
    }

    public func loadCandidatesAndResolve(_ extras: [MobileShieldState] = []) throws -> MobileShieldState? {
        lock.lock()
        defer { lock.unlock() }
        var candidates = extras
        if let loaded = try loadLocked() {
            candidates.append(loaded)
        }
        return MobileShieldState.resolve(candidates: candidates)
    }

    private func loadLocked() throws -> MobileShieldState? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data: Data
        do {
            data = try readCoordinated()
        } catch {
            throw EncryptedStateStoreError.malformedEnvelope
        }
        if data.isEmpty {
            return nil
        }
        return try Self.decrypt(data, key: key)
    }

    private func writeLocked(_ state: MobileShieldState) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try Self.encrypt(state, key: key)
        do {
            try writeCoordinated(data)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw EncryptedStateStoreError.writeFailed
        }
    }

    private func readCoordinated() throws -> Data {
        var coordError: NSError?
        var loaded: Data?
        var readError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordError) { url in
            do {
                loaded = try Data(contentsOf: url)
            } catch {
                readError = error
            }
        }
        if let coordError {
            throw coordError
        }
        if let readError {
            throw readError
        }
        return loaded ?? Data()
    }

    private func writeCoordinated(_ data: Data) throws {
        var coordError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: fileURL,
            options: .forReplacing,
            error: &coordError
        ) { url in
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordError {
            throw coordError
        }
        if let writeError {
            throw writeError
        }
    }
}
