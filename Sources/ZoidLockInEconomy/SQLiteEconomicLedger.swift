import Foundation
import ZoidLockInCore

/// User-space WAL SQLite ledger. Never linked into `ZoidLockInDaemon`.
///
/// Slice 3 uses the system SQLite3 library (WAL + append-only triggers) so the
/// privileged helper cannot inherit a GRDB/SQLite graph from `ZoidLockInCore`.
public final class SQLiteEconomicLedger: EconomicLedger, @unchecked Sendable {
    public let fileURL: URL?
    private let database: SQLiteDatabase
    private let lock = NSRecursiveLock()

    public init(fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = fileURL
        self.database = try SQLiteDatabase(path: fileURL.path)
        try Self.installSchema(on: database)
    }

    public init(inMemory: Void = ()) throws {
        self.fileURL = nil
        self.database = try SQLiteDatabase(path: ":memory:")
        try Self.installSchema(on: database)
    }

    public static func `default`(fileManager: FileManager = .default) throws -> SQLiteEconomicLedger {
        try SQLiteEconomicLedger(fileURL: EconomicLedgerLocation.defaultFileURL(fileManager: fileManager))
    }

    public func journalMode() throws -> String {
        try database.journalMode()
    }

    /// Test seam used to prove UPDATE/DELETE are rejected by SQL triggers.
    public func executeUncheckedSQL(_ sql: String) throws {
        try database.execute(sql)
    }

    public func performAtomically<T>(_ body: () throws -> T) throws -> T {
        try withLock {
            try database.execute("BEGIN IMMEDIATE;")
            do {
                let result = try body()
                try database.execute("COMMIT;")
                return result
            } catch {
                try? database.execute("ROLLBACK;")
                throw error
            }
        }
    }

    public func appendTransaction(_ transaction: WalletTransaction) throws {
        try withLock {
            do {
                try database.execute(
                    """
                    INSERT INTO wallet_transactions (
                        id, timestamp, amount, balance_after, transaction_type, reference_id, description
                    ) VALUES (?, ?, ?, ?, ?, ?, ?);
                    """,
                    [
                        .text(transaction.id.uuidString),
                        .text(LedgerISO8601.string(from: transaction.timestamp)),
                        .double(transaction.amount),
                        .double(transaction.balanceAfter),
                        .text(transaction.transactionType.rawValue),
                        transaction.referenceID.map(SQLiteValue.text) ?? .null,
                        .text(transaction.description),
                    ]
                )
            } catch EconomicLedgerError.sqlite(_, let message)
                where message.localizedCaseInsensitiveContains("UNIQUE") {
                throw EconomicLedgerError.duplicateTransaction
            }
        }
    }

    public func allTransactions() throws -> [WalletTransaction] {
        try withLock {
            let rows = try database.query(
                "SELECT id, timestamp, amount, balance_after, transaction_type, reference_id, description FROM wallet_transactions ORDER BY timestamp ASC, rowid ASC;"
            )
            return try rows.map(Self.transaction(from:))
        }
    }

    public func latestBalance() throws -> Double {
        try withLock {
            let rows = try database.query(
                "SELECT balance_after FROM wallet_transactions ORDER BY timestamp DESC, rowid DESC LIMIT 1;"
            )
            if case let .double(value)? = rows.first?["balance_after"] {
                return CreditMath.normalize(value)
            }
            if case let .integer(value)? = rows.first?["balance_after"] {
                return CreditMath.normalize(Double(value))
            }
            return 0
        }
    }

    public func upsertFocusSession(_ session: FocusSessionRecord) throws {
        try withLock {
            try database.execute(
                """
                INSERT INTO focus_sessions (
                    id, start_time, end_time, elapsed_seconds, state, credits_earned, multiplier_applied
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    start_time = excluded.start_time,
                    end_time = excluded.end_time,
                    elapsed_seconds = excluded.elapsed_seconds,
                    state = excluded.state,
                    credits_earned = excluded.credits_earned,
                    multiplier_applied = excluded.multiplier_applied;
                """,
                [
                    .text(session.id.uuidString),
                    .text(LedgerISO8601.string(from: session.startTime)),
                    session.endTime.map { .text(LedgerISO8601.string(from: $0)) } ?? .null,
                    .integer(Int64(session.elapsedSeconds.rounded(.down))),
                    .text(session.state.rawValue),
                    .double(session.creditsEarned),
                    .double(session.multiplierApplied),
                ]
            )
        }
    }

    public func focusSession(id: UUID) throws -> FocusSessionRecord? {
        try withLock {
            let rows = try database.query(
                "SELECT id, start_time, end_time, elapsed_seconds, state, credits_earned, multiplier_applied FROM focus_sessions WHERE id = ?;",
                [.text(id.uuidString)]
            )
            return try rows.first.map(Self.session(from:))
        }
    }

    public func allFocusSessions() throws -> [FocusSessionRecord] {
        try withLock {
            let rows = try database.query(
                "SELECT id, start_time, end_time, elapsed_seconds, state, credits_earned, multiplier_applied FROM focus_sessions ORDER BY start_time ASC;"
            )
            return try rows.map(Self.session(from:))
        }
    }

    public func insertReconciliation(_ record: DailyReconciliationRecord) throws {
        try withLock {
            do {
                try database.execute(
                    """
                    INSERT INTO daily_reconciliations (
                        date, target_credits, earned_credits, spent_credits, swept_to_vault,
                        victory_streak_count, deficit_strike_applied, friday_rest_mode
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    [
                        .text(record.date),
                        .double(record.targetCredits),
                        .double(record.earnedCredits),
                        .double(record.spentCredits),
                        .double(record.sweptToVault),
                        .integer(Int64(record.victoryStreakCount)),
                        .integer(record.deficitStrikeApplied ? 1 : 0),
                        .integer(record.fridayRestMode ? 1 : 0),
                    ]
                )
            } catch EconomicLedgerError.sqlite(_, let message)
                where message.localizedCaseInsensitiveContains("UNIQUE") {
                throw EconomicLedgerError.duplicateReconciliation
            }
        }
    }

    public func reconciliation(onDay day: String) throws -> DailyReconciliationRecord? {
        try withLock {
            let rows = try database.query(
                """
                SELECT date, target_credits, earned_credits, spent_credits, swept_to_vault,
                       victory_streak_count, deficit_strike_applied, friday_rest_mode
                FROM daily_reconciliations WHERE date = ?;
                """,
                [.text(day)]
            )
            return try rows.first.map(Self.reconciliation(from:))
        }
    }

    public func latestReconciliationDay() throws -> String? {
        try withLock {
            let rows = try database.query("SELECT MAX(date) AS date FROM daily_reconciliations;")
            if case let .text(day)? = rows.first?["date"] {
                return day
            }
            return nil
        }
    }

    public func loadVault() throws -> LifetimeVaultRecord {
        try withLock {
            let rows = try database.query(
                "SELECT total_surplus_credits, current_streak, highest_streak FROM lifetime_vault WHERE id = 1;"
            )
            guard let row = rows.first else { return .empty }
            return LifetimeVaultRecord(
                totalSurplusCredits: Self.double(row["total_surplus_credits"]),
                currentStreak: Int(Self.int(row["current_streak"])),
                highestStreak: Int(Self.int(row["highest_streak"]))
            )
        }
    }

    public func saveVault(_ vault: LifetimeVaultRecord) throws {
        try withLock {
            try database.execute(
                """
                UPDATE lifetime_vault
                SET total_surplus_credits = ?, current_streak = ?, highest_streak = ?
                WHERE id = 1;
                """,
                [
                    .double(vault.totalSurplusCredits),
                    .integer(Int64(vault.currentStreak)),
                    .integer(Int64(vault.highestStreak)),
                ]
            )
        }
    }

    private static func installSchema(on database: SQLiteDatabase) throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS wallet_transactions (
                id TEXT PRIMARY KEY,
                timestamp TEXT NOT NULL,
                amount REAL NOT NULL,
                balance_after REAL NOT NULL,
                transaction_type TEXT NOT NULL,
                reference_id TEXT,
                description TEXT NOT NULL
            );
            """
        )
        try database.execute(
            """
            CREATE TRIGGER IF NOT EXISTS wallet_transactions_no_update
            BEFORE UPDATE ON wallet_transactions
            BEGIN
                SELECT RAISE(ABORT, 'wallet_transactions is append-only');
            END;
            """
        )
        try database.execute(
            """
            CREATE TRIGGER IF NOT EXISTS wallet_transactions_no_delete
            BEFORE DELETE ON wallet_transactions
            BEGIN
                SELECT RAISE(ABORT, 'wallet_transactions is append-only');
            END;
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS focus_sessions (
                id TEXT PRIMARY KEY,
                start_time TEXT NOT NULL,
                end_time TEXT,
                elapsed_seconds INTEGER NOT NULL DEFAULT 0,
                state TEXT NOT NULL,
                credits_earned REAL NOT NULL DEFAULT 0.0,
                multiplier_applied REAL NOT NULL DEFAULT 1.0
            );
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS daily_reconciliations (
                date TEXT PRIMARY KEY,
                target_credits REAL NOT NULL DEFAULT 3.0,
                earned_credits REAL NOT NULL,
                spent_credits REAL NOT NULL,
                swept_to_vault REAL NOT NULL,
                victory_streak_count INTEGER NOT NULL,
                deficit_strike_applied INTEGER NOT NULL,
                friday_rest_mode INTEGER NOT NULL
            );
            """
        )
        try database.execute(
            """
            CREATE TRIGGER IF NOT EXISTS daily_reconciliations_no_update
            BEFORE UPDATE ON daily_reconciliations
            BEGIN
                SELECT RAISE(ABORT, 'daily_reconciliations is append-only');
            END;
            """
        )
        try database.execute(
            """
            CREATE TRIGGER IF NOT EXISTS daily_reconciliations_no_delete
            BEFORE DELETE ON daily_reconciliations
            BEGIN
                SELECT RAISE(ABORT, 'daily_reconciliations is append-only');
            END;
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS lifetime_vault (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                total_surplus_credits REAL NOT NULL DEFAULT 0.0,
                current_streak INTEGER NOT NULL DEFAULT 0,
                highest_streak INTEGER NOT NULL DEFAULT 0
            );
            """
        )
        try database.execute(
            "INSERT OR IGNORE INTO lifetime_vault (id, total_surplus_credits, current_streak, highest_streak) VALUES (1, 0, 0, 0);"
        )
        try database.execute(
            "CREATE INDEX IF NOT EXISTS idx_wallet_transactions_timestamp ON wallet_transactions(timestamp);"
        )
        try database.execute(
            "CREATE INDEX IF NOT EXISTS idx_focus_sessions_state ON focus_sessions(state);"
        )
    }

    private static func transaction(from row: [String: SQLiteValue]) throws -> WalletTransaction {
        guard case let .text(idString)? = row["id"],
              let id = UUID(uuidString: idString),
              case let .text(timestampString)? = row["timestamp"],
              let timestamp = LedgerISO8601.date(from: timestampString),
              case let .text(typeString)? = row["transaction_type"],
              let type = WalletTransactionType(rawValue: typeString),
              case let .text(description)? = row["description"]
        else {
            throw EconomicLedgerError.invalidSchema
        }
        let reference: String?
        if case let .text(value)? = row["reference_id"] {
            reference = value
        } else {
            reference = nil
        }
        return WalletTransaction(
            id: id,
            timestamp: timestamp,
            amount: double(row["amount"]),
            balanceAfter: double(row["balance_after"]),
            transactionType: type,
            referenceID: reference,
            description: description
        )
    }

    private static func session(from row: [String: SQLiteValue]) throws -> FocusSessionRecord {
        guard case let .text(idString)? = row["id"],
              let id = UUID(uuidString: idString),
              case let .text(startString)? = row["start_time"],
              let start = LedgerISO8601.date(from: startString),
              case let .text(stateString)? = row["state"],
              let state = FocusSessionState(rawValue: stateString)
        else {
            throw EconomicLedgerError.invalidSchema
        }
        let end: Date?
        if case let .text(endString)? = row["end_time"] {
            end = LedgerISO8601.date(from: endString)
        } else {
            end = nil
        }
        return FocusSessionRecord(
            id: id,
            startTime: start,
            endTime: end,
            elapsedSeconds: Double(int(row["elapsed_seconds"])),
            state: state,
            creditsEarned: double(row["credits_earned"]),
            multiplierApplied: double(row["multiplier_applied"])
        )
    }

    private static func reconciliation(from row: [String: SQLiteValue]) throws -> DailyReconciliationRecord {
        guard case let .text(date)? = row["date"] else {
            throw EconomicLedgerError.invalidSchema
        }
        return DailyReconciliationRecord(
            date: date,
            targetCredits: double(row["target_credits"]),
            earnedCredits: double(row["earned_credits"]),
            spentCredits: double(row["spent_credits"]),
            sweptToVault: double(row["swept_to_vault"]),
            victoryStreakCount: Int(int(row["victory_streak_count"])),
            deficitStrikeApplied: int(row["deficit_strike_applied"]) != 0,
            fridayRestMode: int(row["friday_rest_mode"]) != 0
        )
    }

    private static func double(_ value: SQLiteValue?) -> Double {
        switch value {
        case .double(let number):
            return CreditMath.normalize(number)
        case .integer(let number):
            return CreditMath.normalize(Double(number))
        default:
            return 0
        }
    }

    private static func int(_ value: SQLiteValue?) -> Int64 {
        switch value {
        case .integer(let number):
            return number
        case .double(let number):
            return Int64(number)
        default:
            return 0
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

enum LedgerISO8601 {
    static func string(from date: Date) -> String {
        date.ISO8601Format()
    }

    static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}
