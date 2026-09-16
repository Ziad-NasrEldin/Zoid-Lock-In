import CryptoKit
import Foundation

public enum EncryptedStateStoreError: Error, Equatable, Sendable {
    case sealFailed
    case malformedEnvelope
    case unsupportedAlgorithm(String)
    case unsupportedVersion(Int)
    case integrityFailed
    case writeFailed
    case clockRejected
    case staleSequence
    case unauthenticatedKey
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
        case .clockRejected:
            return "Encrypted state write rejected by the time-travel guard"
        case .staleSequence:
            return "Encrypted state sequence is not strictly newer than the high-water mark"
        case .unauthenticatedKey:
            return "Mobile shield key is missing, truncated, or is the public Team ID KDF"
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

public protocol MobileShieldKeyProviding: Sendable {
    func loadOrCreate() throws -> SymmetricKey
}

public protocol SequenceHighWaterMarking: Sendable {
    func load() -> UInt64
    func persist(_ value: UInt64)
}

/// Forbidden public KDF retained only so tests can prove production keys are
/// not `SHA256(context || TeamID)`.
public enum MobileShieldSecrets: Sendable {
    public static let context = "com.mavoid.zoidlockin.mobile-shield.v1"
    public static let keyByteCount = 32

    public static func publicTeamIdentifierDerivedKey(
        teamID: String = ZoidLockInIdentity.resolvedTeamIdentifier()
    ) -> SymmetricKey {
        let material = Data("\(context)|\(teamID)".utf8)
        return SymmetricKey(data: Data(SHA256.hash(data: material)))
    }

    @available(*, deprecated, message: "Team ID KDF is not a secret. Use KeychainMobileShieldKeyProvider.")
    public static func derivedKey(
        teamID: String = ZoidLockInIdentity.resolvedTeamIdentifier()
    ) -> SymmetricKey {
        publicTeamIdentifierDerivedKey(teamID: teamID)
    }

    public static func isPublicTeamIdentifierKDF(
        _ key: SymmetricKey,
        teamID: String = ZoidLockInIdentity.resolvedTeamIdentifier()
    ) -> Bool {
        constantTimeEquals(key, publicTeamIdentifierDerivedKey(teamID: teamID))
    }

    public static func randomKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    public static func rawBytes(of key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    public static func validatedKey(from data: Data) throws -> SymmetricKey {
        guard data.count == keyByteCount else {
            throw EncryptedStateStoreError.unauthenticatedKey
        }
        let key = SymmetricKey(data: data)
        if isPublicTeamIdentifierKDF(key) || isPublicTeamIdentifierKDF(key, teamID: ZoidLockInIdentity.teamIdentifierPlaceholder) {
            throw EncryptedStateStoreError.unauthenticatedKey
        }
        return key
    }

    public static func constantTimeEquals(_ lhs: SymmetricKey, _ rhs: SymmetricKey) -> Bool {
        let left = rawBytes(of: lhs)
        let right = rawBytes(of: rhs)
        guard left.count == right.count else {
            return false
        }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

/// Random 256-bit key that lives only in process memory. Default for tests.
public struct InMemoryMobileShieldKeyProvider: MobileShieldKeyProviding, Sendable {
    public let key: SymmetricKey

    public init(key: SymmetricKey = MobileShieldSecrets.randomKey()) {
        self.key = key
    }

    public func loadOrCreate() throws -> SymmetricKey {
        if MobileShieldSecrets.isPublicTeamIdentifierKDF(key) || MobileShieldSecrets.isPublicTeamIdentifierKDF(key, teamID: ZoidLockInIdentity.teamIdentifierPlaceholder) {
            throw EncryptedStateStoreError.unauthenticatedKey
        }
        let bytes = MobileShieldSecrets.rawBytes(of: key)
        guard bytes.count == MobileShieldSecrets.keyByteCount else {
            throw EncryptedStateStoreError.unauthenticatedKey
        }
        return key
    }
}

/// Persists a random `SymmetricKey(size: .bits256)` under
/// `com.mavoid.zoidlockin.mobile-shield.key`. Never falls back to Team ID.
public struct KeychainMobileShieldKeyProvider: MobileShieldKeyProviding, Sendable {
    public var store: any KeychainDataStoring
    public var service: String
    public var account: String

    public init(
        store: any KeychainDataStoring = FileSecureDataStore.shared,
        service: String = ZoidLockInKeychain.mobileShieldService,
        account: String = ZoidLockInKeychain.mobileShieldKeyAccount
    ) {
        self.store = store
        self.service = service
        self.account = account
    }

    public func loadOrCreate() throws -> SymmetricKey {
        if let existing = store.data(service: service, account: account) {
            if let key = try? MobileShieldSecrets.validatedKey(from: existing) {
                return key
            }
        }
        let key = MobileShieldSecrets.randomKey()
        try store.setData(MobileShieldSecrets.rawBytes(of: key), service: service, account: account)
        return key
    }
}

public final class InMemorySequenceHighWater: SequenceHighWaterMarking, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    public init(_ value: UInt64 = 0) {
        self.value = value
    }

    public func load() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func persist(_ value: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if value > self.value {
            self.value = value
        }
    }
}

public struct KeychainSequenceHighWater: SequenceHighWaterMarking, Sendable {
    public var store: any KeychainDataStoring
    public var service: String
    public var account: String

    public init(
        store: any KeychainDataStoring = FileSecureDataStore.shared,
        service: String = ZoidLockInKeychain.mobileShieldService,
        account: String = ZoidLockInKeychain.mobileShieldHighWaterAccount
    ) {
        self.store = store
        self.service = service
        self.account = account
    }

    public func load() -> UInt64 {
        guard let data = store.data(service: service, account: account), data.count == 8 else {
            return 0
        }
        return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    public func persist(_ value: UInt64) {
        var bigEndian = value.bigEndian
        let data = withUnsafeBytes(of: &bigEndian) { Data($0) }
        try? store.setData(data, service: service, account: account)
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

/// AES-GCM `state.json` store. Writes into an isolated Application Support
/// folder (or the ubiquity container's hidden Library path — never `Documents`).
public final class EncryptedStateStore: @unchecked Sendable {
    public static let fileName = "state.json"
    public static let isolatedFolderName = "mobile-shield"
    public static let isolatedRelativePath = "Library/Application Support/ZoidLockIn/mobile-shield"

    public let directoryURL: URL
    public let fileURL: URL
    public let usesUbiquitousContainer: Bool
    public let key: SymmetricKey
    public let timeTravel: TimeTravelGuard

    private let fileManager: FileManager
    private let highWaterMark: any SequenceHighWaterMarking
    private let lock = NSLock()

    public init(
        fallbackDirectory: URL,
        ubiquityIdentifier: String? = ZoidLockInIdentity.ubiquityContainerIdentifier,
        ubiquity: any UbiquityContainerResolving = FileManagerUbiquityResolver(),
        fileManager: FileManager = .default,
        key: SymmetricKey? = nil,
        keyProvider: any MobileShieldKeyProviding = InMemoryMobileShieldKeyProvider(),
        timeTravel: TimeTravelGuard = TimeTravelGuard(),
        highWater: any SequenceHighWaterMarking = InMemorySequenceHighWater()
    ) {
        self.fileManager = fileManager
        self.timeTravel = timeTravel
        self.highWaterMark = highWater
        if let provided = key {
            self.key = provided
        } else if let loaded = try? keyProvider.loadOrCreate() {
            self.key = loaded
        } else {
            self.key = MobileShieldSecrets.randomKey()
        }
        if let ubiquityIdentifier,
           let container = ubiquity.url(forUbiquityContainerIdentifier: ubiquityIdentifier) {
            self.directoryURL = Self.isolatedDirectory(inside: container)
            self.usesUbiquitousContainer = true
        } else {
            self.directoryURL = Self.isolatedDirectory(inside: fallbackDirectory)
            self.usesUbiquitousContainer = false
        }
        self.fileURL = directoryURL.appendingPathComponent(Self.fileName)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    public static func defaultApplicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root
            .appendingPathComponent(EconomicLedgerLocation.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(isolatedFolderName, isDirectory: true)
    }

    public static func makeIsolatedDirectory(fileManager: FileManager = .default) -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("zoidlockin-mobile-shield-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(isolatedFolderName, isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func isolatedDirectory(inside root: URL) -> URL {
        if root.lastPathComponent == isolatedFolderName {
            return root
        }
        if root.path.contains("/\(isolatedRelativePath)") || root.path.hasSuffix("/\(isolatedRelativePath)") {
            return root
        }
        if root.path.contains("/Library/Application Support/ZoidLockIn/\(isolatedFolderName)") {
            return root
        }
        return root.appendingPathComponent(isolatedRelativePath, isDirectory: true)
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

    /// Sequence-authoritative persist. A lower sequence never clobbers a newer
    /// replica, including after the file is deleted (Keychain / in-memory high-water).
    @discardableResult
    public func persist(_ incoming: MobileShieldState, now: Date = Date()) throws -> MobileShieldState {
        lock.lock()
        defer { lock.unlock() }
        do {
            try timeTravel.ensureWritable()
        } catch {
            throw EncryptedStateStoreError.clockRejected
        }
        let skew = incoming.timestamp.timeIntervalSince(now)
        if skew > TimeTravelGuard.maxSkewSeconds {
            throw EncryptedStateStoreError.clockRejected
        }
        let existing = try loadLocked()
        if let existing, !incoming.wins(over: existing) {
            return existing
        }
        let highWater = highWaterMark.load()
        if incoming.sequenceNumber < highWater {
            throw EncryptedStateStoreError.staleSequence
        }
        if incoming.sequenceNumber == highWater, existing == nil {
            throw EncryptedStateStoreError.staleSequence
        }
        try writeLocked(incoming)
        highWaterMark.persist(incoming.sequenceNumber)
        return incoming
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
