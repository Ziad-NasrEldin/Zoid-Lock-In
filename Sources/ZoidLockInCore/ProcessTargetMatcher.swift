import Foundation

/// Matches running process names / bundle identifiers against distraction binaries.
public struct ProcessTargetMatcher: Sendable, Equatable {
    public let targetNames: [String]

    public static let defaultTargets: [String] = [
        "Steam",
        "steam_osx",
        "Discord",
        "Battle.net",
        "Battle.net Helper",
        "Epic Games Launcher",
        "EpicGamesLauncher",
        "Riot Client",
        "RiotClientServices",
        "LeagueClient",
        "League of Legends",
    ]

    public init(targetNames: [String] = ProcessTargetMatcher.defaultTargets) {
        self.targetNames = targetNames.map(Self.normalize)
    }

    /// Returns true when `processName` matches a configured target binary.
    public func matches(processName: String) -> Bool {
        let normalized = Self.normalize(processName)
        guard !normalized.isEmpty else { return false }

        return targetNames.contains { target in
            normalized == target
                || normalized.hasPrefix(target + " ")
                || normalized.hasSuffix(" " + target)
                || normalized.contains("/" + target)
        }
    }

    /// Filters a list of process names down to those that should be terminated.
    public func matchingProcesses(in processNames: [String]) -> [String] {
        processNames.filter(matches(processName:))
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
