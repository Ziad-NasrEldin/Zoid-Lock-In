import CryptoKit
import Foundation

public enum PushRelayError: Error, Equatable, Sendable {
    case timeout
    case httpStatus(Int)
    case invalidResponse
    case unconfigured
    case unauthenticated
    case replayRejected
}

extension PushRelayError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "Push relay request timed out"
        case .httpStatus(let code):
            return "Push relay HTTP status \(code)"
        case .invalidResponse:
            return "Push relay returned an invalid response"
        case .unconfigured:
            return "Push relay URL is not configured"
        case .unauthenticated:
            return "Push relay is missing a Bearer token or HMAC secret"
        case .replayRejected:
            return "Push relay timestamp is outside the replay window"
        }
    }
}

public enum PushRelayCommand: String, Sendable, Equatable, Codable {
    case engageLockdown = "engage_lockdown"
    case releaseLockdown = "release_lockdown"
    case passUnlocked = "pass_unlocked"
}

/// Silent APNs trigger consumed by the Cloudflare Worker and iOS Shortcuts.
public struct SilentAPSPayload: Sendable, Equatable, Codable {
    public var contentAvailable: Int

    public init(contentAvailable: Int = 1) {
        self.contentAvailable = contentAvailable
    }

    enum CodingKeys: String, CodingKey {
        case contentAvailable = "content-available"
    }
}

/// Webhook body posted to the Cloudflare Worker push relay.
public struct PushRelayPayload: Sendable, Equatable, Codable {
    public static let focusModeName = "Lock In"
    public static let shortcutName = "Lock In"

    public var command: PushRelayCommand
    public var targetPassKind: PassKind?
    public var durationSeconds: Int?
    public var expiresAtUtc: Date?
    public var localRelockDurationSeconds: Int?
    public var sequenceNumber: UInt64
    public var timestamp: Date
    public var focusMode: String
    public var shortcutName: String
    public var aps: SilentAPSPayload

    public init(
        command: PushRelayCommand,
        targetPassKind: PassKind? = nil,
        durationSeconds: Int? = nil,
        expiresAtUtc: Date? = nil,
        localRelockDurationSeconds: Int? = nil,
        sequenceNumber: UInt64,
        timestamp: Date,
        focusMode: String = PushRelayPayload.focusModeName,
        shortcutName: String = PushRelayPayload.shortcutName,
        aps: SilentAPSPayload = SilentAPSPayload()
    ) {
        self.command = command
        self.targetPassKind = targetPassKind
        self.durationSeconds = durationSeconds.map { max(0, $0) }
        self.expiresAtUtc = expiresAtUtc.map(MobileShieldCoding.normalize)
        self.localRelockDurationSeconds = localRelockDurationSeconds.map { max(0, $0) }
        self.sequenceNumber = sequenceNumber
        self.timestamp = MobileShieldCoding.normalize(timestamp)
        self.focusMode = focusMode
        self.shortcutName = shortcutName
        self.aps = aps
    }

    public var isSilent: Bool {
        aps.contentAvailable == 1
    }

    public static func make(
        command: PushRelayCommand,
        state: MobileShieldState,
        targetPassKind: PassKind? = nil,
        durationSeconds: Int? = nil,
        now: Date = Date()
    ) -> PushRelayPayload {
        let pass = targetPassKind.flatMap { kind in
            state.activePasses.first { $0.kind == kind }
        } ?? state.primaryMobilePass
        let resolvedKind: PassKind?
        let resolvedDuration: Int?
        let resolvedExpiry: Date?
        let resolvedRelock: Int?
        switch command {
        case .passUnlocked:
            resolvedKind = targetPassKind ?? pass?.kind
            resolvedDuration = durationSeconds ?? pass?.remainingDurationSeconds
            resolvedExpiry = pass?.expiresAtUtc
            resolvedRelock = pass?.localRelockDurationSeconds ?? resolvedDuration
        case .engageLockdown:
            resolvedKind = targetPassKind
            resolvedDuration = durationSeconds
            resolvedExpiry = MobileShieldCoding.normalize(now)
            resolvedRelock = 0
        case .releaseLockdown:
            resolvedKind = targetPassKind
            resolvedDuration = durationSeconds
            resolvedExpiry = pass?.expiresAtUtc
            resolvedRelock = durationSeconds ?? pass?.remainingDurationSeconds
        }
        return PushRelayPayload(
            command: command,
            targetPassKind: resolvedKind,
            durationSeconds: resolvedDuration,
            expiresAtUtc: resolvedExpiry,
            localRelockDurationSeconds: resolvedRelock,
            sequenceNumber: state.sequenceNumber,
            timestamp: state.timestamp
        )
    }
}

public enum PushRelayAuthenticator: Sendable {
    public static let replayWindowSeconds: TimeInterval = 300
    public static let timestampHeader = "X-Zoid-Timestamp"
    public static let signatureHeader = "X-Zoid-Signature"

    public static func unixTimestamp(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970.rounded()))
    }

    public static func signature(timestamp: String, payload: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        var message = Data(timestamp.utf8)
        message.append(payload)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    public static func isTimestampFresh(
        _ timestamp: String,
        now: Date,
        window: TimeInterval = replayWindowSeconds
    ) -> Bool {
        guard let seconds = TimeInterval(timestamp) else {
            return false
        }
        return abs(now.timeIntervalSince1970 - seconds) <= window
    }

    public static func verifyHMAC(
        timestamp: String,
        payload: Data,
        signature: String,
        secret: String
    ) -> Bool {
        let expected = Self.signature(timestamp: timestamp, payload: payload, secret: secret)
        guard expected.count == signature.count else {
            return false
        }
        let expectedBytes = Array(expected.utf8)
        let actualBytes = Array(signature.lowercased().utf8)
        guard expectedBytes.count == actualBytes.count else {
            return false
        }
        var difference: UInt8 = 0
        for index in expectedBytes.indices {
            difference |= expectedBytes[index] ^ actualBytes[index]
        }
        return difference == 0
    }

    public static func verify(
        timestampHeader: String?,
        signatureHeader: String?,
        authorizationHeader: String?,
        payload: Data,
        hmacSecret: String?,
        expectedBearer: String?,
        now: Date,
        window: TimeInterval = replayWindowSeconds
    ) throws {
        guard let timestamp = timestampHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
              !timestamp.isEmpty else {
            throw PushRelayError.replayRejected
        }
        guard isTimestampFresh(timestamp, now: now, window: window) else {
            throw PushRelayError.replayRejected
        }

        let hmacOK: Bool
        if let hmacSecret, !hmacSecret.isEmpty {
            guard let signature = signatureHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !signature.isEmpty,
                  verifyHMAC(
                    timestamp: timestamp,
                    payload: payload,
                    signature: signature,
                    secret: hmacSecret
                  ) else {
                throw PushRelayError.unauthenticated
            }
            hmacOK = true
        } else {
            hmacOK = false
        }

        let bearerOK: Bool
        if let expectedBearer, !expectedBearer.isEmpty {
            bearerOK = authorizationHeader == "Bearer \(expectedBearer)"
        } else {
            bearerOK = false
        }

        if hmacOK {
            return
        }
        if bearerOK {
            return
        }
        throw PushRelayError.unauthenticated
    }
}

public struct PushRelayConfiguration: Sendable, Equatable {
    public static let defaultEnvironmentVariable = "ZOID_LOCK_IN_PUSH_RELAY_URL"
    public static let apiKeyEnvironmentVariable = "ZOID_LOCK_IN_PUSH_RELAY_API_KEY"
    public static let hmacSecretEnvironmentVariable = "ZOID_LOCK_IN_PUSH_RELAY_HMAC_SECRET"
    public static let defaultKeychainService = "com.mavoid.zoidlockin.push-relay"
    public static let defaultKeychainAccount = "endpoint"
    public static let apiKeyKeychainAccount = "api-key"
    public static let hmacSecretKeychainAccount = "hmac-secret"
    public static let defaultTimeoutInterval: TimeInterval = 3
    public static let defaultMaxAttempts = 3

    public var endpoint: URL?
    public var timeoutInterval: TimeInterval
    public var maxAttempts: Int
    public var retryDelayNanoseconds: UInt64
    public var apiKey: String?
    public var hmacSecret: String?
    public var environmentVariable: String
    public var keychainService: String
    public var keychainAccount: String
    private var requestedEnabled: Bool

    public var enabled: Bool {
        requestedEnabled && endpoint != nil && hasCredential
    }

    public var isConfigured: Bool {
        enabled
    }

    public var hasCredential: Bool {
        Self.hasCredential(apiKey: apiKey, hmacSecret: hmacSecret)
    }

    public init(
        endpoint: URL? = nil,
        enabled: Bool = false,
        timeoutInterval: TimeInterval = PushRelayConfiguration.defaultTimeoutInterval,
        maxAttempts: Int = PushRelayConfiguration.defaultMaxAttempts,
        retryDelayNanoseconds: UInt64 = 50_000_000,
        apiKey: String? = nil,
        hmacSecret: String? = nil,
        environmentVariable: String = PushRelayConfiguration.defaultEnvironmentVariable,
        keychainService: String = PushRelayConfiguration.defaultKeychainService,
        keychainAccount: String = PushRelayConfiguration.defaultKeychainAccount
    ) {
        self.endpoint = endpoint
        self.requestedEnabled = enabled
        self.timeoutInterval = timeoutInterval
        self.maxAttempts = max(1, maxAttempts)
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.apiKey = Self.normalized(apiKey)
        self.hmacSecret = Self.normalized(hmacSecret)
        self.environmentVariable = environmentVariable
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }

    public static func hasCredential(apiKey: String?, hmacSecret: String?) -> Bool {
        if let apiKey, !apiKey.isEmpty {
            return true
        }
        if let hmacSecret, !hmacSecret.isEmpty {
            return true
        }
        return false
    }

    public static func resolve(
        explicitEndpoint: URL? = nil,
        enabled: Bool? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        secrets: any SecretProviding = KeychainSecretProvider(),
        environmentVariable: String = defaultEnvironmentVariable,
        keychainService: String = defaultKeychainService,
        keychainAccount: String = defaultKeychainAccount
    ) -> PushRelayConfiguration {
        let envURL = environment[environmentVariable]
            .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let keychainURL = secrets.secret(service: keychainService, account: keychainAccount)
            .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let resolved = explicitEndpoint ?? envURL ?? keychainURL

        let envAPIKey = normalized(environment[apiKeyEnvironmentVariable])
        let keychainAPIKey = normalized(secrets.secret(service: keychainService, account: apiKeyKeychainAccount))
        let apiKey = envAPIKey ?? keychainAPIKey

        let envHMAC = normalized(environment[hmacSecretEnvironmentVariable])
        let keychainHMAC = normalized(secrets.secret(service: keychainService, account: hmacSecretKeychainAccount))
        let hmacSecret = envHMAC ?? keychainHMAC

        let hasCredential = hasCredential(apiKey: apiKey, hmacSecret: hmacSecret)
        let hasURL = resolved != nil
        let armed = enabled ?? (hasURL && hasCredential)
        return PushRelayConfiguration(
            endpoint: resolved,
            enabled: armed,
            apiKey: apiKey,
            hmacSecret: hmacSecret,
            environmentVariable: environmentVariable,
            keychainService: keychainService,
            keychainAccount: keychainAccount
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public enum PushRelayOutcome: Sendable, Equatable {
    case sent
    case skipped
    case failed
}

/// Dispatches silent APNs webhook requests. Timeouts and HTTP errors fail
/// silent — they must never block local lockdown.
public struct PushRelayClient: Sendable {
    public var configuration: PushRelayConfiguration
    public var transport: any HTTPTransporting

    public init(
        configuration: PushRelayConfiguration = PushRelayConfiguration(),
        transport: any HTTPTransporting = URLSessionHTTPTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public static func makeURLRequest(
        payload: PushRelayPayload,
        configuration: PushRelayConfiguration,
        apiKey: String? = nil,
        now: Date = Date()
    ) throws -> URLRequest {
        guard let endpoint = configuration.endpoint else {
            throw PushRelayError.unconfigured
        }
        let resolvedKey = apiKey ?? configuration.apiKey
        let hmacSecret = configuration.hmacSecret
        guard PushRelayConfiguration.hasCredential(apiKey: resolvedKey, hmacSecret: hmacSecret) else {
            throw PushRelayError.unauthenticated
        }
        let body = try MobileShieldCoding.makeEncoder().encode(payload)
        let timestamp = PushRelayAuthenticator.unixTimestamp(now)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ZoidLockIn/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue(timestamp, forHTTPHeaderField: PushRelayAuthenticator.timestampHeader)
        if let resolvedKey, !resolvedKey.isEmpty {
            request.setValue("Bearer \(resolvedKey)", forHTTPHeaderField: "Authorization")
        }
        if let hmacSecret, !hmacSecret.isEmpty {
            let signature = PushRelayAuthenticator.signature(
                timestamp: timestamp,
                payload: body,
                secret: hmacSecret
            )
            request.setValue(signature, forHTTPHeaderField: PushRelayAuthenticator.signatureHeader)
        }
        request.httpBody = body
        return request
    }

    public func makeURLRequest(payload: PushRelayPayload, now: Date = Date()) throws -> URLRequest {
        try Self.makeURLRequest(
            payload: payload,
            configuration: configuration,
            apiKey: configuration.apiKey,
            now: now
        )
    }

    /// Never throws to the caller. Returns `.skipped` when disarmed, `.failed`
    /// after timeout / retry exhaustion, `.sent` on 2xx.
    @discardableResult
    public func dispatch(_ payload: PushRelayPayload, now: Date = Date()) async -> PushRelayOutcome {
        guard configuration.enabled else {
            return .skipped
        }
        do {
            let request = try makeURLRequest(payload: payload, now: now)
            try await performWithRetry(request)
            return .sent
        } catch {
            return .failed
        }
    }

    private func performWithRetry(_ request: URLRequest) async throws {
        var lastError: Error = PushRelayError.timeout
        for attempt in 1...configuration.maxAttempts {
            do {
                let (_, response) = try await performWithTimeout(request)
                guard (200..<300).contains(response.statusCode) else {
                    if (500..<600).contains(response.statusCode),
                       attempt < configuration.maxAttempts {
                        lastError = PushRelayError.httpStatus(response.statusCode)
                        await sleepForRetry()
                        continue
                    }
                    throw PushRelayError.httpStatus(response.statusCode)
                }
                return
            } catch let error as PushRelayError where error == .timeout {
                lastError = error
                if attempt < configuration.maxAttempts {
                    await sleepForRetry()
                    continue
                }
            } catch {
                lastError = error
                if attempt < configuration.maxAttempts, Self.isRetriable(error) {
                    await sleepForRetry()
                    continue
                }
                throw error
            }
        }
        throw lastError
    }

    private func performWithTimeout(
        _ request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let timeout = configuration.timeoutInterval
        return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask {
                let (data, response) = try await self.transport.perform(request)
                return (data, response)
            }
            group.addTask {
                let nanoseconds = UInt64(max(timeout, 0.01) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw PushRelayError.timeout
            }
            defer { group.cancelAll() }
            do {
                guard let result = try await group.next() else {
                    throw PushRelayError.timeout
                }
                return result
            } catch is CancellationError {
                throw PushRelayError.timeout
            }
        }
    }

    private func sleepForRetry() async {
        guard configuration.retryDelayNanoseconds > 0 else { return }
        try? await Task.sleep(nanoseconds: configuration.retryDelayNanoseconds)
    }

    private static func isRetriable(_ error: Error) -> Bool {
        if let relay = error as? PushRelayError {
            switch relay {
            case .timeout, .httpStatus:
                return true
            case .invalidResponse, .unconfigured, .unauthenticated, .replayRejected:
                return false
            }
        }
        if error is URLError {
            return true
        }
        return false
    }
}
