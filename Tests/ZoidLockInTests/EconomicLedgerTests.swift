import Foundation
import Testing
import ZoidLockInCore
import ZoidLockInEconomy

@Suite("Economic ledger (SQLite WAL, append-only)")
struct EconomicLedgerTests {
    @Test("default location is Application Support/ZoidLockIn/db.sqlite")
    func defaultLocation() {
        let url = EconomicLedgerLocation.defaultFileURL()
        #expect(url.path.contains("Application Support/ZoidLockIn/db.sqlite"))
        #expect(url.lastPathComponent == "db.sqlite")
    }

    @Test("file ledger initializes WAL mode and empty vault")
    func fileLedgerWALAndVault() throws {
        let url = EconomicLedgerLocation.makeIsolatedFileURL()
        let ledger = try SQLiteEconomicLedger(fileURL: url)
        #expect(try ledger.journalMode() == "wal")
        #expect(try ledger.latestBalance() == 0)
        #expect(try ledger.loadVault() == .empty)
        #expect(try ledger.allTransactions().isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("in-memory ledger accepts a custom memory path")
    func memoryLedger() throws {
        let ledger = try SQLiteEconomicLedger()
        #expect(try ledger.latestBalance() == 0)
        try ledger.appendTransaction(
            WalletTransaction(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                amount: 0.5,
                balanceAfter: 0.5,
                transactionType: .mint,
                description: "test"
            )
        )
        #expect(try ledger.latestBalance() == 0.5)
    }

    @Test("wallet_transactions reject UPDATE and DELETE")
    func appendOnlyTriggers() throws {
        let ledger = try SQLiteEconomicLedger(fileURL: EconomicLedgerLocation.makeIsolatedFileURL())
        try ledger.appendTransaction(
            WalletTransaction(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                amount: 1.0,
                balanceAfter: 1.0,
                transactionType: .mint,
                description: "mint"
            )
        )

        do {
            try ledger.executeUncheckedSQL("UPDATE wallet_transactions SET amount = 0;")
            Issue.record("UPDATE should be rejected")
        } catch let error as EconomicLedgerError {
            #expect(error == .appendOnly)
        }

        do {
            try ledger.executeUncheckedSQL("DELETE FROM wallet_transactions;")
            Issue.record("DELETE should be rejected")
        } catch let error as EconomicLedgerError {
            #expect(error == .appendOnly)
        }

        #expect(try ledger.latestBalance() == 1.0)
        #expect(try ledger.allTransactions().count == 1)
    }

    @Test("in-memory ledger refuses rewrites")
    func inMemoryAppendOnly() throws {
        let ledger = InMemoryEconomicLedger()
        let tx = WalletTransaction(
            timestamp: Date(timeIntervalSince1970: 0),
            amount: 1,
            balanceAfter: 1,
            transactionType: .mint,
            description: "mint"
        )
        try ledger.appendTransaction(tx)
        do {
            try ledger.rewriteTransaction(tx)
            Issue.record("rewrite should fail")
        } catch let error as EconomicLedgerError {
            #expect(error == .appendOnly)
        }
        do {
            try ledger.deleteAllTransactions()
            Issue.record("delete should fail")
        } catch let error as EconomicLedgerError {
            #expect(error == .appendOnly)
        }
    }

    @Test("duplicate transaction ids are rejected")
    func duplicateIDs() throws {
        let ledger = try SQLiteEconomicLedger()
        let id = UUID()
        let tx = WalletTransaction(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1),
            amount: 0.5,
            balanceAfter: 0.5,
            transactionType: .mint,
            description: "a"
        )
        try ledger.appendTransaction(tx)
        do {
            try ledger.appendTransaction(tx)
            Issue.record("duplicate insert should fail")
        } catch let error as EconomicLedgerError {
            #expect(error == .duplicateTransaction)
        }
    }

    @Test("focus sessions upsert while reconciliations stay insert-only")
    func sessionUpsertAndReconciliationInsert() throws {
        let ledger = try SQLiteEconomicLedger()
        var session = FocusSessionRecord(
            startTime: Date(timeIntervalSince1970: 10),
            state: .active
        )
        try ledger.upsertFocusSession(session)
        session.state = .completed
        session.elapsedSeconds = 1800
        session.creditsEarned = 0.5
        try ledger.upsertFocusSession(session)
        #expect(try ledger.allFocusSessions().count == 1)
        #expect(try ledger.focusSession(id: session.id)?.state == .completed)

        let row = DailyReconciliationRecord(
            date: "2026-09-10",
            earnedCredits: 3,
            spentCredits: 0,
            sweptToVault: 3,
            victoryStreakCount: 1,
            deficitStrikeApplied: false,
            fridayRestMode: false
        )
        try ledger.insertReconciliation(row)
        do {
            try ledger.insertReconciliation(row)
            Issue.record("duplicate day should fail")
        } catch let error as EconomicLedgerError {
            #expect(error == .duplicateReconciliation)
        }
        do {
            try ledger.executeUncheckedSQL(
                "UPDATE daily_reconciliations SET earned_credits = 0 WHERE date = '2026-09-10';"
            )
            Issue.record("reconciliation UPDATE should fail")
        } catch let error as EconomicLedgerError {
            #expect(error == .appendOnly)
        }
    }
}

@Suite("Focus minting")
struct FocusMintingTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    func date(hour: Int, minute: Int) -> Date {
        LocalCivilClock(timeZone: TimeZone(secondsFromGMT: 0)!).date(
            year: 2026,
            month: 9,
            day: 10,
            hour: hour,
            minute: minute
        )
    }

    @Test("standard rate is 0.5 per 30 minutes and 1.0 per hour")
    func standardChunks() {
        #expect(FocusMinting.baseCredits(elapsedSeconds: 1799) == 0)
        #expect(FocusMinting.baseCredits(elapsedSeconds: 1800) == 0.5)
        #expect(FocusMinting.baseCredits(elapsedSeconds: 3600) == 1.0)
        #expect(FocusMinting.baseCredits(elapsedSeconds: 5400) == 1.5)
        #expect(FocusMinting.baseCredits(elapsedSeconds: 7200) == 2.0)
    }

    @Test("90-minute block before noon is 3.0; after noon is 1.5")
    func morningVersusAfternoon() {
        let startMorning = date(hour: 8, minute: 0)
        let endMorning = date(hour: 9, minute: 30)
        #expect(
            FocusMinting.mintedCredits(
                elapsedSeconds: 5400,
                startedAt: startMorning,
                endedAt: endMorning,
                calendar: calendar,
                alreadyAwardedToday: false
            ) == 3.0
        )

        let startAfternoon = date(hour: 13, minute: 0)
        let endAfternoon = date(hour: 14, minute: 30)
        #expect(
            FocusMinting.mintedCredits(
                elapsedSeconds: 5400,
                startedAt: startAfternoon,
                endedAt: endAfternoon,
                calendar: calendar,
                alreadyAwardedToday: false
            ) == 1.5
        )
    }

    @Test("a 90-minute block that finishes at noon is standard rate")
    func noonIsNotMorning() {
        let start = date(hour: 10, minute: 30)
        let end = date(hour: 12, minute: 0)
        #expect(
            FocusMinting.qualifiesForMorningMomentum(
                elapsedSeconds: 5400,
                startedAt: start,
                endedAt: end,
                calendar: calendar,
                alreadyAwardedToday: false
            ) == false
        )
    }
}
