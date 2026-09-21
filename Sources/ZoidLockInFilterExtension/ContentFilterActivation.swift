import Foundation
import NetworkExtension
import ZoidLockInCore

/// Activation state of the Network Extension Content Filter.
public enum ContentFilterStatus: String, Sendable, Equatable, Hashable {
    case disabled = "DISABLED"
    case pendingApproval = "PENDING APPROVAL"
    case enabled = "ENABLED"
    case failed = "FAILED"

    public var caption: String {
        switch self {
        case .enabled:
            return "ENABLED · CONTENT FILTER"
        case .pendingApproval:
            return "PENDING USER APPROVAL IN SYSTEM SETTINGS"
        case .disabled:
            return "DISABLED · NOT CONFIGURED"
        case .failed:
            return "ACTIVATION FAILED"
        }
    }
}

/// Abstraction over `NEFilterManager` for testing and decoupling.
public protocol FilterManaging: AnyObject, Sendable {
    var isEnabled: Bool { get set }
    var localizedDescription: String? { get set }
    var providerConfiguration: NEFilterProviderConfiguration? { get set }
    func loadFromPreferences(completionHandler: @escaping @Sendable ((any Error)?) -> Void)
    func saveToPreferences(completionHandler: @escaping @Sendable ((any Error)?) -> Void)
    func applyDisableEncryptedDNSSettings()
}

extension NEFilterManager: @retroactive @unchecked Sendable, FilterManaging {
    public func applyDisableEncryptedDNSSettings() {
        if #available(macOS 15.0, *) {
            self.disableEncryptedDNSSettings = true
        }
    }
}

/// Host-side activator that configures `NEFilterManager` for the filter sysex.
///
/// Called from the unprivileged app after the user approves the system
/// extension. The LaunchDaemon must not call this — a LaunchDaemon cannot host
/// `NEFilterDataProvider`.
///
/// macOS content filters use `NEFilterDataProvider` only (`NEFilterControlProvider`
/// is unavailable on macOS).
public struct ContentFilterActivation: Sendable {
    public static let dataProviderBundleIdentifier =
        ZoidLockInIdentity.filterDataProviderBundleIdentifier
    public static let controlProviderBundleIdentifier =
        ZoidLockInIdentity.filterControlProviderBundleIdentifier
    public static let systemExtensionBundleIdentifier =
        ZoidLockInIdentity.filterSystemExtensionBundleIdentifier

    public init() {}

    /// Builds the provider configuration. Socket filtering is enabled; packet
    /// filtering is not.
    public func makeProviderConfiguration() -> NEFilterProviderConfiguration {
        let configuration = NEFilterProviderConfiguration()
        configuration.filterSockets = true
        configuration.filterPackets = false
        configuration.filterDataProviderBundleIdentifier = Self.dataProviderBundleIdentifier
        return configuration
    }

    /// Applies macOS 15+ encrypted-DNS defeat so DoH/Private Relay cannot hide names.
    public func applyDisableEncryptedDNSSettings(to manager: NEFilterManager) {
        if #available(macOS 15.0, *) {
            manager.disableEncryptedDNSSettings = true
        }
    }

    public func applyDisableEncryptedDNSSettings(to manager: any FilterManaging) {
        manager.applyDisableEncryptedDNSSettings()
    }
}
