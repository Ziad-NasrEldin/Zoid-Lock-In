import Foundation

/// Pure domain suffix matcher used by the Network Extension content filter.
///
/// Hostnames are compared case-insensitively against configured blacklisted and
/// whitelisted suffixes. Whitelist entries take precedence so temporary amenity
/// passes can unblock specific destinations without disabling the full shield.
public struct DomainFilterRules: Sendable, Equatable {
    public let blacklistedSuffixes: [String]
    public let whitelistedSuffixes: [String]

    public static let defaultBlacklist: [String] = [
        "youtube.com",
        "youtu.be",
        "reddit.com",
        "facebook.com",
        "instagram.com",
        "twitter.com",
        "x.com",
        "tiktok.com",
        "twitch.tv",
        "netflix.com",
        "talabat.com",
        "deliveroo.com",
        "ubereats.com",
        "elmenus.com",
    ]

    public init(
        blacklistedSuffixes: [String] = DomainFilterRules.defaultBlacklist,
        whitelistedSuffixes: [String] = []
    ) {
        self.blacklistedSuffixes = blacklistedSuffixes.map(Self.normalize)
        self.whitelistedSuffixes = whitelistedSuffixes.map(Self.normalize)
    }

    /// Evaluates an outbound hostname and returns allow or drop.
    public func verdict(forHostname hostname: String?) -> FilterVerdict {
        guard let hostname, !hostname.isEmpty else {
            return .allow
        }

        let normalized = Self.normalize(hostname)

        if matches(normalized, against: whitelistedSuffixes) {
            return .allow
        }

        if matches(normalized, against: blacklistedSuffixes) {
            return .drop
        }

        return .allow
    }

    /// Returns true when the hostname matches any blacklisted suffix and is not whitelisted.
    public func shouldBlock(hostname: String?) -> Bool {
        verdict(forHostname: hostname) == .drop
    }

    public func withWhitelist(_ suffixes: [String]) -> DomainFilterRules {
        DomainFilterRules(
            blacklistedSuffixes: blacklistedSuffixes,
            whitelistedSuffixes: suffixes
        )
    }

    private func matches(_ hostname: String, against suffixes: [String]) -> Bool {
        suffixes.contains { suffix in
            hostname == suffix || hostname.hasSuffix("." + suffix)
        }
    }

    private static func normalize(_ value: String) -> String {
        var normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while normalized.hasPrefix(".") {
            normalized.removeFirst()
        }
        return normalized
    }
}
