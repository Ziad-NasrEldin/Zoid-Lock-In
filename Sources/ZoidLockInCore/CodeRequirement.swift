import Foundation

/// Team-ID-pinned designated requirement used to authenticate XPC peers.
///
/// `anchor apple generic` without `certificate leaf[subject.OU]` is rejected:
/// that form matches any Apple-issued Developer ID and is a confused-deputy hole.
public struct CodeRequirement: Sendable, Equatable {
    public var teamID: String
    public var identifier: String

    public init(teamID: String, identifier: String) {
        self.teamID = teamID
        self.identifier = identifier
    }

    public var requirementString: String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(identifier)\""
    }

    /// True when `requirement` pins Team ID via `certificate leaf[subject.OU]`.
    public static func isTeamIDPinned(_ requirement: String) -> Bool {
        requirement.contains("anchor apple generic")
            && requirement.contains("certificate leaf[subject.OU]")
            && requirement.contains("identifier \"")
    }
}
