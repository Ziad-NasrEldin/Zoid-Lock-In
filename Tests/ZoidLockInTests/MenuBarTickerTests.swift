import AppKit
import Foundation
import Testing
import ZoidLockInCore
import ZoidLockInEconomy

@Suite("Menu bar ticker")
struct MenuBarTickerTests {
    @MainActor
    @Test("renders a high-resolution SUMI-E proof PNG")
    func snapshotProofPNG() throws {
        let url = MenuBarTickerProofRenderer.defaultProofURL
        try MenuBarTickerProofRenderer.renderPNG(snapshot: .proof, to: url, scale: 3)

        #expect(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        #expect(data.count > 8_000)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        let image = NSImage(data: data)
        #expect(image != nil)
        #expect((image?.size.width ?? 0) >= 380)
        #expect((image?.size.height ?? 0) >= 280)
    }

    @Test("ticker snapshot exposes balance, focus, streak, and day state")
    func snapshotFields() throws {
        let harness = EngineHarness(hour: 8, minute: 0)
        try harness.engine.startFocus()
        harness.advance(1_800)
        let snap = try harness.engine.tick()
        #expect(snap.walletBalance == 0.5)
        #expect(snap.focusState == .active)
        #expect(snap.focusElapsedSeconds >= 1_800)
        #expect(snap.dayStateCaption == "Morning Focus")
        #expect(snap.isFridayRest == false)
        #expect(snap.formattedBalance == "0.5")
        #expect(snap.focusStatusCaption.contains("Active"))
    }

    @Test("Friday and curfew captions surface on the ticker")
    func dayStateCaptions() throws {
        let friday = EngineHarness(year: 2026, month: 9, day: 11, hour: 10, minute: 0)
        let fridaySnap = try friday.engine.snapshot()
        #expect(fridaySnap.isFridayRest)
        #expect(fridaySnap.dayStateCaption == "Friday Rest")

        let curfew = EngineHarness(hour: 22, minute: 15)
        let curfewSnap = try curfew.engine.snapshot()
        #expect(curfewSnap.isCurfew)
        #expect(curfewSnap.dayStateCaption == "Curfew")
    }
}

@Suite("Slice 3 process isolation")
struct Slice3IsolationTests {
    @Test("ZoidLockInDaemon does not depend on the economy/SQLite module")
    func daemonPackageHasNoEconomy() throws {
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")
        let text = try String(contentsOf: packageURL, encoding: .utf8)
        #expect(text.contains("ZoidLockInEconomy"))
        #expect(
            text.contains(
                "ZoidLockInDaemon — SQLite/GRDB stay out of the privileged helper"
            )
        )
        #expect(
            text.contains(
                "dependencies: [\"ZoidLockInCore\", \"ZoidLockInEnforcer\", \"ZoidLockInIPC\"]"
            )
        )
        #expect(!text.contains("dependencies: [\"ZoidLockInCore\", \"ZoidLockInEnforcer\", \"ZoidLockInIPC\", \"ZoidLockInEconomy\"]"))
    }

    @Test("daemon sources never mention SQLite, GRDB, or wallet_transactions")
    func daemonSourcesStayLedgerFree() throws {
        let daemonDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("ZoidLockInDaemon")
        let files = try FileManager.default.contentsOfDirectory(
            at: daemonDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let lowered = text.lowercased()
            #expect(!lowered.contains("sqlite"))
            #expect(!text.contains("GRDB"))
            #expect(!text.contains("wallet_transactions"))
            #expect(!text.contains("ExchangeEngine"))
        }
    }
}
