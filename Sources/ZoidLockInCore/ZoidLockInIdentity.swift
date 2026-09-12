import Foundation

/// Reverse-DNS identifiers for the three Slice 1 processes.
///
/// The Network Extension content filter is a **system extension** with its own
/// bundle identifier. It is never hosted inside the LaunchDaemon.
public enum ZoidLockInIdentity: Sendable {
    public static let applicationBundleIdentifier = "com.mavoid.zoidlockin"
    public static let daemonLabel = "com.mavoid.zoidlockin.helper"
    public static let daemonPlistFileName = "com.mavoid.zoidlockin.helper.plist"
    public static let filterSystemExtensionBundleIdentifier = "com.mavoid.zoidlockin.filter"
    public static let filterDataProviderBundleIdentifier = "com.mavoid.zoidlockin.filter"
    public static let filterControlProviderBundleIdentifier = "com.mavoid.zoidlockin.filter"

    /// Mach service name reserved for Slice 2. Must not appear in the Slice 1
    /// LaunchDaemon plist until `audit_token_t` validation ships with it.
    public static let enforcementMachServiceName = "com.mavoid.zoidlockin.enforcement"

    /// Team-ID-pinned client requirement. Slice 2 must substitute the real Team ID.
    /// Do not implement `anchor apple generic` without `certificate leaf[subject.OU]`.
    public static let xpcClientRequirementTemplate =
        "anchor apple generic and certificate leaf[subject.OU] = \"TEAMID\" and identifier \"com.mavoid.zoidlockin\""
}
