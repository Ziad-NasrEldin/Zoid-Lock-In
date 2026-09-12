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
