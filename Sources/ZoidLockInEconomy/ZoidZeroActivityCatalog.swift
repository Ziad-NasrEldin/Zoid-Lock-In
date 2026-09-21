import Foundation

/// Mirrors Zoid 0 ActivityCategory. Only work mints Lock In focus credits.
public enum ZoidZeroActivityCategory: String, Codable, CaseIterable, Equatable, Sendable {
    case work
    case communication
    case social
    case gaming
    case media
    case utilities
    case browser
    case uncategorized

    public var isProductive: Bool { self == .work }
}

public enum ZoidZeroActivitySubject: Hashable, Sendable {
    case application(bundleIdentifier: String)
    case website(domain: String)
}

/// Source of truth for productive focus: Zoid 0 defaults, live user
/// recategorizations from Application Support/ZoidZero/store.json, and
/// Lock In work tools that are not yet in Zoid 0 defaults.
public final class ZoidZeroActivityCatalog: @unchecked Sendable {
    public static let shared = ZoidZeroActivityCatalog()

    public static let defaultStoreURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ZoidZero", isDirectory: true)
        .appendingPathComponent("store.json")

    public static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "org.mozilla.firefox"
    ]

    /// Exact copy of Zoid 0 DefaultActivityCategories.assignments.
    public static let defaultAssignments: [ZoidZeroActivitySubject: ZoidZeroActivityCategory] = [
        .application(bundleIdentifier: "com.apple.Safari"): .browser,
        .application(bundleIdentifier: "com.google.Chrome"): .browser,
        .application(bundleIdentifier: "company.thebrowser.Browser"): .browser,
        .application(bundleIdentifier: "org.mozilla.firefox"): .browser,
        .application(bundleIdentifier: "com.apple.dt.Xcode"): .work,
        .application(bundleIdentifier: "com.apple.Terminal"): .work,
        .application(bundleIdentifier: "com.openai.chat"): .work,
        .application(bundleIdentifier: "com.tinyspeck.slackmacgap"): .communication,
        .application(bundleIdentifier: "net.whatsapp.WhatsApp"): .communication,
        .application(bundleIdentifier: "com.apple.mail"): .communication,
        .application(bundleIdentifier: "com.apple.MobileSMS"): .communication,
        .application(bundleIdentifier: "com.valvesoftware.steam"): .gaming,
        .application(bundleIdentifier: "com.spotify.client"): .media,
        .application(bundleIdentifier: "com.apple.Music"): .media,
        .application(bundleIdentifier: "com.apple.finder"): .utilities,
        .application(bundleIdentifier: "com.apple.systempreferences"): .utilities,
        .application(bundleIdentifier: "com.apple.systemsettings"): .utilities,
        .website(domain: "github.com"): .work,
        .website(domain: "notion.so"): .work,
        .website(domain: "figma.com"): .work,
        .website(domain: "linear.app"): .work,
        .website(domain: "slack.com"): .communication,
        .website(domain: "whatsapp.com"): .communication,
        .website(domain: "reddit.com"): .social,
        .website(domain: "x.com"): .social,
        .website(domain: "facebook.com"): .social,
        .website(domain: "instagram.com"): .social,
        .website(domain: "youtube.com"): .media,
        .website(domain: "netflix.com"): .media,
        .website(domain: "spotify.com"): .media
    ]

    /// Work tools Lock In already tracked that Zoid 0 defaults omit.
    public static let lockInWorkBundlePrefixes: Set<String> = [
        "com.todesktop.230313mzl4w4u92",
        "com.microsoft.VSCode",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.sublimetext",
        "md.obsidian",
        "notion.id",
        "com.linear",
        "com.figma.Desktop",
        "com.github.GitHubClient",
        "com.fournova.Tower",
        "com.microsoft.teams2",
        "com.openai.codex"
    ]

    private let lock = NSLock()
    private let storeURL: URL
    private var userAssignments: [ZoidZeroActivitySubject: ZoidZeroActivityCategory] = [:]
    private var lastLoadedAt: Date?
    private let reloadInterval: TimeInterval

    public init(
        storeURL: URL = ZoidZeroActivityCatalog.defaultStoreURL,
        reloadInterval: TimeInterval = 5
    ) {
        self.storeURL = storeURL
        self.reloadInterval = reloadInterval
        reloadUserAssignments()
    }

    public func reloadIfNeeded(force: Bool = false, now: Date = Date()) {
        lock.lock()
        let due = lastLoadedAt.map { now.timeIntervalSince($0) >= reloadInterval } ?? true
        lock.unlock()
        guard force || due else { return }
        reloadUserAssignments(at: now)
    }

    public func category(for subject: ZoidZeroActivitySubject) -> ZoidZeroActivityCategory {
        reloadIfNeeded()
        lock.lock()
        let user = userAssignments[subject]
        lock.unlock()
        if let user { return user }
        if let exact = Self.defaultAssignments[subject] { return exact }
        switch subject {
        case .application(let bundleIdentifier):
            if let prefixed = Self.defaultAssignment(matchingBundle: bundleIdentifier) {
                return prefixed
            }
            if Self.lockInWorkBundlePrefixes.contains(where: { bundleIdentifier.hasPrefix($0) }) {
                return .work
            }
            return .uncategorized
        case .website(let domain):
            return Self.defaultWebsiteCategory(for: domain) ?? .uncategorized
        }
    }

    public func isBrowser(_ bundleIdentifier: String) -> Bool {
        Self.browserBundleIdentifiers.contains(where: { bundleIdentifier.hasPrefix($0) })
            || category(for: .application(bundleIdentifier: bundleIdentifier)) == .browser
    }

    public func isProductive(bundleIdentifier: String, domain: String? = nil) -> Bool {
        if isBrowser(bundleIdentifier) {
            guard let domain, !domain.isEmpty else { return false }
            return category(for: .website(domain: domain)).isProductive
        }
        return category(for: .application(bundleIdentifier: bundleIdentifier)).isProductive
    }

    public static func normalizedDomain(from address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let host = URL(string: trimmed)?.host, !host.isEmpty {
            return registrableDomain(from: host.lowercased())
        }
        if trimmed.contains("."), !trimmed.contains(" ") {
            return registrableDomain(from: trimmed.lowercased())
        }
        return nil
    }

    private static func registrableDomain(from host: String) -> String {
        var labels = host.split(separator: ".").map(String.init)
        if labels.first == "www" { labels.removeFirst() }
        guard labels.count >= 2 else { return labels.joined(separator: ".") }
        return labels.suffix(2).joined(separator: ".")
    }

    private static func defaultAssignment(matchingBundle bundleIdentifier: String) -> ZoidZeroActivityCategory? {
        for (subject, category) in defaultAssignments {
            if case .application(let prefix) = subject, bundleIdentifier.hasPrefix(prefix) {
                return category
            }
        }
        return nil
    }

    private static func defaultWebsiteCategory(for domain: String) -> ZoidZeroActivityCategory? {
        let normalized = registrableDomain(from: domain.lowercased())
        for (subject, category) in defaultAssignments {
            if case .website(let listed) = subject {
                if normalized == listed || normalized.hasSuffix("." + listed) || domain.hasSuffix(listed) {
                    return category
                }
            }
        }
        return nil
    }

    private func reloadUserAssignments(at now: Date = Date()) {
        let parsed = Self.parseUserAssignments(at: storeURL)
        lock.lock()
        userAssignments = parsed
        lastLoadedAt = now
        lock.unlock()
    }

    public static func parseUserAssignments(at url: URL) -> [ZoidZeroActivitySubject: ZoidZeroActivityCategory] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["categoryAssignments"] as? [Any]
        else {
            return [:]
        }

        var result: [ZoidZeroActivitySubject: ZoidZeroActivityCategory] = [:]
        var index = 0
        while index + 1 < raw.count {
            defer { index += 2 }
            guard let categoryName = raw[index + 1] as? String,
                  let category = ZoidZeroActivityCategory(rawValue: categoryName),
                  let key = raw[index] as? [String: Any]
            else { continue }
            if let application = key["application"] as? [String: Any],
               let bundle = application["bundleIdentifier"] as? String {
                result[.application(bundleIdentifier: bundle)] = category
            } else if let website = key["website"] as? [String: Any],
                      let domain = website["domain"] as? String {
                result[.website(domain: domain)] = category
            }
        }
        return result
    }
}

