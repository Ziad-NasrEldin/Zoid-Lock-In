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

    @Test("matches launcher helpers, Discord channels, and Wine/GPTK wrappers")
    func matchesHelpersAndWrappers() {
        #expect(matcher.matches(processName: "steamwebhelper"))
        #expect(matcher.matches(processName: "Discord Canary"))
        #expect(matcher.matches(processName: "Discord PTB"))
        #expect(matcher.matches(processName: "Discord Helper (Renderer)"))
        #expect(matcher.matches(processName: "wine64"))
        #expect(matcher.matches(processName: "wineserver"))
        #expect(matcher.matches(processName: "wine64-preloader"))
        #expect(matcher.matches(processName: "Whisky"))
        #expect(matcher.matches(processName: "game-porting-toolkit"))
    }

    @Test("matches executable paths and app-bundle paths from proc_pidpath")
    func matchesExecutablePaths() {
        #expect(
            matcher.matches(
                processName: "steamwebhelper",
                executablePath: "/Applications/Steam.app/Contents/MacOS/steamwebhelper"
            )
        )
        #expect(
            matcher.matches(
                processName: "Helper",
                executablePath: "/Applications/Steam.app/Contents/MacOS/steamwebhelper"
            )
        )
        #expect(
            matcher.matches(
                processName: "dota2",
                executablePath: "/Applications/Steam.app/Contents/MacOS/dota2"
            )
        )
        #expect(
            matcher.matches(
                processName: "Game",
                executablePath: "/Users/me/Library/Application Support/Steam/steamapps/common/SomeTitle/Game"
            )
        )
        #expect(
            matcher.matches(
                processName: "dota2",
                executablePath: "/Users/me/Library/Application Support/Steam/steamapps/common/dota 2 beta/dota2"
            )
        )
        #expect(
            matcher.matches(
                processName: "cs2",
                executablePath: "/Users/me/Library/Application Support/Steam/steamapps/common/Counter-Strike Global Offensive/cs2"
            )
        )
        #expect(
            matcher.matches(
                processName: "hl2_osx",
                executablePath: "/Users/me/Library/Application Support/Steam/steamapps/common/Half-Life 2/hl2_osx"
            )
        )
        #expect(
            matcher.matches(
                processName: "World of Warcraft",
                executablePath: "/Applications/World of Warcraft/_retail_/World of Warcraft.app/Contents/MacOS/World of Warcraft"
            )
        )
        #expect(
            matcher.matches(
                processName: "Discord Canary",
                executablePath: "/Applications/Discord Canary.app/Contents/MacOS/Discord Canary"
            )
        )
        #expect(
            matcher.matches(
                processName: "wine64",
                executablePath: "/usr/local/bin/wine64"
            )
        )
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

        #expect(
            !matcher.matches(
                processName: "cli",
                executablePath: "/Users/you/src/steam-tools/cli"
            )
        )
        #expect(
            !matcher.matches(
                processName: "Notes",
                executablePath: "/Users/me/bin/Notes"
            )
        )
    }

    @Test("filters a process list down to targets only")
    func filtersProcessList() {
        let running = ["Finder", "Steam", "Safari", "Discord", "Xcode"]
        #expect(matcher.matchingProcesses(in: running) == ["Steam", "Discord"])
    }
}
