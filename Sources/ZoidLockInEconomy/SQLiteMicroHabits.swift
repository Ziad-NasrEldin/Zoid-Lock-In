import Foundation
import ZoidLockInCore

extension SQLiteEconomicLedger: MicroHabitStoring {
    public func upsertHabit(_ habit: MicroHabit) throws {
        try performAtomically {
            try database.execute(
                """
                INSERT INTO micro_habits (
                    id, title, reward_credits, daily_frequency_limit, is_enabled, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    reward_credits = excluded.reward_credits,
                    daily_frequency_limit = excluded.daily_frequency_limit,
                    is_enabled = excluded.is_enabled,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at;
                """,
                [
                    .text(habit.id.uuidString),
                    .text(habit.title),
                    .double(habit.rewardCredits),
                    .integer(Int64(habit.dailyFrequencyLimit)),
                    .integer(habit.isEnabled ? 1 : 0),
                    .text(LedgerISO8601.string(from: habit.createdAt)),
                    .text(LedgerISO8601.string(from: habit.updatedAt)),
                ]
            )
        }
    }

    public func deleteHabit(id: UUID) throws {
        try performAtomically {
            try database.execute(
                "DELETE FROM micro_habit_completions WHERE habit_id = ?;",
                [.text(id.uuidString)]
            )
            try database.execute(
                "DELETE FROM micro_habits WHERE id = ?;",
                [.text(id.uuidString)]
            )
        }
    }

    public func habit(id: UUID) throws -> MicroHabit? {
        let rows = try database.query(
            Self.habitSelectSQL + " WHERE id = ?;",
            [.text(id.uuidString)]
        )
        return try rows.first.map(Self.habit(from:))
    }

    public func allHabits() throws -> [MicroHabit] {
        let rows = try database.query(
            Self.habitSelectSQL + " ORDER BY created_at ASC, title ASC;"
        )
        return try rows.map(Self.habit(from:))
    }

    public func insertCompletion(_ completion: MicroHabitCompletion) throws {
        try performAtomically {
            do {
                try database.execute(
                    """
                    INSERT INTO micro_habit_completions (
                        id, habit_id, civil_date, credits_awarded, created_at, created_monotonic
                    ) VALUES (?, ?, ?, ?, ?, ?);
                    """,
                    [
                        .text(completion.id.uuidString),
                        .text(completion.habitID.uuidString),
                        .text(completion.civilDate),
                        .double(completion.creditsAwarded),
                        .text(LedgerISO8601.string(from: completion.createdAt)),
                        .double(completion.createdMonotonic),
                    ]
                )
            } catch EconomicLedgerError.sqlite(_, let message)
                where message.localizedCaseInsensitiveContains("UNIQUE") {
                throw MicroHabitError.duplicateCompletion
            }
        }
    }

    public func completion(id: UUID) throws -> MicroHabitCompletion? {
        let rows = try database.query(
            Self.completionSelectSQL + " WHERE id = ?;",
            [.text(id.uuidString)]
        )
        return try rows.first.map(Self.completion(from:))
    }

    public func completions(habitID: UUID, on day: String) throws -> [MicroHabitCompletion] {
        let rows = try database.query(
            Self.completionSelectSQL + " WHERE habit_id = ? AND civil_date = ? ORDER BY created_at ASC, rowid ASC;",
            [.text(habitID.uuidString), .text(day)]
        )
        return try rows.map(Self.completion(from:))
    }

    public func completions(on day: String) throws -> [MicroHabitCompletion] {
        let rows = try database.query(
            Self.completionSelectSQL + " WHERE civil_date = ? ORDER BY created_at ASC, rowid ASC;",
            [.text(day)]
        )
        return try rows.map(Self.completion(from:))
    }

    public func allCompletions() throws -> [MicroHabitCompletion] {
        let rows = try database.query(
            Self.completionSelectSQL + " ORDER BY created_at ASC, rowid ASC;"
        )
        return try rows.map(Self.completion(from:))
    }

    private static let habitSelectSQL = """
        SELECT id, title, reward_credits, daily_frequency_limit, is_enabled, created_at, updated_at
        FROM micro_habits
        """

    private static let completionSelectSQL = """
        SELECT id, habit_id, civil_date, credits_awarded, created_at, created_monotonic
        FROM micro_habit_completions
        """

    private static func habit(from row: [String: SQLiteValue]) throws -> MicroHabit {
        guard case let .text(idString)? = row["id"],
              let id = UUID(uuidString: idString),
              case let .text(title)? = row["title"],
              case let .text(createdString)? = row["created_at"],
              let createdAt = LedgerISO8601.date(from: createdString),
              case let .text(updatedString)? = row["updated_at"],
              let updatedAt = LedgerISO8601.date(from: updatedString)
        else {
            throw EconomicLedgerError.invalidSchema
        }
        return MicroHabit(
            id: id,
            title: title,
            rewardCredits: double(row["reward_credits"]),
            dailyFrequencyLimit: Int(int(row["daily_frequency_limit"])),
            isEnabled: int(row["is_enabled"]) != 0,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func completion(from row: [String: SQLiteValue]) throws -> MicroHabitCompletion {
        guard case let .text(idString)? = row["id"],
              let id = UUID(uuidString: idString),
              case let .text(habitString)? = row["habit_id"],
              let habitID = UUID(uuidString: habitString),
              case let .text(civilDate)? = row["civil_date"],
              case let .text(createdString)? = row["created_at"],
              let createdAt = LedgerISO8601.date(from: createdString)
        else {
            throw EconomicLedgerError.invalidSchema
        }
        return MicroHabitCompletion(
            id: id,
            habitID: habitID,
            civilDate: civilDate,
            creditsAwarded: double(row["credits_awarded"]),
            createdAt: createdAt,
            createdMonotonic: rawDouble(row["created_monotonic"])
        )
    }
}

extension SQLiteEconomicLedger: GovernanceStoring {
    public func loadGovernanceState() throws -> GovernanceState {
        let rows = try database.query(
            """
            SELECT last_configuration_mutation_at, last_configuration_mutation_monotonic,
                   boot_session_uuid, last_observed_wall, last_observed_monotonic,
                   last_observed_boot_session_uuid, accrued_monotonic_elapsed,
                   pinned_time_zone, seal_sequence
            FROM governance_state WHERE id = 1;
            """
        )
        guard let row = rows.first else { return .empty }
        return GovernanceState(
            lastConfigurationMutationAt: Self.optionalDate(row["last_configuration_mutation_at"]),
            lastConfigurationMutationMonotonic: Self.optionalDouble(row["last_configuration_mutation_monotonic"]),
            mutationBootSessionUUID: Self.optionalText(row["boot_session_uuid"]),
            lastObservedWall: Self.optionalDate(row["last_observed_wall"]),
            lastObservedMonotonic: Self.optionalDouble(row["last_observed_monotonic"]),
            lastObservedBootSessionUUID: Self.optionalText(row["last_observed_boot_session_uuid"]),
            accruedMonotonicElapsed: Self.optionalDouble(row["accrued_monotonic_elapsed"]) ?? 0,
            pinnedTimeZoneIdentifier: Self.optionalText(row["pinned_time_zone"]),
            sequence: UInt64(Self.int(row["seal_sequence"]))
        )
    }

    public func saveGovernanceState(_ state: GovernanceState) throws {
        try withGovernanceWritePermit {
            try database.execute(
                """
                INSERT INTO governance_state (
                    id, last_configuration_mutation_at, last_configuration_mutation_monotonic,
                    boot_session_uuid, last_observed_wall, last_observed_monotonic,
                    last_observed_boot_session_uuid, accrued_monotonic_elapsed,
                    pinned_time_zone, seal_sequence
                ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    last_configuration_mutation_at = excluded.last_configuration_mutation_at,
                    last_configuration_mutation_monotonic = excluded.last_configuration_mutation_monotonic,
                    boot_session_uuid = excluded.boot_session_uuid,
                    last_observed_wall = excluded.last_observed_wall,
                    last_observed_monotonic = excluded.last_observed_monotonic,
                    last_observed_boot_session_uuid = excluded.last_observed_boot_session_uuid,
                    accrued_monotonic_elapsed = excluded.accrued_monotonic_elapsed,
                    pinned_time_zone = excluded.pinned_time_zone,
                    seal_sequence = excluded.seal_sequence;
                """,
                [
                    state.lastConfigurationMutationAt.map { .text(LedgerISO8601.string(from: $0)) } ?? .null,
                    state.lastConfigurationMutationMonotonic.map(SQLiteValue.double) ?? .null,
                    state.mutationBootSessionUUID.map(SQLiteValue.text) ?? .null,
                    state.lastObservedWall.map { .text(LedgerISO8601.string(from: $0)) } ?? .null,
                    state.lastObservedMonotonic.map(SQLiteValue.double) ?? .null,
                    state.lastObservedBootSessionUUID.map(SQLiteValue.text) ?? .null,
                    .double(state.accruedMonotonicElapsed),
                    state.pinnedTimeZoneIdentifier.map(SQLiteValue.text) ?? .null,
                    .integer(Int64(state.sequence)),
                ]
            )
        }
    }

    public func loadGovernanceEnvelope() throws -> GovernanceSealEnvelope? {
        let rows = try database.query(
            "SELECT envelope_json FROM governance_seal WHERE id = 1;"
        )
        guard case let .text(json)? = rows.first?["envelope_json"],
              let data = json.data(using: .utf8)
        else {
            return nil
        }
        return try GovernanceSeal.decode(data)
    }

    public func saveGovernanceEnvelope(_ envelope: GovernanceSealEnvelope) throws {
        let data = try GovernanceSeal.encode(envelope)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EconomicLedgerError.invalidSchema
        }
        try withGovernanceWritePermit {
            try database.execute(
                """
                INSERT INTO governance_seal (id, envelope_json) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET envelope_json = excluded.envelope_json;
                """,
                [.text(json)]
            )
        }
    }

    public func loadAmenityPriceOverrides() throws -> [AmenityKind: Double] {
        let rows = try database.query(
            "SELECT amenity_kind, cost_credits FROM amenity_price_overrides;"
        )
        var result: [AmenityKind: Double] = [:]
        for row in rows {
            guard case let .text(raw)? = row["amenity_kind"],
                  let kind = AmenityKind(rawValue: raw)
            else {
                continue
            }
            result[kind] = Self.double(row["cost_credits"])
        }
        return result
    }

    public func upsertAmenityPriceOverride(kind: AmenityKind, cost: Double, updatedAt: Date) throws {
        try performAtomically {
            try database.execute(
                """
                INSERT INTO amenity_price_overrides (amenity_kind, cost_credits, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(amenity_kind) DO UPDATE SET
                    cost_credits = excluded.cost_credits,
                    updated_at = excluded.updated_at;
                """,
                [
                    .text(kind.rawValue),
                    .double(CreditMath.normalize(cost)),
                    .text(LedgerISO8601.string(from: updatedAt)),
                ]
            )
        }
    }

    public func loadBlocklistRules() throws -> [BlocklistRule] {
        let rows = try database.query(
            "SELECT suffix, created_at FROM blocklist_rules ORDER BY created_at ASC;"
        )
        return try rows.map { row in
            guard case let .text(suffix)? = row["suffix"],
                  case let .text(createdString)? = row["created_at"],
                  let createdAt = LedgerISO8601.date(from: createdString)
            else {
                throw EconomicLedgerError.invalidSchema
            }
            return BlocklistRule(suffix: suffix, createdAt: createdAt)
        }
    }

    public func upsertBlocklistRule(_ rule: BlocklistRule) throws {
        try performAtomically {
            try database.execute(
                """
                INSERT INTO blocklist_rules (suffix, created_at)
                VALUES (?, ?)
                ON CONFLICT(suffix) DO UPDATE SET created_at = excluded.created_at;
                """,
                [
                    .text(rule.suffix),
                    .text(LedgerISO8601.string(from: rule.createdAt)),
                ]
            )
        }
    }

    public func deleteBlocklistRule(suffix: String) throws {
        try performAtomically {
            try database.execute(
                "DELETE FROM blocklist_rules WHERE suffix = ?;",
                [.text(DomainFilterRules.normalize(suffix))]
            )
        }
    }

    private static func optionalText(_ value: SQLiteValue?) -> String? {
        if case let .text(text)? = value, !text.isEmpty {
            return text
        }
        return nil
    }

    private static func optionalDate(_ value: SQLiteValue?) -> Date? {
        guard let text = optionalText(value) else { return nil }
        return LedgerISO8601.date(from: text)
    }

    private static func optionalDouble(_ value: SQLiteValue?) -> TimeInterval? {
        switch value {
        case .double(let number):
            return number
        case .integer(let number):
            return Double(number)
        default:
            return nil
        }
    }
}
