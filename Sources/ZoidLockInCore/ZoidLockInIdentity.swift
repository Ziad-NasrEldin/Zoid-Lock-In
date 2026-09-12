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

    /// Mach service advertised by the LaunchDaemon after `audit_token_t` validation shipped.
    public static let enforcementMachServiceName = "com.mavoid.zoidlockin.enforcement"

    /// Environment variable that replaces the `TEAMID` placeholder at runtime.
    public static let teamIdentifierEnvironmentVariable = "ZOID_LOCK_IN_TEAM_ID"

    /// Placeholder used until a real Apple Developer Team ID is supplied.
    public static let teamIdentifierPlaceholder = "TEAMID"

    /// Team-ID-pinned client requirement template. Do not implement
    /// `anchor apple generic` without `certificate leaf[subject.OU]`.
    public static let xpcClientRequirementTemplate =
        "anchor apple generic and certificate leaf[subject.OU] = \"TEAMID\" and identifier \"com.mavoid.zoidlockin\""

    public static func resolvedTeamIdentifier(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let trimmed = environment[teamIdentifierEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return teamIdentifierPlaceholder
    }

    public static func xpcClientRequirement(teamID: String) -> String {
        CodeRequirement(
            teamID: teamID,
            identifier: applicationBundleIdentifier
        ).requirementString
    }

    public static func xpcDaemonRequirement(teamID: String) -> String {
        CodeRequirement(
            teamID: teamID,
            identifier: daemonLabel
        ).requirementString
    }
}
