import Foundation
import Security

/// Human-readable emergency incident payload posted to Resend.
public struct EmergencyIncidentReport: Sendable, Equatable {
    public var timestamp: Date
    public var durationSeconds: Int
    public var recipient: String
    public var eventType: String
    public var creditDebt: Double

    public init(
        timestamp: Date,
        durationSeconds: Int,
        recipient: String,
        eventType: String = "EMERGENCY_OVERRIDE",
        creditDebt: Double = PendingDebtRecord.emergencyPenaltyCredits
    ) {
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.recipient = recipient
        self.eventType = eventType
        self.creditDebt = creditDebt
    }
}

/// JSON body for `POST https://api.resend.com/emails`.
public struct ResendEmailPayload: Sendable, Equatable, Codable {
    public var from: String
    public var to: [String]
    public var subject: String
    public var text: String

    public init(from: String, to: [String], subject: String, text: String) {
        self.from = from
        self.to = to
        self.subject = subject
        self.text = text
    }
}

public enum AlertMailError: Error, Equatable, Sendable {
    case missingAPIKey
    case invalidResponse
    case httpStatus(Int)
}

public protocol HTTPTransporting: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPTransport: HTTPTransporting {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AlertMailError.invalidResponse
        }
        return (data, http)
    }
}

public protocol SecretProviding: Sendable {
    func secret(service: String, account: String) -> String?
}

/// Reads a generic password from the macOS Keychain.
public struct KeychainSecretProvider: SecretProviding {
    public init() {}

    public func secret(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

public struct AlertMailConfiguration: Sendable, Equatable {
    public static let defaultEndpoint = URL(string: "https://api.resend.com/emails")!
    public static let defaultEnvironmentVariable = "ZOID_LOCK_IN_RESEND_API_KEY"
    public static let defaultKeychainService = "com.mavoid.zoidlockin.resend"
    public static let defaultKeychainAccount = "api-key"

    public var endpoint: URL
    public var apiKey: String?
    public var from: String
    public var recipient: String
    public var environmentVariable: String
    public var keychainService: String
    public var keychainAccount: String

    public init(
        endpoint: URL = AlertMailConfiguration.defaultEndpoint,
        apiKey: String? = nil,
        from: String = "Zoid Lock In <alerts@mavoid.com>",
        recipient: String,
        environmentVariable: String = AlertMailConfiguration.defaultEnvironmentVariable,
        keychainService: String = AlertMailConfiguration.defaultKeychainService,
        keychainAccount: String = AlertMailConfiguration.defaultKeychainAccount
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.from = from
        self.recipient = recipient
        self.environmentVariable = environmentVariable
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }
}

public struct ResendAPIKeyResolver: Sendable {
    public var configuration: AlertMailConfiguration
    public var environment: [String: String]
    public var secrets: any SecretProviding

    public init(
        configuration: AlertMailConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        secrets: any SecretProviding = KeychainSecretProvider()
    ) {
        self.configuration = configuration
        self.environment = environment
        self.secrets = secrets
    }

    public func resolve() -> String? {
        if let configured = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return configured
        }

        if let env = environment[configuration.environmentVariable]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !env.isEmpty {
            return env
        }

        if let stored = secrets.secret(
            service: configuration.keychainService,
            account: configuration.keychainAccount
        )?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return stored
        }

        return nil
    }
}

/// Formats and POSTs emergency incident mail through the Resend Emails API.
public struct AlertMailService: EmergencyIncidentAlerting, Sendable {
    public var configuration: AlertMailConfiguration
    public var transport: any HTTPTransporting
    public var keyResolver: ResendAPIKeyResolver

    public var recipient: String { configuration.recipient }

    public init(
        configuration: AlertMailConfiguration,
        transport: any HTTPTransporting = URLSessionHTTPTransport(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        secrets: any SecretProviding = KeychainSecretProvider()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.keyResolver = ResendAPIKeyResolver(
            configuration: configuration,
            environment: environment,
            secrets: secrets
        )
    }

    public static func makePayload(
        report: EmergencyIncidentReport,
        from: String
    ) -> ResendEmailPayload {
        let timestamp = ISO8601DateFormatter().string(from: report.timestamp)
        let minutes = report.durationSeconds / 60
        let text = """
        CRITICAL SECURITY & INTEGRITY ALERT: Emergency Safety Valve engaged.

        Event: \(report.eventType)
        Timestamp: \(timestamp)
        Duration: \(report.durationSeconds) seconds (\(minutes) minutes)
        Recipient: \(report.recipient)
        Pending debt: \(report.creditDebt) credits (mandatory 2-hour penalty)

        All process and domain locks are released for the duration above, then \
        hard lockdown re-engages automatically. Do not treat this as a leisure pass.
        """

        return ResendEmailPayload(
            from: from,
            to: [report.recipient],
            subject: "CRITICAL: Emergency Safety Valve engaged",
            text: text
        )
    }

    public func makeURLRequest(
        payload: ResendEmailPayload,
        apiKey: String
    ) throws -> URLRequest {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    public func dispatchEmergencyIncident(_ report: EmergencyIncidentReport) async throws {
        guard let apiKey = keyResolver.resolve() else {
            throw AlertMailError.missingAPIKey
        }

        let payload = Self.makePayload(report: report, from: configuration.from)
        let request = try makeURLRequest(payload: payload, apiKey: apiKey)
        let (_, response) = try await transport.perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw AlertMailError.httpStatus(response.statusCode)
        }
    }
}
