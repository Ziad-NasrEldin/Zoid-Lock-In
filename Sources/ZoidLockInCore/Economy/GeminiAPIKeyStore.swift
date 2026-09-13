import Foundation

/// Keychain + environment resolution for the Google AI Studio Gemini API key.
public enum GeminiAPIKeyStore: Sendable {
    public static let service = ZoidLockInKeychain.geminiService
    public static let account = ZoidLockInKeychain.geminiAccount
    public static let environmentVariable = "GEMINI_API_KEY"

    public static func store(_ key: String, into secrets: any KeychainDataStoring) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw GeminiAuditError.invalidAPIKey
        }
        try secrets.setData(data, service: service, account: account)
    }

    public static func load(from secrets: any KeychainDataStoring) -> String? {
        guard let data = secrets.data(service: service, account: account),
              let key = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func delete(from secrets: any KeychainDataStoring) throws {
        try secrets.delete(service: service, account: account)
    }
}

/// Keychain is primary; `GEMINI_API_KEY` is the development/CI fallback.
public struct GeminiAPIKeyResolver: Sendable {
    public var environment: [String: String]
    public var secrets: any SecretProviding
    public var configuredKey: String?

    public init(
        configuredKey: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        secrets: any SecretProviding = KeychainSecretProvider()
    ) {
        self.configuredKey = configuredKey
        self.environment = environment
        self.secrets = secrets
    }

    public func resolve() -> String? {
        if let configured = configuredKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return configured
        }
        if let stored = secrets.secret(
            service: GeminiAPIKeyStore.service,
            account: GeminiAPIKeyStore.account
        )?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return stored
        }
        if let env = environment[GeminiAPIKeyStore.environmentVariable]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !env.isEmpty {
            return env
        }
        return nil
    }
}

extension InMemoryKeychainStore: SecretProviding {
    public func secret(service: String, account: String) -> String? {
        guard let data = data(service: service, account: account) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
