import Foundation
import ZoidLockInCore

/// Re-export of process and filter bundle identifiers for XPC and sysex packaging.
public enum ZoidLockInIPCIdentity {
    public static let applicationBundleIdentifier = ZoidLockInIdentity.applicationBundleIdentifier
    public static let daemonLabel = ZoidLockInIdentity.daemonLabel
    public static let filterSystemExtensionBundleIdentifier =
        ZoidLockInIdentity.filterSystemExtensionBundleIdentifier
    public static let filterDataProviderBundleIdentifier =
        ZoidLockInIdentity.filterDataProviderBundleIdentifier
    public static let filterControlProviderBundleIdentifier =
        ZoidLockInIdentity.filterControlProviderBundleIdentifier
    public static let enforcementMachServiceName = ZoidLockInIdentity.enforcementMachServiceName
    public static let xpcClientRequirementTemplate = ZoidLockInIdentity.xpcClientRequirementTemplate

    public static func xpcClientRequirement(teamID: String) -> String {
        ZoidLockInIdentity.xpcClientRequirement(teamID: teamID)
    }

    public static func xpcDaemonRequirement(teamID: String) -> String {
        ZoidLockInIdentity.xpcDaemonRequirement(teamID: teamID)
    }
}
