import Foundation
import NetworkExtension
import ZoidLockInCore

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
}
