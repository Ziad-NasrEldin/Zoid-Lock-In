import Foundation
import Security

public enum ZoidLockInKeychainError: Error, Equatable, Sendable {
    case invalidKeyLength(Int)
    case storeFailed(OSStatus)
    case updateFailed(OSStatus)
    case deleteFailed(OSStatus)
}

extension ZoidLockInKeychainError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidKeyLength(let length):
            return "Keychain key must be 32 bytes, got \(length)"
        case .storeFailed(let status):
            return "Keychain persist failed (\(status))"
        case .updateFailed(let status):
            return "Keychain update failed (\(status))"
        case .deleteFailed(let status):
            return "Keychain delete failed (\(status))"
        }
    }
}

/// Binary Keychain seam. Production uses the Security framework; tests inject
/// an in-memory store so headless runs never touch the login keychain.
public protocol KeychainDataStoring: Sendable {
    func data(service: String, account: String) -> Data?
    func setData(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

/// `kSecClassGenericPassword` wrapper. Items are device-bound
/// (`AfterFirstUnlockThisDeviceOnly`) and never iCloud-synced from this type.
public struct ZoidLockInKeychain: KeychainDataStoring {
    public static let mobileShieldService = "com.mavoid.zoidlockin.mobile-shield"
    public static let mobileShieldKeyAccount = "com.mavoid.zoidlockin.mobile-shield.key"
    public static let mobileShieldHighWaterAccount = "com.mavoid.zoidlockin.mobile-shield.hw"
    public static let governanceService = "com.mavoid.zoidlockin.governance"
    public static let governanceKeyAccount = "com.mavoid.zoidlockin.governance.key"
    public static let governanceSealAccount = "com.mavoid.zoidlockin.governance.seal"
    public static let geminiService = "com.mavoid.zoidlockin.gemini"
    public static let geminiAccount = "api_key"
    public static let securityService = "com.mavoid.zoidlockin.security"
    public static let passwordHashAccount = "admin-password-hash"
    public static let totpSecretAccount = "admin-totp-secret"
    public static let alertRecipientAccount = "alert-mail-recipient"

    public init() {}

    public func data(service: String, account: String) -> Data? {
        Self.load(service: service, account: account)
    }

    public func setData(_ data: Data, service: String, account: String) throws {
        try Self.store(data, service: service, account: account)
    }

    public func delete(service: String, account: String) throws {
        try Self.deleteItem(service: service, account: account)
    }

    public static func load(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    public static func store(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        if existing == errSecSuccess {
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else {
                throw ZoidLockInKeychainError.updateFailed(status)
            }
            return
        }
        var add = query
        for (key, value) in attributes {
            add[key] = value
        }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ZoidLockInKeychainError.storeFailed(status)
        }
    }

    public static func deleteItem(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ZoidLockInKeychainError.deleteFailed(status)
        }
    }
}

/// Process-local Keychain stand-in for tests and unsigned `swift test` runs.
public final class InMemoryKeychainStore: KeychainDataStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func data(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[Self.makeKey(service: service, account: account)]
    }

    public func setData(_ data: Data, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[Self.makeKey(service: service, account: account)] = data
    }

    public func delete(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items.removeValue(forKey: Self.makeKey(service: service, account: account))
    }

    private static func makeKey(service: String, account: String) -> String {
        "\(service)\u{1F}\(account)"
    }
}
