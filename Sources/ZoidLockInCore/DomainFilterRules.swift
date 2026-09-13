import Foundation

/// Pure domain suffix matcher used by the Network Extension content filter.
///
/// Hostnames are compared case-insensitively against configured blacklisted and
/// whitelisted suffixes. Whitelist entries take precedence so temporary amenity
/// passes can unblock specific destinations without disabling the full shield.
///
/// Missing, empty, or IP-literal hostnames are **unverified**. Callers that
/// invoke this matcher for inspected ports must treat `.drop` as fail-closed.
public struct DomainFilterRules: Sendable, Equatable {
    public let blacklistedSuffixes: [String]
    public let whitelistedSuffixes: [String]

    public static let foodDeliverySuffixes: [String] = [
        "talabat.com",
        "deliveroo.com",
        "ubereats.com",
        "elmenus.com",
    ]

    public static let communicationSuffixes: [String] = [
        "whatsapp.com",
        "web.whatsapp.com",
        "telegram.org",
        "t.me",
    ]

    public static let streamingSuffixes: [String] = [
        "youtube.com",
        "youtu.be",
        "googlevideo.com",
        "ytimg.com",
        "yt3.ggpht.com",
        "netflix.com",
        "nflxvideo.net",
        "nflxext.com",
        "nflximg.net",
        "twitch.tv",
        "ttvnw.net",
        "jtvnw.net",
    ]

    /// Media delivery CDNs that carry bits after the marketing hostname is blocked.
    public static let mediaDeliverySuffixes: [String] = [
        "googlevideo.com",
        "ytimg.com",
        "yt3.ggpht.com",
        "nflxvideo.net",
        "nflxext.com",
        "nflximg.net",
        "ttvnw.net",
        "jtvnw.net",
        "cdninstagram.com",
        "fbcdn.net",
        "redditstatic.com",
        "redditmedia.com",
    ]

    public static let defaultBlacklist: [String] = [
        "youtube.com",
        "youtu.be",
        "googlevideo.com",
        "ytimg.com",
        "yt3.ggpht.com",
        "reddit.com",
        "redditstatic.com",
        "redditmedia.com",
        "facebook.com",
        "instagram.com",
        "cdninstagram.com",
        "fbcdn.net",
        "twitter.com",
        "x.com",
        "tiktok.com",
        "twitch.tv",
        "ttvnw.net",
        "jtvnw.net",
        "netflix.com",
        "nflxvideo.net",
        "nflxext.com",
        "nflximg.net",
        "talabat.com",
        "deliveroo.com",
        "ubereats.com",
        "elmenus.com",
        "whatsapp.com",
        "web.whatsapp.com",
        "telegram.org",
        "t.me",
    ]

    public init(
        blacklistedSuffixes: [String] = DomainFilterRules.defaultBlacklist,
        whitelistedSuffixes: [String] = []
    ) {
        self.blacklistedSuffixes = blacklistedSuffixes.map(Self.normalize)
        self.whitelistedSuffixes = whitelistedSuffixes.map(Self.normalize)
    }

    /// Evaluates an outbound hostname and returns allow or drop.
    ///
    /// Unverified identities (nil, empty, trailing-dot-only, IP literals) drop.
    public func verdict(forHostname hostname: String?) -> FilterVerdict {
        guard let hostname = Self.verifiedHostname(hostname) else {
            return .drop
        }

        if matches(hostname, against: whitelistedSuffixes) {
            return .allow
        }

        if matches(hostname, against: blacklistedSuffixes) {
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

    /// Unions extra suffixes onto the existing whitelist (kind-scoped passes).
    public func allowing(suffixes: [String]) -> DomainFilterRules {
        DomainFilterRules(
            blacklistedSuffixes: blacklistedSuffixes,
            whitelistedSuffixes: whitelistedSuffixes + suffixes
        )
    }

    /// Normalized hostname if it is a usable DNS name; otherwise nil (unverified).
    public static func verifiedHostname(_ hostname: String?) -> String? {
        guard let hostname else { return nil }

        let normalized = normalize(hostname)
        guard !normalized.isEmpty else { return nil }
        if isIPLiteral(normalized) { return nil }
        return normalized
    }

    private func matches(_ hostname: String, against suffixes: [String]) -> Bool {
        suffixes.contains { suffix in
            hostname == suffix || hostname.hasSuffix("." + suffix)
        }
    }

    static func normalize(_ value: String) -> String {
        var normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while normalized.hasPrefix(".") {
            normalized.removeFirst()
        }
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func isIPLiteral(_ value: String) -> Bool {
        let host: String
        if value.hasPrefix("["), value.hasSuffix("]"), value.count > 2 {
            host = String(value.dropFirst().dropLast())
        } else {
            host = value
        }

        if isIPv4Literal(host) {
            return true
        }

        return host.contains(":")
    }

    private static func isIPv4Literal(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }

        return parts.allSatisfy { part in
            let text = String(part)
            guard let octet = UInt8(text), String(octet) == text else {
                return false
            }
            return true
        }
    }
}
