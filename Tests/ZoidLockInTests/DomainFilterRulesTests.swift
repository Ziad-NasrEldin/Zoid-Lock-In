import Foundation
import Testing
import ZoidLockInCore

@Suite("Domain filter rules")
struct DomainFilterRulesTests {
    let rules = DomainFilterRules()

    @Test("drops blacklisted hostnames from the Slice 1 blocklist")
    func dropsBlacklistedHostnames() {
        let blocked = [
            "youtube.com",
            "www.youtube.com",
            "m.youtube.com",
            "googlevideo.com",
            "r3.sn-abc.googlevideo.com",
            "talabat.com",
            "www.talabat.com",
            "deliveroo.com",
            "twitter.com",
            "mobile.twitter.com",
            "x.com",
            "www.x.com",
            "reddit.com",
            "redditstatic.com",
            "ubereats.com",
            "elmenus.com",
            "nflxvideo.net",
            "ttvnw.net",
            "cdninstagram.com",
            "fbcdn.net",
        ]

        for hostname in blocked {
            #expect(
                rules.verdict(forHostname: hostname) == .drop,
                "Expected drop for \(hostname)"
            )
        }
    }

    @Test("allows non-blacklisted hostnames")
    func allowsNonBlacklistedHostnames() {
        let allowed = [
            "apple.com",
            "github.com",
            "docs.swift.org",
            "mavoid.com",
            "developer.apple.com",
        ]

        for hostname in allowed {
            #expect(
                rules.verdict(forHostname: hostname) == .allow,
                "Expected allow for \(hostname)"
            )
        }
    }

    @Test("whitelist overrides blacklist for temporary amenity passes")
    func whitelistOverridesBlacklist() {
        let passRules = rules.withWhitelist(["youtube.com", "talabat.com"])

        #expect(passRules.verdict(forHostname: "www.youtube.com") == .allow)
        #expect(passRules.verdict(forHostname: "order.talabat.com") == .allow)
        #expect(passRules.verdict(forHostname: "reddit.com") == .drop)
    }

    @Test("treats hostnames case-insensitively and strips leading and trailing dots")
    func normalizesHostnames() {
        #expect(rules.verdict(forHostname: "YouTube.COM") == .drop)
        #expect(rules.verdict(forHostname: ".x.com") == .drop)
        #expect(rules.verdict(forHostname: "  Twitter.Com ") == .drop)
        #expect(rules.verdict(forHostname: "youtube.com.") == .drop)
        #expect(rules.verdict(forHostname: "www.youtube.com.") == .drop)
        #expect(rules.verdict(forHostname: "youtube.com...") == .drop)
    }

    @Test("drops nil, empty, or IP-literal hostnames (fail-closed)")
    func dropsUnverifiedHostnames() {
        #expect(rules.verdict(forHostname: nil) == .drop)
        #expect(rules.verdict(forHostname: "") == .drop)
        #expect(rules.verdict(forHostname: ".") == .drop)
        #expect(rules.verdict(forHostname: "   ") == .drop)
        #expect(rules.verdict(forHostname: "142.250.72.14") == .drop)
        #expect(rules.verdict(forHostname: "2001:4860:4860::8888") == .drop)
        #expect(rules.verdict(forHostname: "[2001:4860:4860::8888]") == .drop)
        #expect(DomainFilterRules.verifiedHostname(nil) == nil)
        #expect(DomainFilterRules.verifiedHostname("") == nil)
        #expect(DomainFilterRules.verifiedHostname("8.8.8.8") == nil)
        #expect(DomainFilterRules.verifiedHostname("youtube.com.") == "youtube.com")
    }
}
