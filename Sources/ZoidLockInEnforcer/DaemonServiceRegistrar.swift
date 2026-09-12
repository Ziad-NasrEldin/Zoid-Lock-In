import Foundation
import ServiceManagement
import ZoidLockInCore

/// Manages privileged daemon registration through modern `SMAppService.daemon`.
///
/// Does **not** use obsolete `SMJobBless`. The LaunchDaemon plist must live at
/// `Contents/Library/LaunchDaemons/<plistName>` inside the app bundle.
public struct DaemonServiceRegistrar: Sendable {
    public let configuration: DaemonConfiguration
    public let plistName: String

    public init(
        configuration: DaemonConfiguration = DaemonConfiguration(),
        plistName: String = DaemonConfiguration.plistFileName
    ) {
        self.configuration = configuration
        self.plistName = plistName
    }

    /// Creates the `SMAppService` handle for this daemon plist.
    public func makeService() -> SMAppService {
        SMAppService.daemon(plistName: plistName)
    }

    /// Registers the daemon with `launchd` via SMAppService.
    @discardableResult
    public func register() throws -> SMAppService.Status {
        let service = makeService()
        try service.register()
        return service.status
    }

    /// Unregisters the daemon.
    public func unregister() throws {
        try makeService().unregister()
    }

    /// Current registration status.
    public var status: SMAppService.Status {
        makeService().status
    }

    /// Ensures configuration is valid before attempting SMAppService registration.
    public func validateForRegistration() throws {
        let issues = configuration.validate()
        guard issues.isEmpty else {
            throw DaemonRegistrationError.invalidConfiguration(issues)
        }
    }
}

public enum DaemonRegistrationError: Error, Equatable, LocalizedError {
    case invalidConfiguration([String])

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let issues):
            return "Invalid daemon configuration: \(issues.joined(separator: "; "))"
        }
    }
}

    /// Privileged enforcement daemon lifecycle coordinator (Slice 1 prototype).
    ///
    /// Owns the process sentinel. Does **not** instantiate `ContentFilterProvider`;
    /// that type lives in `ZoidLockInFilterExtension`.
public final class EnforcementDaemon: @unchecked Sendable {
    public let configuration: DaemonConfiguration
    public let registrar: DaemonServiceRegistrar
    public let processSentinel: ProcessSentinel

    private let lock = NSLock()
    private var policy: EnforcementPolicy
    private var isStarted = false

    public init(
        configuration: DaemonConfiguration = DaemonConfiguration(),
        policy: EnforcementPolicy = .lockedDown,
        processSentinel: ProcessSentinel? = nil
    ) {
        self.configuration = configuration
        self.registrar = DaemonServiceRegistrar(configuration: configuration)
        self.policy = policy
        self.processSentinel = processSentinel ?? ProcessSentinel(
            matcher: policy.processMatcher,
            scanInterval: policy.processScanIntervalSeconds
        )
    }

    public var currentPolicy: EnforcementPolicy {
        lock.lock()
        defer { lock.unlock() }
        return policy
    }

    public func applyPolicy(_ policy: EnforcementPolicy) {
        lock.lock()
        self.policy = policy
        lock.unlock()
        processSentinel.apply(policy)
    }

    /// Starts the process sentinel. Network Extension activation is owned by the
    /// unprivileged app via `ContentFilterActivation`; this daemon never hosts
    /// `NEFilterDataProvider`.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isStarted else { return }
        isStarted = true
        processSentinel.start()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isStarted else { return }
        isStarted = false
        processSentinel.stop()
    }

    /// LaunchDaemon plist payload expected by SMAppService packaging.
    public var launchDaemonPropertyList: [String: Any] {
        configuration.propertyList
    }

    public var launchDaemonPropertyListXML: String {
        configuration.propertyListXML()
    }
}
