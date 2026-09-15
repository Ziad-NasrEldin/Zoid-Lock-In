import CryptoKit
import Foundation

/// HMAC-SHA256 seal over the 3-day calibration window. SQLite is a cache;
/// a missing, corrupt, or mismatched signature fail-closes into `.hard`.
public enum CalibrationSealLocation: Sendable {
    public static let privilegedDirectoryPath = "/var/db/zoidlockin"
    public static let fileName = "calibration_state.json"
    public static let keychainAccount = "com.mavoid.zoidlockin.calibration.key"

    public static var privilegedDirectoryURL: URL {
        URL(fileURLWithPath: privilegedDirectoryPath, isDirectory: true)
    }

    public static var privilegedFileURL: URL {
        privilegedDirectoryURL.appendingPathComponent(fileName)
    }
}

public enum CalibrationSecrets: Sendable {
    public static let context = "com.mavoid.zoidlockin.calibration.v1"
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
            throw CalibrationError.integrityFailed
        }
        let key = SymmetricKey(data: data)
        if isPublicTeamIdentifierKDF(key) {
            throw CalibrationError.integrityFailed
        }
        return key
    }
}

public enum CalibrationError: Error, Equatable, Sendable {
    case integrityFailed
}

public protocol CalibrationKeyProviding: Sendable {
    func loadOrCreate() throws -> SymmetricKey
}

public struct InMemoryCalibrationKeyProvider: CalibrationKeyProviding, Sendable {
    public let key: SymmetricKey

    public init(key: SymmetricKey = CalibrationSecrets.randomKey()) {
        self.key = key
    }

    public func loadOrCreate() throws -> SymmetricKey {
        try CalibrationSecrets.validatedKey(from: CalibrationSecrets.rawBytes(of: key))
    }
}

public struct KeychainCalibrationKeyProvider: CalibrationKeyProviding, Sendable {
    public var store: any KeychainDataStoring
    public var service: String
    public var account: String

    public init(
        store: any KeychainDataStoring = ZoidLockInKeychain(),
        service: String = ZoidLockInKeychain.calibrationService,
        account: String = ZoidLockInKeychain.calibrationKeyAccount
    ) {
        self.store = store
        self.service = service
        self.account = account
    }

    public func loadOrCreate() throws -> SymmetricKey {
        if let existing = store.data(service: service, account: account),
           let key = try? CalibrationSecrets.validatedKey(from: existing) {
            return key
        }
        let key = CalibrationSecrets.randomKey()
        try store.setData(CalibrationSecrets.rawBytes(of: key), service: service, account: account)
        return key
    }
}

public struct CalibrationSealPayload: Sendable, Equatable, Codable {
    public var version: Int
    public var calibrationStartedAt: Date
    public var calibrationStartedMonotonic: TimeInterval
    public var bootSessionUUID: String
    public var isCompleted: Bool
    public var transitionToHardAt: Date
    public var lastObservedWall: Date?
    public var lastObservedMonotonic: TimeInterval?
    public var accruedMonotonicElapsed: TimeInterval
    public var isTampered: Bool
    public var sequence: UInt64

    public init(
        version: Int = 1,
        calibrationStartedAt: Date,
        calibrationStartedMonotonic: TimeInterval,
        bootSessionUUID: String,
        isCompleted: Bool,
        transitionToHardAt: Date,
        lastObservedWall: Date? = nil,
        lastObservedMonotonic: TimeInterval? = nil,
        accruedMonotonicElapsed: TimeInterval = 0,
        isTampered: Bool = false,
        sequence: UInt64 = 0
    ) {
        self.version = version
        self.calibrationStartedAt = calibrationStartedAt
        self.calibrationStartedMonotonic = calibrationStartedMonotonic
        self.bootSessionUUID = bootSessionUUID
        self.isCompleted = isCompleted
        self.transitionToHardAt = transitionToHardAt
        self.lastObservedWall = lastObservedWall
        self.lastObservedMonotonic = lastObservedMonotonic
        self.accruedMonotonicElapsed = max(0, accruedMonotonicElapsed)
        self.isTampered = isTampered
        self.sequence = sequence
    }

    public init(_ state: CalibrationState) {
        self.init(
            calibrationStartedAt: state.calibrationStartedAt,
            calibrationStartedMonotonic: state.calibrationStartedMonotonic,
            bootSessionUUID: state.bootSessionUUID,
            isCompleted: state.isCompleted,
            transitionToHardAt: state.transitionToHardAt,
            lastObservedWall: state.lastObservedWall,
            lastObservedMonotonic: state.lastObservedMonotonic,
            accruedMonotonicElapsed: state.accruedMonotonicElapsed,
            isTampered: state.isTampered,
            sequence: state.sequence
        )
    }
}

public struct CalibrationSealEnvelope: Sendable, Equatable, Codable {
    public var payload: CalibrationSealPayload
    public var hmac: String

    public init(payload: CalibrationSealPayload, hmac: String) {
        self.payload = payload
        self.hmac = hmac
    }
}

public enum CalibrationSeal: Sendable {
    public static func canonicalBytes(_ payload: CalibrationSealPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(payload)
    }

    public static func seal(_ payload: CalibrationSealPayload, key: SymmetricKey) throws -> CalibrationSealEnvelope {
        let bytes = try canonicalBytes(payload)
        let code = Data(HMAC<SHA256>.authenticationCode(for: bytes, using: key))
        return CalibrationSealEnvelope(payload: payload, hmac: code.base64EncodedString())
    }

    public static func verify(_ envelope: CalibrationSealEnvelope, key: SymmetricKey) -> Bool {
        guard let given = Data(base64Encoded: envelope.hmac), !given.isEmpty else {
            return false
        }
        guard let bytes = try? canonicalBytes(envelope.payload) else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: bytes, using: key)
    }

    public static func encode(_ envelope: CalibrationSealEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(envelope)
    }

    public static func decode(_ data: Data) throws -> CalibrationSealEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(CalibrationSealEnvelope.self, from: data)
    }
}

public protocol CalibrationSealPersisting: Sendable {
    func loadEnvelope() throws -> CalibrationSealEnvelope?
    func saveEnvelope(_ envelope: CalibrationSealEnvelope) throws
}

public final class InMemoryCalibrationSealStore: CalibrationSealPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var envelope: CalibrationSealEnvelope?

    public init() {}

    public func loadEnvelope() throws -> CalibrationSealEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return envelope
    }

    public func saveEnvelope(_ envelope: CalibrationSealEnvelope) throws {
        lock.lock()
        defer { lock.unlock() }
        self.envelope = envelope
    }
}

/// Privileged `/var/db/zoidlockin/calibration_state.json` plus a user-space
/// fallback and a Keychain replica. Verification fail-closes if any authentic
/// replica disagrees with SQLite.
public final class FileCalibrationSealStore: CalibrationSealPersisting, @unchecked Sendable {
    public let privilegedFileURL: URL
    public let fallbackFileURL: URL
    public let keychainStore: any KeychainDataStoring
    public let keychainService: String
    public let keychainSealAccount: String

    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        privilegedFileURL: URL = CalibrationSealLocation.privilegedFileURL,
        fallbackDirectory: URL,
        keychainStore: any KeychainDataStoring = ZoidLockInKeychain(),
        keychainService: String = ZoidLockInKeychain.calibrationService,
        keychainSealAccount: String = ZoidLockInKeychain.calibrationSealAccount,
        fileManager: FileManager = .default
    ) {
        self.privilegedFileURL = privilegedFileURL
        self.fallbackFileURL = fallbackDirectory.appendingPathComponent(CalibrationSealLocation.fileName)
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

    public func loadEnvelope() throws -> CalibrationSealEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        let candidates = [
            try? Data(contentsOf: privilegedFileURL),
            try? Data(contentsOf: fallbackFileURL),
            keychainStore.data(service: keychainService, account: keychainSealAccount),
        ]
        var decoded: [CalibrationSealEnvelope] = []
        for data in candidates {
            guard let data, !data.isEmpty, let envelope = try? CalibrationSeal.decode(data) else {
                continue
            }
            decoded.append(envelope)
        }
        return Self.mostRestrictive(decoded)
    }

    public func saveEnvelope(_ envelope: CalibrationSealEnvelope) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try CalibrationSeal.encode(envelope)
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

    public static func mostRestrictive(_ envelopes: [CalibrationSealEnvelope]) -> CalibrationSealEnvelope? {
        guard !envelopes.isEmpty else { return nil }
        return envelopes.min { lhs, rhs in
            if lhs.payload.isCompleted != rhs.payload.isCompleted {
                return lhs.payload.isCompleted && !rhs.payload.isCompleted
            }
            if lhs.payload.accruedMonotonicElapsed != rhs.payload.accruedMonotonicElapsed {
                return lhs.payload.accruedMonotonicElapsed > rhs.payload.accruedMonotonicElapsed
            }
            if lhs.payload.transitionToHardAt != rhs.payload.transitionToHardAt {
                return lhs.payload.transitionToHardAt < rhs.payload.transitionToHardAt
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

enum CalibrationLoad: Equatable {
    case firstLaunch
    case loaded(CalibrationState)
}

enum CalibrationIntegrity {
    static func verify(
        sqlite: CalibrationState?,
        envelope: CalibrationSealEnvelope?,
        replica: CalibrationSealEnvelope?,
        key: SymmetricKey
    ) throws -> CalibrationLoad {
        if let envelope, !CalibrationSeal.verify(envelope, key: key) {
            throw CalibrationError.integrityFailed
        }
        if let replica, !CalibrationSeal.verify(replica, key: key) {
            throw CalibrationError.integrityFailed
        }

        let sealed = FileCalibrationSealStore.mostRestrictive(
            [envelope, replica].compactMap { $0 }
        )

        guard let sqlite else {
            if sealed != nil {
                throw CalibrationError.integrityFailed
            }
            return .firstLaunch
        }

        guard let sealed else {
            throw CalibrationError.integrityFailed
        }
        guard sqlite.sealMaterialMatches(sealed.payload) else {
            throw CalibrationError.integrityFailed
        }
        return .loaded(sqlite)
    }
}

extension CalibrationState {
    func sealMaterialMatches(_ payload: CalibrationSealPayload) -> Bool {
        datesEqual(calibrationStartedAt, payload.calibrationStartedAt)
            && abs(calibrationStartedMonotonic - payload.calibrationStartedMonotonic) < 0.000_1
            && bootSessionUUID == payload.bootSessionUUID
            && isCompleted == payload.isCompleted
            && datesEqual(transitionToHardAt, payload.transitionToHardAt)
            && datesEqual(lastObservedWall, payload.lastObservedWall)
            && doublesEqual(lastObservedMonotonic, payload.lastObservedMonotonic)
            && abs(accruedMonotonicElapsed - payload.accruedMonotonicElapsed) < 0.000_1
            && isTampered == payload.isTampered
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

    private func datesEqual(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 0.002
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
