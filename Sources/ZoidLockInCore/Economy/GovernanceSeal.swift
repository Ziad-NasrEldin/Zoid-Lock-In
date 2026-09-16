import CryptoKit
import Foundation

/// HMAC-SHA256 seal over 48-hour governance lock material. SQLite is a cache;
/// a missing or mismatched signature fail-closes into a full cooldown.
public enum GovernanceSealLocation: Sendable {
    public static let privilegedDirectoryPath = "/var/db/zoidlockin"
    public static let fileName = "governance_state.json"
    public static let keychainAccount = "com.mavoid.zoidlockin.governance.key"

    public static var privilegedDirectoryURL: URL {
        URL(fileURLWithPath: privilegedDirectoryPath, isDirectory: true)
    }

    public static var privilegedFileURL: URL {
        privilegedDirectoryURL.appendingPathComponent(fileName)
    }
}

public enum GovernanceSecrets: Sendable {
    public static let context = "com.mavoid.zoidlockin.governance.v1"
    public static let keyByteCount = 32

    public static func publicTeamIdentifierDerivedKey(
        teamID: String = ZoidLockInIdentity.resolvedTeamIdentifier()
    ) -> SymmetricKey {
        let material = Data("\(context)|\(teamID)".utf8)
        return SymmetricKey(data: Data(SHA256.hash(data: material)))
    }

    public static func isPublicTeamIdentifierKDF(
        _ key: SymmetricKey,
        teamID: String = ZoidLockInIdentity.resolvedTeamIdentifier()
    ) -> Bool {
        MobileShieldSecrets.constantTimeEquals(key, publicTeamIdentifierDerivedKey(teamID: teamID))
    }

    public static func randomKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    public static func rawBytes(of key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    public static func validatedKey(from data: Data) throws -> SymmetricKey {
        guard data.count == keyByteCount else {
            throw GovernanceLockError.integrityFailed
        }
        let key = SymmetricKey(data: data)
        if isPublicTeamIdentifierKDF(key) || isPublicTeamIdentifierKDF(key, teamID: ZoidLockInIdentity.teamIdentifierPlaceholder) {
            throw GovernanceLockError.integrityFailed
        }
        return key
    }
}

public protocol GovernanceKeyProviding: Sendable {
    func loadOrCreate() throws -> SymmetricKey
}

/// Random in-process key. Default for tests; production injects the Keychain provider.
public struct InMemoryGovernanceKeyProvider: GovernanceKeyProviding, Sendable {
    public let key: SymmetricKey

    public init(key: SymmetricKey = GovernanceSecrets.randomKey()) {
        self.key = key
    }

    public func loadOrCreate() throws -> SymmetricKey {
        try GovernanceSecrets.validatedKey(from: GovernanceSecrets.rawBytes(of: key))
    }
}

/// Persists a random 256-bit key under `com.mavoid.zoidlockin.governance.key`.
public struct KeychainGovernanceKeyProvider: GovernanceKeyProviding, Sendable {
    public var store: any KeychainDataStoring
    public var service: String
    public var account: String

    public init(
        store: any KeychainDataStoring = FileSecureDataStore.shared,
        service: String = ZoidLockInKeychain.governanceService,
        account: String = ZoidLockInKeychain.governanceKeyAccount
    ) {
        self.store = store
        self.service = service
        self.account = account
    }

    public func loadOrCreate() throws -> SymmetricKey {
        if let existing = store.data(service: service, account: account),
           let key = try? GovernanceSecrets.validatedKey(from: existing) {
            return key
        }
        let key = GovernanceSecrets.randomKey()
        try store.setData(GovernanceSecrets.rawBytes(of: key), service: service, account: account)
        return key
    }
}

/// Canonical lock material covered by HMAC-SHA256.
public struct GovernanceSealPayload: Sendable, Equatable, Codable {
    public var version: Int
    public var lastConfigurationMutationAt: Date?
    public var lastConfigurationMutationMonotonic: TimeInterval?
    public var mutationBootSessionUUID: String?
    public var lastObservedWall: Date?
    public var lastObservedMonotonic: TimeInterval?
    public var lastObservedBootSessionUUID: String?
    public var accruedMonotonicElapsed: TimeInterval
    public var pinnedTimeZoneIdentifier: String?
    public var sequence: UInt64

    public init(
        version: Int = 1,
        lastConfigurationMutationAt: Date? = nil,
        lastConfigurationMutationMonotonic: TimeInterval? = nil,
        mutationBootSessionUUID: String? = nil,
        lastObservedWall: Date? = nil,
        lastObservedMonotonic: TimeInterval? = nil,
        lastObservedBootSessionUUID: String? = nil,
        accruedMonotonicElapsed: TimeInterval = 0,
        pinnedTimeZoneIdentifier: String? = nil,
        sequence: UInt64 = 0
    ) {
        self.version = version
        self.lastConfigurationMutationAt = lastConfigurationMutationAt
        self.lastConfigurationMutationMonotonic = lastConfigurationMutationMonotonic
        self.mutationBootSessionUUID = mutationBootSessionUUID
        self.lastObservedWall = lastObservedWall
        self.lastObservedMonotonic = lastObservedMonotonic
        self.lastObservedBootSessionUUID = lastObservedBootSessionUUID
        self.accruedMonotonicElapsed = max(0, accruedMonotonicElapsed)
        self.pinnedTimeZoneIdentifier = pinnedTimeZoneIdentifier
        self.sequence = sequence
    }

    public init(_ state: GovernanceState) {
        self.init(
            lastConfigurationMutationAt: state.lastConfigurationMutationAt,
            lastConfigurationMutationMonotonic: state.lastConfigurationMutationMonotonic,
            mutationBootSessionUUID: state.mutationBootSessionUUID,
            lastObservedWall: state.lastObservedWall,
            lastObservedMonotonic: state.lastObservedMonotonic,
            lastObservedBootSessionUUID: state.lastObservedBootSessionUUID,
            accruedMonotonicElapsed: state.accruedMonotonicElapsed,
            pinnedTimeZoneIdentifier: state.pinnedTimeZoneIdentifier,
            sequence: state.sequence
        )
    }

    public var hasMutation: Bool {
        lastConfigurationMutationAt != nil
    }
}

public struct GovernanceSealEnvelope: Sendable, Equatable, Codable {
    public var payload: GovernanceSealPayload
    public var hmac: String

    public init(payload: GovernanceSealPayload, hmac: String) {
        self.payload = payload
        self.hmac = hmac
    }
}

public enum GovernanceSeal: Sendable {
    public static func canonicalBytes(_ payload: GovernanceSealPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(payload)
    }

    public static func seal(_ payload: GovernanceSealPayload, key: SymmetricKey) throws -> GovernanceSealEnvelope {
        let bytes = try canonicalBytes(payload)
        let code = Data(HMAC<SHA256>.authenticationCode(for: bytes, using: key))
        return GovernanceSealEnvelope(payload: payload, hmac: code.base64EncodedString())
    }

    public static func verify(_ envelope: GovernanceSealEnvelope, key: SymmetricKey) -> Bool {
        guard let given = Data(base64Encoded: envelope.hmac), !given.isEmpty else {
            return false
        }
        guard let bytes = try? canonicalBytes(envelope.payload) else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: bytes, using: key)
    }

    public static func encode(_ envelope: GovernanceSealEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(envelope)
    }

    public static func decode(_ data: Data) throws -> GovernanceSealEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(GovernanceSealEnvelope.self, from: data)
    }
}

public protocol GovernanceSealPersisting: Sendable {
    func loadEnvelope() throws -> GovernanceSealEnvelope?
    func saveEnvelope(_ envelope: GovernanceSealEnvelope) throws
}

public final class InMemoryGovernanceSealStore: GovernanceSealPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var envelope: GovernanceSealEnvelope?

    public init() {}

    public func loadEnvelope() throws -> GovernanceSealEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return envelope
    }

    public func saveEnvelope(_ envelope: GovernanceSealEnvelope) throws {
        lock.lock()
        defer { lock.unlock() }
        self.envelope = envelope
    }
}

/// Privileged `/var/db/zoidlockin/governance_state.json` plus a user-space fallback
/// and a Keychain replica. Writes to `/var` fail open to the fallback; verification
/// fail-closes if any authentic replica disagrees with SQLite.
public final class FileGovernanceSealStore: GovernanceSealPersisting, @unchecked Sendable {
    public let privilegedFileURL: URL
    public let fallbackFileURL: URL
    public let keychainStore: any KeychainDataStoring
    public let keychainService: String
    public let keychainSealAccount: String

    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        privilegedFileURL: URL = GovernanceSealLocation.privilegedFileURL,
        fallbackDirectory: URL,
        keychainStore: any KeychainDataStoring = FileSecureDataStore.shared,
        keychainService: String = ZoidLockInKeychain.governanceService,
        keychainSealAccount: String = ZoidLockInKeychain.governanceSealAccount,
        fileManager: FileManager = .default
    ) {
        self.privilegedFileURL = privilegedFileURL
        self.fallbackFileURL = fallbackDirectory.appendingPathComponent(GovernanceSealLocation.fileName)
        self.keychainStore = keychainStore
        self.keychainService = keychainService
        self.keychainSealAccount = keychainSealAccount
        self.fileManager = fileManager
        try? fileManager.createDirectory(
            at: fallbackDirectory,
            withIntermediateDirectories: true
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fallbackDirectory.path
        )
    }

    public func loadEnvelope() throws -> GovernanceSealEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        let candidates = [
            try? Data(contentsOf: privilegedFileURL),
            try? Data(contentsOf: fallbackFileURL),
            keychainStore.data(service: keychainService, account: keychainSealAccount),
        ]
        var decoded: [GovernanceSealEnvelope] = []
        for data in candidates {
            guard let data, !data.isEmpty, let envelope = try? GovernanceSeal.decode(data) else {
                continue
            }
            decoded.append(envelope)
        }
        return Self.mostRestrictive(decoded)
    }

    public func saveEnvelope(_ envelope: GovernanceSealEnvelope) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try GovernanceSeal.encode(envelope)
        _ = Self.tryWrite(data, to: privilegedFileURL, fileManager: fileManager, posix: 0o600)
        try fileManager.createDirectory(
            at: fallbackFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fallbackFileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fallbackFileURL.path
        )
        try keychainStore.setData(data, service: keychainService, account: keychainSealAccount)
    }

    public static func mostRestrictive(_ envelopes: [GovernanceSealEnvelope]) -> GovernanceSealEnvelope? {
        guard !envelopes.isEmpty else { return nil }
        let mutated = envelopes.filter(\.payload.hasMutation)
        let pool = mutated.isEmpty ? envelopes : mutated
        return pool.min { lhs, rhs in
            if lhs.payload.accruedMonotonicElapsed != rhs.payload.accruedMonotonicElapsed {
                return lhs.payload.accruedMonotonicElapsed < rhs.payload.accruedMonotonicElapsed
            }
            return lhs.payload.sequence > rhs.payload.sequence
        }
    }

    private static func tryWrite(
        _ data: Data,
        to url: URL,
        fileManager: FileManager,
        posix: Int
    ) -> Bool {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: posix], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}

enum GovernanceIntegrity {
    static func verify(
        sqlite: GovernanceState,
        envelope: GovernanceSealEnvelope?,
        replica: GovernanceSealEnvelope?,
        key: SymmetricKey
    ) throws -> GovernanceState {
        if let envelope, !GovernanceSeal.verify(envelope, key: key) {
            throw GovernanceLockError.integrityFailed
        }
        if let replica, !GovernanceSeal.verify(replica, key: key) {
            throw GovernanceLockError.integrityFailed
        }

        let sealed = FileGovernanceSealStore.mostRestrictive(
            [envelope, replica].compactMap { $0 }
        )

        let sqliteLooksLocked = sqlite.hasMutation || sqlite.accruedMonotonicElapsed > 0.000_1
        if sealed == nil, sqliteLooksLocked || sqlite.sequence > 0 {
            throw GovernanceLockError.integrityFailed
        }
        if sqliteLooksLocked {
            guard let sealed else {
                throw GovernanceLockError.integrityFailed
            }
            guard sqlite.lockMaterialMatches(sealed.payload) else {
                throw GovernanceLockError.integrityFailed
            }
        }

        if let sealed, sealed.payload.hasMutation {
            guard sqlite.lockMaterialMatches(sealed.payload) else {
                throw GovernanceLockError.integrityFailed
            }
        }

        return sqlite
    }
}

extension GovernanceState {
    func lockMaterialMatches(_ payload: GovernanceSealPayload) -> Bool {
        datesEqual(lastConfigurationMutationAt, payload.lastConfigurationMutationAt)
            && doublesEqual(lastConfigurationMutationMonotonic, payload.lastConfigurationMutationMonotonic)
            && mutationBootSessionUUID == payload.mutationBootSessionUUID
            && datesEqual(lastObservedWall, payload.lastObservedWall)
            && doublesEqual(lastObservedMonotonic, payload.lastObservedMonotonic)
            && lastObservedBootSessionUUID == payload.lastObservedBootSessionUUID
            && abs(accruedMonotonicElapsed - payload.accruedMonotonicElapsed) < 0.000_1
            && pinnedTimeZoneIdentifier == payload.pinnedTimeZoneIdentifier
            && sequence == payload.sequence
    }

    private func datesEqual(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return abs(left.timeIntervalSince(right)) < 0.002
        default:
            return false
        }
    }

    private func doublesEqual(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return abs(left - right) < 0.000_1
        default:
            return false
        }
    }
}
