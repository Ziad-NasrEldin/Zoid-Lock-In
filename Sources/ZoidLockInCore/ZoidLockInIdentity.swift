import Foundation
import Security

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

    /// Ubiquitous iCloud Drive container for encrypted `state.json` (Slice 5).
    public static let ubiquityContainerIdentifier = "iCloud.com.mavoid.zoidlockin"

    /// Finder / iCloud Drive folder name for the ubiquitous container.
    public static let ubiquitousDirectoryName = "iCloud~com~mavoid~zoidlockin"

    /// Environment variable that replaces the `TEAMID` placeholder at runtime.
    /// The value must be a sanitized 10-character Team ID; anything else is ignored.
    public static let teamIdentifierEnvironmentVariable = "ZOID_LOCK_IN_TEAM_ID"

    /// Placeholder used until a real Apple Developer Team ID is supplied.
    public static let teamIdentifierPlaceholder = "TEAMID"

    /// Team-ID-pinned client requirement template. Do not implement
    /// `anchor apple generic` without `certificate leaf[subject.OU]`.
    /// This string is documentation; always go through `xpcClientRequirement(teamID:)`.
    public static let xpcClientRequirementTemplate =
        "anchor apple generic and certificate leaf[subject.OU] = \"TEAMID\" and identifier \"com.mavoid.zoidlockin\""

    public static func resolvedTeamIdentifier(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        ownTeamIdentifier: String? = nil,
        queryOwnSignature: Bool = true
    ) -> String {
        let trimmed = environment[teamIdentifierEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, let sanitized = CodeRequirement.sanitizedTeamIdentifier(trimmed),
           sanitized != teamIdentifierPlaceholder {
            return sanitized
        }

        if let ownTeamIdentifier, let sanitized = CodeRequirement.sanitizedTeamIdentifier(ownTeamIdentifier),
           sanitized != teamIdentifierPlaceholder {
            return sanitized
        }

        if queryOwnSignature,
           let signed = teamIdentifierFromOwnCodeSignature(),
           let sanitized = CodeRequirement.sanitizedTeamIdentifier(signed),
           sanitized != teamIdentifierPlaceholder {
            return sanitized
        }

        return teamIdentifierPlaceholder
    }

    /// Reads the Team ID from this process's code signature via `SecCodeCopySelf`.
    /// Returns nil when unsigned, ad-hoc, or the Team ID is missing / malformed.
    public static func teamIdentifierFromOwnCodeSignature() -> String? {
        var code: SecCode?
        let selfStatus = SecCodeCopySelf([], &code)
        guard selfStatus == errSecSuccess, let code else {
            return nil
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return nil
        }

        var information: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard infoStatus == errSecSuccess,
              let info = information as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String else {
            return nil
        }

        return CodeRequirement.sanitizedTeamIdentifier(team)
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

    public static func xpcFilterQueryRequirement(teamID: String) -> String {
        CodeRequirement(
            teamID: teamID,
            identifier: filterSystemExtensionBundleIdentifier
        ).requirementString
    }
}
