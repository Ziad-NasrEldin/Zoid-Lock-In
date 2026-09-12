import Foundation

/// Matches running process names and executable paths against distraction binaries.
///
/// Matching uses the process comm name **and** `proc_pidpath` so helpers that
/// live inside a launcher `.app` bundle are visible even when `proc_name` is
/// truncated. This is a backstop, not a code-signature control.
public struct ProcessTargetMatcher: Sendable, Equatable {
    public let targetNames: [String]

    public static let defaultTargets: [String] = [
        "Steam",
        "steam_osx",
        "steamwebhelper",
        "steamhelper",
        "Discord",
        "Discord Canary",
        "Discord PTB",
        "Discord Helper",
        "Discord Canary Helper",
        "Discord PTB Helper",
        "Battle.net",
        "Battle.net Helper",
        "Epic Games Launcher",
        "EpicGamesLauncher",
        "Riot Client",
        "RiotClientServices",
        "LeagueClient",
        "League of Legends",
        "wine",
        "wine64",
        "wine64-preloader",
        "wine-preloader",
        "wineserver",
        "wineloader",
        "winedevice.exe",
        "CrossOver",
        "Whisky",
        "game-porting-toolkit",
        "gptk",
    ]

    public init(targetNames: [String] = ProcessTargetMatcher.defaultTargets) {
        self.targetNames = targetNames.map(Self.normalize)
    }

    /// Returns true when `processName` matches a configured target binary.
    public func matches(processName: String) -> Bool {
        matches(processName: processName, executablePath: nil)
    }

    /// Returns true when the process name or executable path matches a target.
    public func matches(processName: String, executablePath: String?) -> Bool {
        if matchesName(processName) {
            return true
        }

        if let executablePath, matches(executablePath: executablePath) {
            return true
        }

        return false
    }

    /// Filters a list of process names down to those that should be terminated.
    public func matchingProcesses(in processNames: [String]) -> [String] {
        processNames.filter(matches(processName:))
    }

    private func matchesName(_ processName: String) -> Bool {
        let normalized = Self.normalize(processName)
        guard !normalized.isEmpty else { return false }
        let basename = Self.lastPathComponent(normalized)
        return targetNames.contains { target in
            Self.name(basename, matches: target) || Self.name(normalized, matches: target)
        }
    }

    private func matches(executablePath: String) -> Bool {
        let normalizedPath = Self.normalize(executablePath)
        guard !normalizedPath.isEmpty else { return false }

        let basename = Self.lastPathComponent(normalizedPath)
        if matchesName(basename) {
            return true
        }

        return targetNames.contains { target in
            let bundleNeedle = "/\(target).app/"
            return normalizedPath.contains(bundleNeedle)
        }
    }

    private static func name(_ value: String, matches target: String) -> Bool {
        if value == target {
            return true
        }

        // Electron / Chromium helpers: "discord helper (renderer)"
        if value.hasPrefix(target + " helper") {
            return true
        }

        return false
    }

    private static func lastPathComponent(_ value: String) -> String {
        let slash = value.split(separator: "/").last.map(String.init) ?? value
        return slash.split(separator: "\\").last.map(String.init) ?? slash
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
