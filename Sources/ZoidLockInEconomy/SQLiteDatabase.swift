import Foundation
import SQLite3
import ZoidLockInCore

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)
}

/// Serial SQLite connection. WAL is enabled for on-disk files.
final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var transactionDepth = 0

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &db, flags, nil)
        handle = db
        if status != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            handle = nil
            throw EconomicLedgerError.sqlite(code: status, message: message)
        }

        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA busy_timeout = 5000;")
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
    }

    deinit {
        sqlite3_close(handle)
        handle = nil
    }

    var isInWriteTransaction: Bool {
        lock.lock()
        defer { lock.unlock() }
        return transactionDepth > 0
    }

    func journalMode() throws -> String {
        let rows = try query("PRAGMA journal_mode;")
        if case let .text(mode)? = rows.first?["journal_mode"] {
            return mode.lowercased()
        }
        if case let .text(mode)? = rows.first?.values.first {
            return mode.lowercased()
        }
        return ""
    }

    /// Starts a reserved write transaction. Nested calls share the outer BEGIN IMMEDIATE.
    func beginImmediate() throws {
        try withLock {
            if transactionDepth == 0 {
                try executeLocked("BEGIN IMMEDIATE;")
            }
            transactionDepth += 1
        }
    }

    func commit() throws {
        try withLock {
            guard transactionDepth > 0 else { return }
            transactionDepth -= 1
            if transactionDepth == 0 {
                try executeLocked("COMMIT;")
            }
        }
    }

    func rollback() throws {
        try withLock {
            guard transactionDepth > 0 else { return }
            transactionDepth = 0
            try executeLocked("ROLLBACK;")
        }
    }

    func execute(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
        try withLock {
            try executeLocked(sql, parameters)
        }
    }

    func query(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        try withLock {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bind(statement, parameters)
            var rows: [[String: SQLiteValue]] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                if status != SQLITE_ROW {
                    throw mappedError(status)
                }
                rows.append(row(statement))
            }
            return rows
        }
    }

    private func executeLocked(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, parameters)
        let status = sqlite3_step(statement)
        if status != SQLITE_DONE && status != SQLITE_ROW {
            throw mappedError(status)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw mappedError(status)
        }
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ parameters: [SQLiteValue]) throws {
        for (index, value) in parameters.enumerated() {
            let slot = Int32(index + 1)
            let status: Int32
            switch value {
            case .null:
                status = sqlite3_bind_null(statement, slot)
            case .integer(let number):
                status = sqlite3_bind_int64(statement, slot, number)
            case .double(let number):
                status = sqlite3_bind_double(statement, slot, number)
            case .text(let string):
                status = sqlite3_bind_text(statement, slot, string, -1, sqliteTransient)
            }
            if status != SQLITE_OK {
                throw mappedError(status)
            }
        }
    }

    private func row(_ statement: OpaquePointer) -> [String: SQLiteValue] {
        let count = sqlite3_column_count(statement)
        var result: [String: SQLiteValue] = [:]
        for index in 0..<count {
            let name = String(cString: sqlite3_column_name(statement, index))
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                result[name] = .integer(sqlite3_column_int64(statement, index))
            case SQLITE_FLOAT:
                result[name] = .double(sqlite3_column_double(statement, index))
            case SQLITE_TEXT:
                if let pointer = sqlite3_column_text(statement, index) {
                    result[name] = .text(String(cString: pointer))
                } else {
                    result[name] = .null
                }
            default:
                result[name] = .null
            }
        }
        return result
    }

    private func mappedError(_ code: Int32) -> EconomicLedgerError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error"
        if message.localizedCaseInsensitiveContains("append-only") {
            return .appendOnly
        }
        return .sqlite(code: code, message: message)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
