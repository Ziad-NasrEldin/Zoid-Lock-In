import CoreGraphics
import Foundation
import Testing
import ZoidLockInCore
import ZoidLockInEconomy

@Suite("Slice 6 adversarial hardening")
struct Slice6AdversarialHardeningTests {
    @Test("notes shorter than 120 characters are rejected")
    func shortNotesRejected() throws {
        do {
            try MeetingArtifactFormat.validate(kind: .notes, data: Data("x".utf8), fileExtension: "md")
            Issue.record("single-character notes must fail")
        } catch let error as OfflineMeetingError {
            guard case .invalidArtifact(.notes, let reason) = error else {
                Issue.record("expected invalidArtifact, got \(error)")
                return
            }
            #expect(reason.localizedCaseInsensitiveContains("120") || reason.localizedCaseInsensitiveContains("non-whitespace"))
        }

        let punctuation = Data((["#", String(repeating: "!", count: 200)] as [String]).joined(separator: "\n").utf8)
        do {
            try MeetingArtifactFormat.validate(kind: .notes, data: punctuation, fileExtension: "md")
            Issue.record("punctuation stub notes must fail")
        } catch let error as OfflineMeetingError {
            guard case .invalidArtifact(.notes, let reason) = error else {
                Issue.record("expected invalidArtifact, got \(error)")
                return
            }
            #expect(reason.localizedCaseInsensitiveContains("stub") || reason.localizedCaseInsensitiveContains("placeholder"))
        }

        let oneLine = Data(String(repeating: "Agenda item about the client workshop ", count: 8).utf8)
        do {
            try MeetingArtifactFormat.validate(kind: .notes, data: oneLine, fileExtension: "md")
            Issue.record("single-line notes must fail")
        } catch let error as OfflineMeetingError {
            guard case .invalidArtifact(.notes, let reason) = error else {
                Issue.record("expected invalidArtifact, got \(error)")
                return
            }
            #expect(reason.localizedCaseInsensitiveContains("multi-line"))
        }

        try MeetingArtifactFormat.validate(
            kind: .notes,
            data: MeetingTestSupport.substantiveNotesData,
            fileExtension: "md"
        )

        let harness = MeetingHardeningHarness()
        try harness.completeFifteenMinuteSession()
        do {
            _ = try harness.coordinator.attach(kind: .notes, data: Data("ok\n".utf8), fileExtension: "md")
            Issue.record("attach of stub notes must fail")
        } catch let error as OfflineMeetingError {
            guard case .invalidArtifact(.notes, _) = error else {
                Issue.record("expected invalidArtifact, got \(error)")
                return
            }
        }
    }

    @Test("duplicate receipt and photo SHA-256 hashes across meetings are rejected")
    func duplicateArtifactHashesRejected() throws {
        let harness = MeetingHardeningHarness()
        let sharedReceipt = TestImageFactory.uniquePDF("shared-receipt")
        let sharedPhoto = try TestImageFactory.appleCameraJPEG(dateTime: "2023:11:14 22:30:00")

        try harness.completeFifteenMinuteSession()
        try harness.attachNotes()
        _ = try harness.coordinator.attach(kind: .receipt, data: sharedReceipt, fileExtension: "pdf")
        _ = try harness.coordinator.attach(kind: .environmentPhoto, data: sharedPhoto, fileExtension: "jpg")
        let first = try harness.coordinator.submit()
        #expect(first.receiptSHA256 == ArtifactDigest.sha256Hex(sharedReceipt))
        #expect(first.photoSHA256 == ArtifactDigest.sha256Hex(sharedPhoto))

        try harness.coordinator.punchIn()
        harness.mono.advance(by: 900)
        harness.wall.advance(by: 900)
        try harness.coordinator.punchOut()
        _ = try harness.coordinator.attach(
            kind: .notes,
            data: MeetingTestSupport.alternateSubstantiveNotesData,
            fileExtension: "md"
        )

        do {
            _ = try harness.coordinator.attach(kind: .receipt, data: sharedReceipt, fileExtension: "pdf")
            Issue.record("reused receipt digest must fail")
        } catch let error as OfflineMeetingError {
            #expect(error == .duplicateArtifact(.receipt))
        }

        do {
            _ = try harness.coordinator.attach(kind: .environmentPhoto, data: sharedPhoto, fileExtension: "jpg")
            Issue.record("reused photo digest must fail")
        } catch let error as OfflineMeetingError {
            #expect(error == .duplicateArtifact(.environmentPhoto))
        }

        let uniqueReceipt = TestImageFactory.uniquePDF("second-receipt")
        let uniquePhoto = try TestImageFactory.appleCameraJPEG(
            dateTime: "2023:11:14 22:35:00",
            fill: CGColor(red: 0.12, green: 0.38, blue: 0.72, alpha: 1)
        )
        _ = try harness.coordinator.attach(kind: .receipt, data: uniqueReceipt, fileExtension: "pdf")
        _ = try harness.coordinator.attach(kind: .environmentPhoto, data: uniquePhoto, fileExtension: "jpg")
        let second = try harness.coordinator.submit()
        #expect(second.id != first.id)
        #expect(second.receiptSHA256 != first.receiptSHA256)
        #expect(second.photoSHA256 != first.photoSHA256)
    }

    @Test("tiny thumbnail and stripped non-Apple EXIF images are rejected")
    func tinyAndNonAppleExifRejected() throws {
        let punchIn = Date(timeIntervalSince1970: 1_700_000_000)
        let punchOut = punchIn.addingTimeInterval(900)
        let validator = MeetingPhotoValidator(timeZone: TimeZone(secondsFromGMT: 0)!)

        do {
            _ = try validator.validate(
                imageData: try TestImageFactory.thumbnailJPEG(),
                punchIn: punchIn,
                punchOut: punchOut
            )
            Issue.record("48×48 thumbnail must fail")
        } catch let error as MeetingPhotoValidationError {
            guard case .photoTooSmall(let width, let height) = error else {
                Issue.record("expected photoTooSmall, got \(error)")
                return
            }
            #expect(width == 48)
            #expect(height == 48)
        }

        do {
            _ = try validator.validate(
                imageData: try TestImageFactory.jpeg(
                    make: "Apple",
                    model: "iPhone 15 Pro",
                    dateTime: "2023:11:14 22:20:00",
                    offset: "+00:00",
                    includeCameraHardware: false,
                    includeMakerApple: false
                ),
                punchIn: punchIn,
                punchOut: punchOut
            )
            Issue.record("Make/Model without MakerNotes or sensor tags must fail")
        } catch let error as MeetingPhotoValidationError {
            #expect(error == .missingAppleHardwareIndicators)
        }

        do {
            _ = try validator.validate(
                imageData: try TestImageFactory.jpeg(
                    make: nil,
                    model: nil,
                    dateTime: nil,
                    software: nil,
                    offset: nil,
                    includeCameraHardware: false,
                    includeMakerApple: false
                ),
                punchIn: punchIn,
                punchOut: punchOut
            )
            Issue.record("stripped EXIF must fail")
        } catch let error as MeetingPhotoValidationError {
            #expect(
                error == .strippedMetadata
                    || error == .notAppleCamera(make: nil, model: nil)
                    || error == .missingCaptureTimestamp
                    || error == .missingAppleHardwareIndicators
            )
        }

        do {
            _ = try validator.validate(
                imageData: try TestImageFactory.jpeg(offset: "+05:00"),
                punchIn: punchIn,
                punchOut: punchOut
            )
            Issue.record("offset that does not match system timezone must fail")
        } catch let error as MeetingPhotoValidationError {
            guard case .timezoneOffsetMismatch(let photoOffset, let systemOffset) = error else {
                Issue.record("expected timezoneOffsetMismatch, got \(error)")
                return
            }
            #expect(photoOffset == 5 * 3600)
            #expect(systemOffset == 0)
        }

        let accepted = try validator.validate(
            imageData: try TestImageFactory.appleCameraJPEG(dateTime: "2023:11:14 22:20:00"),
            punchIn: punchIn,
            punchOut: punchOut
        )
        #expect(accepted.isAppleCamera)
        #expect(accepted.pixelWidth >= OfflineMeetingPolicy.minimumPhotoEdge)
        #expect(accepted.pixelHeight >= OfflineMeetingPolicy.minimumPhotoEdge)
    }

    @Test("TimeTravelGuard clock tamper rejects punch-in and punch-out")
    func timeTravelGuardRejectsPunchInAndOut() throws {
        let tamper = TimeTravelGuard()
        let mono = ManualMonotonicClock(startingAt: 2_000)
        let wall = ManualWallClock(Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = OfflineSessionCoordinator(
            store: InMemoryOfflineMeetingStore(),
            artifacts: MeetingArtifactStore(rootURL: MeetingArtifactLocation.makeIsolatedRoot()),
            clock: mono,
            uptimeClock: mono,
            wallClock: wall,
            timeTravel: tamper,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            bootSessionUUID: "boot-tamper"
        )

        tamper.observe(wall: wall.now(), monotonic: mono.nowSeconds())
        wall.advance(by: TimeTravelGuard.maxSkewSeconds + 30)
        tamper.observe(wall: wall.now(), monotonic: mono.nowSeconds())
        #expect(tamper.isTampered)

        do {
            _ = try coordinator.punchIn()
            Issue.record("tampered punch-in must fail")
        } catch let error as OfflineMeetingError {
            guard case .clockTampered(let skew) = error else {
                Issue.record("expected clockTampered, got \(error)")
                return
            }
            #expect(abs(skew) > TimeTravelGuard.maxSkewSeconds)
        }

        let clean = TimeTravelGuard()
        let cleanMono = ManualMonotonicClock(startingAt: 3_000)
        let cleanWall = ManualWallClock(Date(timeIntervalSince1970: 1_700_000_000))
        let punching = OfflineSessionCoordinator(
            store: InMemoryOfflineMeetingStore(),
            artifacts: MeetingArtifactStore(rootURL: MeetingArtifactLocation.makeIsolatedRoot()),
            clock: cleanMono,
            uptimeClock: cleanMono,
            wallClock: cleanWall,
            timeTravel: clean,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            bootSessionUUID: "boot-tamper-out"
        )
        try punching.punchIn()
        cleanMono.advance(by: 900)
        cleanWall.advance(by: TimeTravelGuard.maxSkewSeconds + 180)
        do {
            _ = try punching.punchOut()
            Issue.record("tampered punch-out must fail")
        } catch let error as OfflineMeetingError {
            guard case .clockTampered = error else {
                Issue.record("expected clockTampered on punch-out, got \(error)")
                return
            }
        }
    }

    @Test("active meeting prevents concurrent focus block double-dipping")
    func activeMeetingBlocksFocusMinting() throws {
        let engineHarness = EngineHarness(hour: 10, minute: 0)
        let meetings = OfflineSessionCoordinator(
            store: InMemoryOfflineMeetingStore(),
            artifacts: MeetingArtifactStore(rootURL: MeetingArtifactLocation.makeIsolatedRoot()),
            clock: engineHarness.mono,
            uptimeClock: engineHarness.mono,
            wallClock: engineHarness.wall,
            timeTravel: engineHarness.engine.timeTravel,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            bootSessionUUID: "boot-mutex"
        )
        meetings.bindFocusEngine(engineHarness.engine)

        try engineHarness.engine.startFocus()
        engineHarness.advance(1_800)
        try engineHarness.engine.tick()
        #expect(engineHarness.engine.walletBalance == 0.5)
        #expect(engineHarness.engine.activeFocusSession?.state == .active)

        try meetings.punchIn()
        #expect(meetings.isPunchedIn)
        #expect(engineHarness.engine.isOfflineMeetingRecording)
        #expect(engineHarness.engine.activeFocusSession == nil)

        do {
            _ = try engineHarness.engine.startFocus()
            Issue.record("focus minting must not start during a punched-in meeting")
        } catch let error as ExchangeEngineError {
            #expect(error == .offlineMeetingActive)
        }

        engineHarness.advance(1_800)
        try engineHarness.engine.tick()
        #expect(engineHarness.engine.walletBalance == 0.5)

        try meetings.punchOut()
        #expect(!meetings.isPunchedIn)
        #expect(!engineHarness.engine.isOfflineMeetingRecording)

        try engineHarness.engine.startFocus()
        engineHarness.advance(1_800)
        try engineHarness.engine.tick()
        #expect(engineHarness.engine.walletBalance == 1.0)
    }

    @Test("abandon session resets state after reboot and over-max duration")
    func abandonResetsStateCleanly() throws {
        let store = InMemoryOfflineMeetingStore()
        let artifacts = MeetingArtifactStore(rootURL: MeetingArtifactLocation.makeIsolatedRoot())
        let mono = ManualMonotonicClock(startingAt: 10)
        let wall = ManualWallClock(Date(timeIntervalSince1970: 1_700_000_000))
        let original = OfflineSessionCoordinator(
            store: store,
            artifacts: artifacts,
            clock: mono,
            uptimeClock: mono,
            wallClock: wall,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            bootSessionUUID: "boot-a"
        )
        try original.punchIn()
        #expect(original.snapshot().canAbandon)

        let resumed = OfflineSessionCoordinator(
            store: store,
            artifacts: artifacts,
            clock: ManualMonotonicClock(startingAt: 80),
            uptimeClock: ManualMonotonicClock(startingAt: 80),
            wallClock: wall,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            bootSessionUUID: "boot-b"
        )
        #expect(resumed.snapshot().phase == .recording)
        #expect(resumed.snapshot().canAbandon)
        do {
            _ = try resumed.punchOut()
            Issue.record("cross-boot punch-out must fail")
        } catch let error as OfflineMeetingError {
            #expect(error == .bootSessionChanged)
        }

        let abandoned = try resumed.abandon()
        #expect(abandoned.auditStatus == .abandoned)
        #expect(resumed.activeMeeting == nil)
        #expect(resumed.snapshot().phase == .idle)
        #expect(!resumed.snapshot().canAbandon)
        #expect(resumed.snapshot().canPunchIn)

        let next = try resumed.punchIn()
        #expect(next.bootSessionUUID == "boot-b")
        #expect(next.id != abandoned.id)

        let overMax = MeetingHardeningHarness()
        try overMax.coordinator.punchIn()
        overMax.mono.advance(by: OfflineMeetingPolicy.maximumDuration + 60)
        overMax.wall.advance(by: OfflineMeetingPolicy.maximumDuration + 60)
        do {
            _ = try overMax.coordinator.punchOut()
            Issue.record("over-max punch-out must fail")
        } catch let error as OfflineMeetingError {
            guard case .durationTooLong = error else {
                Issue.record("expected durationTooLong, got \(error)")
                return
            }
        }
        #expect(overMax.coordinator.snapshot().canAbandon)
        _ = try overMax.coordinator.abandon()
        #expect(overMax.coordinator.snapshot().phase == .idle)
        _ = try overMax.coordinator.punchIn()
        #expect(overMax.coordinator.snapshot().phase == .recording)
    }

    @Test("submit re-hashes artifacts and refuses a swapped photo")
    func submitRehashDetectsTOCTOU() throws {
        let harness = MeetingHardeningHarness()
        try harness.completeFifteenMinuteSession()
        try harness.attachNotes()
        try harness.attachReceipt()
        try harness.attachApplePhoto(exif: "2023:11:14 22:20:00")
        let path = try #require(harness.coordinator.activeMeeting?.photoLocalPath)
        let replacement = try TestImageFactory.appleCameraJPEG(
            dateTime: "2023:11:14 22:21:00",
            fill: CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1)
        )
        try replacement.write(to: URL(fileURLWithPath: path), options: .atomic)
        do {
            _ = try harness.coordinator.submit()
            Issue.record("swapped photo bytes must fail the digest check")
        } catch let error as OfflineMeetingError {
            #expect(error == .artifactHashMismatch(.environmentPhoto))
        }
        #expect(harness.coordinator.activeMeeting?.auditStatus == .inProgress)
    }

    @Test("sleep-farmed monotonic duration is rejected by uptime cross-check")
    func sleepDilationRejected() throws {
        let clock = SleepSimulationClock(startingAt: 1_000)
        let wall = ManualWallClock(Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = OfflineSessionCoordinator(
            store: InMemoryOfflineMeetingStore(),
            artifacts: MeetingArtifactStore(rootURL: MeetingArtifactLocation.makeIsolatedRoot()),
            clock: clock,
            uptimeClock: clock.uptimeClock,
            wallClock: wall,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            bootSessionUUID: "boot-sleep"
        )
        try coordinator.punchIn()
        clock.simulateSleep(for: 900)
        wall.advance(by: 900)
        do {
            _ = try coordinator.punchOut()
            Issue.record("lid-closed 15-minute meeting must fail the uptime gate")
        } catch let error as OfflineMeetingError {
            guard case .excessiveSleep(let sleepSeconds, let awakeSeconds, let duration) = error else {
                Issue.record("expected excessiveSleep, got \(error)")
                return
            }
            #expect(sleepSeconds == 900)
            #expect(awakeSeconds == 0)
            #expect(duration == 900)
        }

        _ = try coordinator.abandon()
        try coordinator.punchIn()
        clock.advanceAwake(by: 900)
        wall.advance(by: 900)
        let punched = try coordinator.punchOut()
        #expect(punched.durationSeconds == 900)
        #expect(punched.punchOutUptime != nil)
    }

    @Test("submitted meeting evidence is immutable in SQLite")
    func submittedMeetingEvidenceImmutable() throws {
        let ledger = try SQLiteEconomicLedger(fileURL: EconomicLedgerLocation.makeIsolatedFileURL())
        let artifacts = MeetingArtifactStore(rootURL: MeetingArtifactLocation.makeIsolatedRoot())
        let mono = ManualMonotonicClock(startingAt: 5_000)
        let wall = ManualWallClock(Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = OfflineSessionCoordinator(
            store: ledger,
            artifacts: artifacts,
            clock: mono,
            uptimeClock: mono,
            wallClock: wall,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            bootSessionUUID: "boot-sqlite-immutable"
        )
        try coordinator.punchIn()
        mono.advance(by: 1_200)
        wall.advance(by: 1_200)
        try coordinator.punchOut()
        _ = try coordinator.attach(kind: .notes, data: MeetingTestSupport.substantiveNotesData, fileExtension: "md")
        _ = try coordinator.attach(kind: .receipt, data: TestImageFactory.uniquePDF("immutable"), fileExtension: "pdf")
        _ = try coordinator.attach(
            kind: .environmentPhoto,
            data: try TestImageFactory.appleCameraJPEG(dateTime: "2023:11:14 22:25:00"),
            fileExtension: "jpg"
        )
        let submitted = try coordinator.submit()
        #expect(submitted.auditStatus == .pending)
        #expect(submitted.creditsMinted == 0)

        do {
            try ledger.executeUncheckedSQL(
                "UPDATE offline_meetings SET duration_seconds = 14400 WHERE id = '\(submitted.id.uuidString)';"
            )
            Issue.record("duration UPDATE after submit must fail")
        } catch let error as EconomicLedgerError {
            #expect(error == .appendOnly)
        }
        do {
            try ledger.executeUncheckedSQL(
                "UPDATE offline_meetings SET photo_image_sha256 = 'deadbeef' WHERE id = '\(submitted.id.uuidString)';"
            )
            Issue.record("hash UPDATE after submit must fail")
        } catch let error as EconomicLedgerError {
            #expect(error == .appendOnly)
        }
        try ledger.executeUncheckedSQL(
            """
            UPDATE offline_meetings
               SET audit_status = 'REJECTED',
                   denial_count = 1,
                   ai_reasoning = 'flash-reject',
                   credits_minted = 0.0
             WHERE id = '\(submitted.id.uuidString)';
            """
        )
        do {
            try ledger.executeUncheckedSQL(
                "DELETE FROM offline_meetings WHERE id = '\(submitted.id.uuidString)';"
            )
            Issue.record("DELETE of submitted meeting must fail")
        } catch let error as EconomicLedgerError {
            #expect(error == .appendOnly)
        }

        try ledger.executeUncheckedSQL(
            "UPDATE offline_meetings SET notes_local_path = NULL WHERE id = '\(submitted.id.uuidString)';"
        )
        let kept = try #require(try ledger.meeting(id: submitted.id))
        #expect(kept.durationSeconds == submitted.durationSeconds)
        #expect(kept.photoSHA256 == submitted.photoSHA256)
        #expect(kept.auditStatus == .rejected)
        #expect(kept.denialCount == 1)
        #expect(kept.aiReasoning == "flash-reject")
        #expect(kept.creditsMinted == 0)
        #expect(kept.notesLocalPath == nil)
    }
}

private struct MeetingHardeningHarness {
    let store: InMemoryOfflineMeetingStore
    let artifacts: MeetingArtifactStore
    let mono: ManualMonotonicClock
    let wall: ManualWallClock
    let coordinator: OfflineSessionCoordinator

    init() {
        store = InMemoryOfflineMeetingStore()
        artifacts = MeetingArtifactStore(rootURL: MeetingArtifactLocation.makeIsolatedRoot())
        mono = ManualMonotonicClock(startingAt: 1_000)
        wall = ManualWallClock(Date(timeIntervalSince1970: 1_700_000_000))
        coordinator = OfflineSessionCoordinator(
            store: store,
            artifacts: artifacts,
            clock: mono,
            uptimeClock: mono,
            wallClock: wall,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            bootSessionUUID: "boot-hardening"
        )
    }

    func completeFifteenMinuteSession() throws {
        try coordinator.punchIn()
        mono.advance(by: 900)
        wall.advance(by: 900)
        try coordinator.punchOut()
    }

    func attachNotes() throws {
        _ = try coordinator.attach(kind: .notes, data: MeetingTestSupport.substantiveNotesData, fileExtension: "md")
    }

    func attachReceipt() throws {
        _ = try coordinator.attach(kind: .receipt, data: TestImageFactory.minimalPDF, fileExtension: "pdf")
    }

    func attachApplePhoto(exif: String) throws {
        let jpeg = try TestImageFactory.appleCameraJPEG(dateTime: exif)
        _ = try coordinator.attach(kind: .environmentPhoto, data: jpeg, fileExtension: "jpg")
    }
}
