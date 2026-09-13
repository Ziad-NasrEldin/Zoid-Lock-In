import Foundation

public enum PushRelayError: Error, Equatable, Sendable {
    case timeout
    case httpStatus(Int)
    case invalidResponse
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
    public var sequenceNumber: UInt64
    public var timestamp: Date
    public var focusMode: String
    public var shortcutName: String
    public var aps: SilentAPSPayload

    public init(
        command: PushRelayCommand,
        targetPassKind: PassKind? = nil,
        durationSeconds: Int? = nil,
        sequenceNumber: UInt64,
        timestamp: Date,
        focusMode: String = PushRelayPayload.focusModeName,
        shortcutName: String = PushRelayPayload.shortcutName,
        aps: SilentAPSPayload = SilentAPSPayload()
    ) {
        self.command = command
        self.targetPassKind = targetPassKind
        self.durationSeconds = durationSeconds.map { max(0, $0) }
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
        durationSeconds: Int? = nil
    ) -> PushRelayPayload {
        let pass = targetPassKind.flatMap { kind in
            state.activePasses.first { $0.kind == kind }
        } ?? state.primaryMobilePass
        let resolvedKind: PassKind?
        let resolvedDuration: Int?
        switch command {
        case .passUnlocked:
            resolvedKind = targetPassKind ?? pass?.kind
            resolvedDuration = durationSeconds ?? pass?.remainingDurationSeconds
        case .engageLockdown, .releaseLockdown:
            resolvedKind = targetPassKind
            resolvedDuration = durationSeconds
        }
        return PushRelayPayload(
            command: command,
            targetPassKind: resolvedKind,
            durationSeconds: resolvedDuration,
            sequenceNumber: state.sequenceNumber,
            timestamp: state.timestamp
        )
    }
}

public struct PushRelayConfiguration: Sendable, Equatable {
    public static let defaultEndpoint = URL(string: "https://zoid-lock-in.mavoid.workers.dev/v1/push")!
    public static let defaultEnvironmentVariable = "ZOID_LOCK_IN_PUSH_RELAY_URL"
    public static let defaultKeychainService = "com.mavoid.zoidlockin.push-relay"
    public static let defaultKeychainAccount = "endpoint"
    public static let defaultTimeoutInterval: TimeInterval = 3
    public static let defaultMaxAttempts = 3

    public var endpoint: URL
    public var enabled: Bool
    public var timeoutInterval: TimeInterval
    public var maxAttempts: Int
    public var retryDelayNanoseconds: UInt64
    public var apiKey: String?
    public var environmentVariable: String
    public var keychainService: String
    public var keychainAccount: String

    public init(
        endpoint: URL = PushRelayConfiguration.defaultEndpoint,
        enabled: Bool = false,
        timeoutInterval: TimeInterval = PushRelayConfiguration.defaultTimeoutInterval,
        maxAttempts: Int = PushRelayConfiguration.defaultMaxAttempts,
        retryDelayNanoseconds: UInt64 = 50_000_000,
        apiKey: String? = nil,
        environmentVariable: String = PushRelayConfiguration.defaultEnvironmentVariable,
        keychainService: String = PushRelayConfiguration.defaultKeychainService,
        keychainAccount: String = PushRelayConfiguration.defaultKeychainAccount
    ) {
        self.endpoint = endpoint
        self.enabled = enabled
        self.timeoutInterval = timeoutInterval
        self.maxAttempts = max(1, maxAttempts)
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.apiKey = apiKey
        self.environmentVariable = environmentVariable
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
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
        let resolved = explicitEndpoint ?? envURL ?? keychainURL ?? defaultEndpoint
        let armed = enabled ?? (explicitEndpoint != nil || envURL != nil || keychainURL != nil)
        return PushRelayConfiguration(
            endpoint: resolved,
            enabled: armed,
            environmentVariable: environmentVariable,
            keychainService: keychainService,
            keychainAccount: keychainAccount
        )
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
        apiKey: String? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ZoidLockIn/1.0", forHTTPHeaderField: "User-Agent")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try MobileShieldCoding.makeEncoder().encode(payload)
        return request
    }

    public func makeURLRequest(payload: PushRelayPayload) throws -> URLRequest {
        try Self.makeURLRequest(
            payload: payload,
            configuration: configuration,
            apiKey: configuration.apiKey
        )
    }

    /// Never throws to the caller. Returns `.skipped` when disarmed, `.failed`
    /// after timeout / retry exhaustion, `.sent` on 2xx.
    @discardableResult
    public func dispatch(_ payload: PushRelayPayload) async -> PushRelayOutcome {
        guard configuration.enabled else {
            return .skipped
        }
        do {
            let request = try makeURLRequest(payload: payload)
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
            case .invalidResponse:
                return false
            }
        }
        if error is URLError {
            return true
        }
        return false
    }
}
