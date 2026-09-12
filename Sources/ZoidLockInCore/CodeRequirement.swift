import Foundation

/// Team-ID-pinned designated requirement used to authenticate XPC peers.
///
/// `anchor apple generic` without `certificate leaf[subject.OU]` is rejected:
/// that form matches any Apple-issued Developer ID and is a confused-deputy hole.
///
/// `teamID` and `identifier` are sanitized before interpolation. Anything that
/// is not a 10-character Apple Team ID (or the unsigned-dev placeholder `TEAMID`)
/// is replaced with a never-matching token so requirement-language injection
/// cannot widen the admitted set.
public struct CodeRequirement: Sendable, Equatable {
    public var teamID: String
    public var identifier: String

    public init(teamID: String, identifier: String) {
        self.teamID = teamID
        self.identifier = identifier
    }

    public var requirementString: String {
        let team = Self.sanitizedTeamIdentifier(teamID) ?? "INVALID"
        let ident = Self.sanitizedCodeIdentifier(identifier) ?? "invalid"
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(ident)\""
    }

    /// Apple Team IDs are exactly 10 uppercase alphanumeric characters.
    /// `TEAMID` is allowed only as the unsigned / test placeholder.
    public static func sanitizedTeamIdentifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == ZoidLockInIdentity.teamIdentifierPlaceholder {
            return trimmed
        }
        guard trimmed.count == 10 else { return nil }

        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    /// Reverse-DNS bundle identifiers: alphanumerics, `.`, and `-` only.
    public static func sanitizedCodeIdentifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 255 else { return nil }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    /// True when `requirement` is exactly a Team-ID-pinned designated requirement
    /// with no extra `or` clauses or interpolated operators.
    public static func isTeamIDPinned(_ requirement: String) -> Bool {
        guard !requirement.localizedCaseInsensitiveContains(" or ") else {
            return false
        }

        let pattern =
            #"^anchor apple generic and certificate leaf\[subject\.OU\] = "(TEAMID|[A-Z0-9]{10})" and identifier "[A-Za-z0-9.-]+"$"#
        return requirement.range(of: pattern, options: .regularExpression) != nil
    }
}
