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
            "talabat.com",
            "www.talabat.com",
            "deliveroo.com",
            "twitter.com",
            "mobile.twitter.com",
            "x.com",
            "www.x.com",
            "reddit.com",
            "ubereats.com",
            "elmenus.com",
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

    @Test("treats hostnames case-insensitively and ignores leading dots")
    func normalizesHostnames() {
        #expect(rules.verdict(forHostname: "YouTube.COM") == .drop)
        #expect(rules.verdict(forHostname: ".x.com") == .drop)
        #expect(rules.verdict(forHostname: "  Twitter.Com ") == .drop)
    }

    @Test("allows nil or empty hostnames")
    func allowsMissingHostnames() {
        #expect(rules.verdict(forHostname: nil) == .allow)
        #expect(rules.verdict(forHostname: "") == .allow)
    }
}
