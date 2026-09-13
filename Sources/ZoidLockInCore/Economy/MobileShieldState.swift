import Foundation

/// One amenity window mirrored onto paired iOS devices.
public struct MobilePassRecord: Sendable, Equatable, Codable, Identifiable {
    public var kind: PassKind
    public var expiresAtUtc: Date
    public var remainingDurationSeconds: Int
    public var localRelockDurationSeconds: Int

    public var id: PassKind { kind }

    enum CodingKeys: String, CodingKey {
        case kind
        case expiresAtUtc
        case remainingDurationSeconds
        case localRelockDurationSeconds
    }

    public init(
        kind: PassKind,
        expiresAtUtc: Date,
        remainingDurationSeconds: Int,
        localRelockDurationSeconds: Int? = nil
    ) {
        self.kind = kind
        self.expiresAtUtc = MobileShieldCoding.normalize(expiresAtUtc)
        self.remainingDurationSeconds = max(0, remainingDurationSeconds)
        self.localRelockDurationSeconds = max(
            0,
            localRelockDurationSeconds ?? remainingDurationSeconds
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(PassKind.self, forKey: .kind)
        expiresAtUtc = try container.decode(Date.self, forKey: .expiresAtUtc)
        remainingDurationSeconds = max(0, try container.decode(Int.self, forKey: .remainingDurationSeconds))
        localRelockDurationSeconds = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .localRelockDurationSeconds)
                ?? remainingDurationSeconds
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(expiresAtUtc, forKey: .expiresAtUtc)
        try container.encode(remainingDurationSeconds, forKey: .remainingDurationSeconds)
        try container.encode(localRelockDurationSeconds, forKey: .localRelockDurationSeconds)
    }

    public func remaining(at now: Date) -> Int {
        max(
            0,
            min(
                remainingDurationSeconds,
                Int(expiresAtUtc.timeIntervalSince(now).rounded(.towardZero))
            )
        )
    }

    public func isLive(at now: Date) -> Bool {
        remaining(at: now) > 0
    }
}

/// Encrypted cross-device snapshot written to isolated Application Support `state.json`.
public struct MobileShieldState: Sendable, Equatable, Codable {
    public var sessionActive: Bool
    public var activePasses: [MobilePassRecord]
    public var sequenceNumber: UInt64
    public var timestamp: Date
    public var streakDays: Int
    public var balanceCredits: Double

    public static let empty = MobileShieldState(
        sessionActive: false,
        activePasses: [],
        sequenceNumber: 0,
        timestamp: Date(timeIntervalSince1970: 0),
        streakDays: 0,
        balanceCredits: 0
    )

    public init(
        sessionActive: Bool,
        activePasses: [MobilePassRecord],
        sequenceNumber: UInt64,
        timestamp: Date,
        streakDays: Int,
        balanceCredits: Double,
        now: Date? = nil
    ) {
        self.sessionActive = sessionActive
        self.activePasses = Self.normalizedPasses(activePasses, now: now)
        self.sequenceNumber = sequenceNumber
        self.timestamp = MobileShieldCoding.normalize(timestamp)
        self.streakDays = max(0, streakDays)
        self.balanceCredits = CreditMath.normalize(balanceCredits)
    }

    public var mobilePassKinds: [PassKind] {
        activePasses.map(\.kind).filter(\.isMobileShieldPass)
    }

    public var hasMobilePass: Bool {
        activePasses.contains { $0.kind.isMobileShieldPass && $0.remainingDurationSeconds > 0 }
    }

    public var hasEmergencyPass: Bool {
        activePasses.contains { $0.kind == .emergency && $0.remainingDurationSeconds > 0 }
    }

    public var primaryMobilePass: MobilePassRecord? {
        activePasses
            .filter { $0.kind.isMobileShieldPass && $0.remainingDurationSeconds > 0 }
            .min { lhs, rhs in
                if lhs.remainingDurationSeconds != rhs.remainingDurationSeconds {
                    return lhs.remainingDurationSeconds < rhs.remainingDurationSeconds
                }
                return lhs.kind < rhs.kind
            }
    }

    /// Sequence is strictly authoritative. Wall-clock timestamps are a
    /// tie-breaker only. A poisoned future timestamp with a lower sequence loses.
    public func wins(over other: MobileShieldState) -> Bool {
        if sequenceNumber != other.sequenceNumber {
            return sequenceNumber > other.sequenceNumber
        }
        return timestamp > other.timestamp
    }

    public static func resolve(local: MobileShieldState?, remote: MobileShieldState?) -> MobileShieldState? {
        switch (local, remote) {
        case (nil, nil):
            return nil
        case (let local?, nil):
            return local
        case (nil, let remote?):
            return remote
        case (let local?, let remote?):
            return local.wins(over: remote) ? local : remote
        }
    }

    public static func resolve(candidates: [MobileShieldState]) -> MobileShieldState? {
        candidates.reduce(into: nil as MobileShieldState?) { winner, next in
            winner = resolve(local: winner, remote: next) ?? next
        }
    }

    public func advancingSequence(to now: Date) -> MobileShieldState {
        var next = self
        next.sequenceNumber = sequenceNumber &+ 1
        let proposed = MobileShieldCoding.normalize(now)
        if proposed > timestamp {
            next.timestamp = proposed
        } else {
            next.timestamp = timestamp.addingTimeInterval(0.001)
        }
        return next
    }

    public func expiringPasses(at now: Date) -> MobileShieldState {
        MobileShieldState(
            sessionActive: sessionActive,
            activePasses: activePasses.filter { $0.isLive(at: now) },
            sequenceNumber: sequenceNumber,
            timestamp: timestamp,
            streakDays: streakDays,
            balanceCredits: balanceCredits,
            now: now
        )
    }

    private static func normalizedPasses(_ passes: [MobilePassRecord], now: Date?) -> [MobilePassRecord] {
        var unique: [PassKind: MobilePassRecord] = [:]
        for record in passes {
            if let now, !record.isLive(at: now) {
                continue
            }
            if record.remainingDurationSeconds <= 0 {
                continue
            }
            unique[record.kind] = record
        }
        return unique.values.sorted { $0.kind < $1.kind }
    }
}

/// Connection word shown in the SUMI-E marketplace / menu-bar extra.
public enum MobileShieldLink: String, Sendable, Equatable, Codable {
    case local
    case localOnly = "local_only"
    case notConfigured = "not_configured"
    case paired
    case synced

    public var caption: String {
        switch self {
        case .local, .localOnly:
            return "LOCAL ONLY"
        case .notConfigured:
            return "NOT CONFIGURED"
        case .paired:
            return "PAIRED"
        case .synced:
            return "SYNCED"
        }
    }
}

/// View-model for truthful `SHIELD:` captions. Unconfigured relays never claim PAIRED.
public struct MobileShieldStatus: Sendable, Equatable {
    public var link: MobileShieldLink
    public var sessionActive: Bool
    public var passActive: Bool
    public var relayConfigured: Bool

    public init(
        link: MobileShieldLink,
        sessionActive: Bool,
        passActive: Bool,
        relayConfigured: Bool = false
    ) {
        self.link = link
        self.sessionActive = sessionActive
        self.passActive = passActive
        self.relayConfigured = relayConfigured
    }

    public static let standby = MobileShieldStatus(
        link: .notConfigured,
        sessionActive: false,
        passActive: false,
        relayConfigured: false
    )

    public var activityCaption: String {
        if sessionActive {
            return "FOCUS ACTIVE"
        }
        if passActive {
            return "PASS ACTIVE"
        }
        return "LOCKED"
    }

    public var caption: String {
        switch link {
        case .notConfigured:
            return "SHIELD: NOT CONFIGURED"
        case .local, .localOnly:
            return "SHIELD: LOCAL ONLY"
        case .paired, .synced:
            return "SHIELD: \(link.caption) · \(activityCaption)"
        }
    }

    public static func derive(
        ticker: MenuBarTickerSnapshot,
        status: EnforcementStatus?,
        localRemaining: [AmenityKind: Int] = [:],
        link: MobileShieldLink? = nil,
        relayConfigured: Bool = false
    ) -> MobileShieldStatus {
        let sessionActive = ticker.focusState == .active || ticker.focusState == .pausedGrace
        let passFromDaemon = status?.activePasses.contains {
            $0.kind.isMobileShieldPass && $0.remainingSeconds > 0
        } ?? false
        let passFromLocal = (localRemaining[.food] ?? 0) > 0 || (localRemaining[.phone] ?? 0) > 0
        let passActive = passFromDaemon || passFromLocal
        let resolvedLink = link ?? inferredLink(
            sessionActive: sessionActive,
            passActive: passActive,
            relayConfigured: relayConfigured
        )
        return MobileShieldStatus(
            link: resolvedLink,
            sessionActive: sessionActive,
            passActive: passActive,
            relayConfigured: relayConfigured
        )
    }

    public static func from(
        state: MobileShieldState,
        link: MobileShieldLink,
        relayConfigured: Bool = false
    ) -> MobileShieldStatus {
        MobileShieldStatus(
            link: link,
            sessionActive: state.sessionActive,
            passActive: state.hasMobilePass,
            relayConfigured: relayConfigured
        )
    }

    /// Truthful link: unconfigured relay is local-only / not configured.
    /// Configured relays report SYNCED, never PAIRED from local focus alone.
    public static func inferredLink(
        sessionActive: Bool,
        passActive: Bool,
        relayConfigured: Bool = false
    ) -> MobileShieldLink {
        if !relayConfigured {
            return .localOnly
        }
        _ = (sessionActive, passActive)
        return .synced
    }
}

/// Domain events the coordinator maps onto iCloud writes and silent pushes.
public enum MobileShieldEvent: Sendable, Equatable {
    case focusTick
    case focusStarted
    case focusCompleted
    case passRedeemed(kind: PassKind, durationSeconds: Int)
    case passExpired(kind: PassKind)
}

public enum MobileShieldCoding: Sendable {
    public static func normalize(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    public static func string(from date: Date) -> String {
        makeFractionalFormatter().string(from: normalize(date))
    }

    public static func date(from string: String) -> Date? {
        if let parsed = makeFractionalFormatter().date(from: string) {
            return normalize(parsed)
        }
        return ISO8601DateFormatter().date(from: string).map(normalize)
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 timestamp"
                )
            }
            return date
        }
        return decoder
    }

    private static func makeFractionalFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}

extension PassKind {
    /// Food and Phone passes drive the iOS Focus Filter window.
    public var isMobileShieldPass: Bool {
        switch self {
        case .food, .phone:
            return true
        case .emergency, .streaming, .gaming:
            return false
        }
    }
}
