import Foundation
import Testing
import ZoidLockInCore

@Suite("Process target matcher")
struct ProcessTargetMatcherTests {
    let matcher = ProcessTargetMatcher()

    @Test("matches Steam and Discord distraction binaries")
    func matchesSteamAndDiscord() {
        #expect(matcher.matches(processName: "Steam"))
        #expect(matcher.matches(processName: "steam_osx"))
        #expect(matcher.matches(processName: "Discord"))
        #expect(matcher.matches(processName: "discord"))
    }

    @Test("matches game launcher family binaries")
    func matchesGameLaunchers() {
        #expect(matcher.matches(processName: "Battle.net"))
        #expect(matcher.matches(processName: "Epic Games Launcher"))
        #expect(matcher.matches(processName: "EpicGamesLauncher"))
        #expect(matcher.matches(processName: "RiotClientServices"))
        #expect(matcher.matches(processName: "LeagueClient"))
    }

    @Test("does not match productive or unrelated binaries")
    func ignoresNonTargets() {
        let safe = [
            "Xcode",
            "Cursor",
            "Safari",
            "Terminal",
            "Code",
            "Finder",
            "WindowServer",
            "zsh",
        ]

        for name in safe {
            #expect(!matcher.matches(processName: name), "Unexpected match for \(name)")
        }
    }

    @Test("filters a process list down to targets only")
    func filtersProcessList() {
        let running = ["Finder", "Steam", "Safari", "Discord", "Xcode"]
        #expect(matcher.matchingProcesses(in: running) == ["Steam", "Discord"])
    }
}
