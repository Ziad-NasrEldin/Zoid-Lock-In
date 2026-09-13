import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ZoidLockInCore
import ZoidLockInEconomy

@Suite("Slice 6 offline meeting core")
struct Slice6OfflineMeetingTests {
    @Test("punch-in and punch-out record monotonic duration beside UTC")
    func punchInOutMonotonicAndUTC() throws {
        let harness = MeetingHarness()
        let punchedIn = try harness.coordinator.punchIn()
        #expect(punchedIn.auditStatus == .inProgress)
        #expect(punchedIn.punchInMonotonic == 1_000)
        #expect(punchedIn.punchInUTC == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(punchedIn.punchOutUTC == nil)
        #expect(punchedIn.bootSessionUUID == "boot-test")

        harness.mono.advance(by: 10)
        harness.wall.advance(by: 10)
        do {
            _ = try harness.coordinator.punchOut()
            Issue.record("punch-out under 15 minutes must fail")
        } catch let error as OfflineMeetingError {
            guard case .durationTooShort(let duration) = error else {
                Issue.record("expected durationTooShort, got \(error)")
                return
            }
            #expect(duration == 10)
        }

        harness.mono.advance(by: 890)
        harness.wall.advance(by: 5)
        let punchedOut = try harness.coordinator.punchOut()
        #expect(punchedOut.punchOutMonotonic == 1_900)
        #expect(punchedOut.durationSeconds == 900)
        #expect(punchedOut.punchOutUTC == Date(timeIntervalSince1970: 1_700_000_015))
        #expect(punchedOut.punchOutUTC != punchedIn.punchInUTC.addingTimeInterval(900))

        let stored = try #require(try harness.store.meeting(id: punchedOut.id))
        #expect(stored.punchInMonotonic == 1_000)
        #expect(stored.punchOutMonotonic == 1_900)
        #expect(stored.durationSeconds == 900)
        #expect(stored.punchInUTC.timeIntervalSince1970 == 1_700_000_000)
        #expect(stored.punchOutUTC?.timeIntervalSince1970 == 1_700_000_015)
    }

    @Test("punch-out rejects sessions longer than 240 minutes")
    func punchOutRejectsOverMax() throws {
        let harness = MeetingHarness()
        try harness.coordinator.punchIn()
        harness.mono.advance(by: OfflineMeetingPolicy.maximumDuration + 1)
        harness.wall.advance(by: OfflineMeetingPolicy.maximumDuration + 1)
        do {
            _ = try harness.coordinator.punchOut()
            Issue.record("punch-out over 240 minutes must fail")
        } catch let error as OfflineMeetingError {
            guard case .durationTooLong(let duration) = error else {
                Issue.record("expected durationTooLong, got \(error)")
                return
            }
            #expect(duration == OfflineMeetingPolicy.maximumDuration + 1)
        }
    }

    @Test("triple-artifact gate rejects a missing payload")
    func missingArtifactRejectsSubmission() throws {
        let harness = MeetingHarness()
        try harness.completeFifteenMinuteSession()
        try harness.attachNotes()
        try harness.attachReceipt()

        do {
            _ = try harness.coordinator.submit()
            Issue.record("submit without environment photo must fail")
        } catch let error as OfflineMeetingError {
            guard case .missingArtifacts(let kinds) = error else {
                Issue.record("expected missingArtifacts, got \(error)")
                return
            }
            #expect(kinds == [.environmentPhoto])
        }

        let record = try #require(harness.coordinator.activeMeeting)
        #expect(record.auditStatus == .inProgress)
        #expect(record.photoSHA256 == nil)
    }

    @Test("submit without punch-out is refused")
    func submitRequiresPunchOut() throws {
        let harness = MeetingHarness()
        try harness.coordinator.punchIn()
        try harness.attachNotes()
        try harness.attachReceipt()
        try harness.attachApplePhoto(exif: "2023:11:14 22:15:00")
        do {
            _ = try harness.coordinator.submit()
            Issue.record("submit before punch-out must fail")
        } catch let error as OfflineMeetingError {
            #expect(error == .notPunchedOut)
        }
    }

    @Test("EXIF validator accepts Apple camera timestamps inside the meeting window")
    func exifAcceptsAppleCameraInWindow() throws {
        let punchIn = Date(timeIntervalSince1970: 1_700_000_000)
        let punchOut = punchIn.addingTimeInterval(900)
        let jpeg = try TestImageFactory.jpeg(
            make: "Apple",
            model: "iPhone 15 Pro",
            dateTime: "2023:11:14 22:20:00"
        )
        let validation = try MeetingPhotoValidator(timeZone: TimeZone(secondsFromGMT: 0)!).validate(
            imageData: jpeg,
            punchIn: punchIn,
            punchOut: punchOut
        )
        #expect(validation.isAppleCamera)
        #expect(validation.make == "Apple")
        #expect(validation.model == "iPhone 15 Pro")
        #expect(validation.capturedAt == Date(timeIntervalSince1970: 1_700_000_400))
    }

    @Test("EXIF validator allows the 15-minute punch-out leeway")
    func exifAllowsLeewayAndRejectsBeyond() throws {
        let punchIn = Date(timeIntervalSince1970: 1_700_000_000)
        let punchOut = punchIn.addingTimeInterval(900)
        let validator = MeetingPhotoValidator(timeZone: TimeZone(secondsFromGMT: 0)!)

        let inside = try TestImageFactory.jpeg(dateTime: "2023:11:14 22:43:00")
        _ = try validator.validate(imageData: inside, punchIn: punchIn, punchOut: punchOut)

        let outside = try TestImageFactory.jpeg(dateTime: "2023:11:14 22:44:00")
        do {
            _ = try validator.validate(imageData: outside, punchIn: punchIn, punchOut: punchOut)
            Issue.record("timestamp 16 minutes after punch-out must fail")
        } catch let error as MeetingPhotoValidationError {
            guard case .timestampOutOfWindow = error else {
                Issue.record("expected timestampOutOfWindow, got \(error)")
                return
            }
        }
    }

    @Test("EXIF validator rejects stripped, Photoshop-edited, and non-Apple cameras")
    func exifRejectsSpoofStrippedAndNonApple() throws {
        let punchIn = Date(timeIntervalSince1970: 1_700_000_000)
        let punchOut = punchIn.addingTimeInterval(900)
        let validator = MeetingPhotoValidator(timeZone: TimeZone(secondsFromGMT: 0)!)

        let stripped = try TestImageFactory.jpeg(make: nil, model: nil, dateTime: nil, software: nil)
        do {
            _ = try validator.validate(imageData: stripped, punchIn: punchIn, punchOut: punchOut)
            Issue.record("stripped EXIF must fail")
        } catch let error as MeetingPhotoValidationError {
            #expect(error == .strippedMetadata || error == .notAppleCamera(make: nil, model: nil) || error == .missingCaptureTimestamp)
        }

        let photoshop = try TestImageFactory.jpeg(software: "Adobe Photoshop 25.0 (Macintosh)")
        do {
            _ = try validator.validate(imageData: photoshop, punchIn: punchIn, punchOut: punchOut)
            Issue.record("Photoshop software tag must fail")
        } catch let error as MeetingPhotoValidationError {
            guard case .softwareEdited(let name) = error else {
                Issue.record("expected softwareEdited, got \(error)")
                return
            }
            #expect(name.lowercased().contains("photoshop"))
        }

        let gimp = try TestImageFactory.jpeg(software: "GIMP 2.10.34")
        do {
            _ = try validator.validate(imageData: gimp, punchIn: punchIn, punchOut: punchOut)
            Issue.record("GIMP software tag must fail")
        } catch let error as MeetingPhotoValidationError {
            guard case .softwareEdited = error else {
                Issue.record("expected softwareEdited, got \(error)")
                return
            }
        }

        let android = try TestImageFactory.jpeg(make: "Samsung", model: "SM-S928B")
        do {
            _ = try validator.validate(imageData: android, punchIn: punchIn, punchOut: punchOut)
            Issue.record("non-Apple camera must fail")
        } catch let error as MeetingPhotoValidationError {
            guard case .notAppleCamera(let make, let model) = error else {
                Issue.record("expected notAppleCamera, got \(error)")
                return
            }
            #expect(make == "Samsung")
            #expect(model == "SM-S928B")
        }
    }

    @Test("SHA-256 digests of all three artifacts persist in SQLite")
    func sha256PersistedInSQLite() throws {
        let fileURL = EconomicLedgerLocation.makeIsolatedFileURL()
        let ledger = try SQLiteEconomicLedger(fileURL: fileURL)
        let artifacts = MeetingArtifactStore(rootURL: MeetingArtifactLocation.makeIsolatedRoot())
        let mono = ManualMonotonicClock(startingAt: 5_000)
        let wall = ManualWallClock(Date(timeIntervalSince1970: 1_700_000_000))
        let coordinator = OfflineSessionCoordinator(
            store: ledger,
            artifacts: artifacts,
            clock: mono,
            wallClock: wall,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            bootSessionUUID: "boot-sqlite"
        )

        try coordinator.punchIn()
        mono.advance(by: 1_200)
        wall.advance(by: 1_200)
        try coordinator.punchOut()

        let notes = Data("# Agenda\nSite visit with the client.\n".utf8)
        let receipt = TestImageFactory.minimalPDF
        let photo = try TestImageFactory.jpeg(dateTime: "2023:11:14 22:25:00")
        let notesHash = ArtifactDigest.sha256Hex(notes)
        let receiptHash = ArtifactDigest.sha256Hex(receipt)
        let photoHash = ArtifactDigest.sha256Hex(photo)

        try coordinator.attach(kind: .notes, data: notes, fileExtension: "md")
        try coordinator.attach(kind: .receipt, data: receipt, fileExtension: "pdf")
        try coordinator.attach(kind: .environmentPhoto, data: photo, fileExtension: "jpg")
        let submitted = try coordinator.submit()

        #expect(submitted.notesSHA256 == notesHash)
        #expect(submitted.receiptSHA256 == receiptHash)
        #expect(submitted.photoSHA256 == photoHash)
        #expect(submitted.auditStatus == .pending)
        #expect(submitted.artifactsPurgeDate == submitted.punchOutUTC?.addingTimeInterval(OfflineMeetingPolicy.artifactRetention))

        let reloaded = try #require(try ledger.meeting(id: submitted.id))
        #expect(reloaded.notesSHA256 == notesHash)
        #expect(reloaded.receiptSHA256 == receiptHash)
        #expect(reloaded.photoSHA256 == photoHash)
        #expect(reloaded.agendaNotes.contains("Site visit"))
        #expect(FileManager.default.fileExists(atPath: try #require(reloaded.notesLocalPath)))
        #expect(FileManager.default.fileExists(atPath: try #require(reloaded.receiptLocalPath)))
        #expect(FileManager.default.fileExists(atPath: try #require(reloaded.photoLocalPath)))
        #expect(try ledger.journalMode() == "wal")
        #expect(reloaded.notesLocalPath?.contains("/meetings/") == true)
        #expect(reloaded.notesLocalPath?.contains(reloaded.id.uuidString) == true)
    }

    @Test("30-day purge deletes binaries and keeps hashes")
    func thirtyDayPurgeKeepsHashes() throws {
        let harness = MeetingHarness()
        try harness.completeFifteenMinuteSession()
        try harness.attachNotes()
        try harness.attachReceipt()
        try harness.attachApplePhoto(exif: "2023:11:14 22:20:00")
        let submitted = try harness.coordinator.submit()

        let notesPath = try #require(submitted.notesLocalPath)
        let receiptPath = try #require(submitted.receiptLocalPath)
        let photoPath = try #require(submitted.photoLocalPath)
        #expect(FileManager.default.fileExists(atPath: notesPath))
        #expect(FileManager.default.fileExists(atPath: receiptPath))
        #expect(FileManager.default.fileExists(atPath: photoPath))

        var stale = submitted
        stale.artifactsPurgeDate = Date(timeIntervalSince1970: 1)
        try harness.store.upsert(stale)

        let scheduler = MeetingArtifactPurgeScheduler(
            store: harness.store,
            artifacts: harness.artifacts,
            wallClock: harness.wall
        )
        let report = try scheduler.purgeExpired(now: Date(timeIntervalSince1970: 1_700_100_000))
        #expect(report.purgedMeetingIDs == [submitted.id])
        #expect(report.deletedFileCount == 3)
        #expect(!FileManager.default.fileExists(atPath: notesPath))
        #expect(!FileManager.default.fileExists(atPath: receiptPath))
        #expect(!FileManager.default.fileExists(atPath: photoPath))

        let kept = try #require(try harness.store.meeting(id: submitted.id))
        #expect(kept.notesSHA256 == submitted.notesSHA256)
        #expect(kept.receiptSHA256 == submitted.receiptSHA256)
        #expect(kept.photoSHA256 == submitted.photoSHA256)
        #expect(kept.agendaNotes == submitted.agendaNotes)
        #expect(kept.notesLocalPath == nil)
        #expect(kept.receiptLocalPath == nil)
        #expect(kept.photoLocalPath == nil)
        #expect(kept.artifactsPurgedAt != nil)
        #expect(kept.auditStatus == .pending)

        let second = try scheduler.purgeExpired(now: Date(timeIntervalSince1970: 1_700_200_000))
        #expect(second.purgedMeetingIDs.isEmpty)
    }

    @Test("future purge dates are left untouched")
    func futurePurgeDateIsNotDeleted() throws {
        let harness = MeetingHarness()
        try harness.completeFifteenMinuteSession()
        try harness.attachNotes()
        try harness.attachReceipt()
        try harness.attachApplePhoto(exif: "2023:11:14 22:20:00")
        let submitted = try harness.coordinator.submit()
        let scheduler = MeetingArtifactPurgeScheduler(
            store: harness.store,
            artifacts: harness.artifacts,
            wallClock: harness.wall
        )
        let report = try scheduler.purgeExpired(now: submitted.punchOutUTC)
        #expect(report.purgedMeetingIDs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: try #require(submitted.photoLocalPath)))
    }

    @Test("spoofed environment photo is refused at submit")
    func spoofedPhotoRefusedAtSubmit() throws {
        let harness = MeetingHarness()
        try harness.completeFifteenMinuteSession()
        try harness.attachNotes()
        try harness.attachReceipt()
        let spoofed = try TestImageFactory.jpeg(software: "Adobe Photoshop 2024")
        do {
            _ = try harness.coordinator.attach(kind: .environmentPhoto, data: spoofed, fileExtension: "jpg")
            Issue.record("Photoshop photo must fail attach after punch-out")
        } catch let error as OfflineMeetingError {
            guard case .photoValidation(.softwareEdited(_)) = error else {
                Issue.record("expected photoValidation softwareEdited, got \(error)")
                return
            }
        }
        #expect(harness.coordinator.snapshot().photo.isPresent == false)
    }

    @Test("boot-session change refuses monotonic punch-out")
    func bootSessionChangeRefusesPunchOut() throws {
        let store = InMemoryOfflineMeetingStore()
        let artifacts = MeetingArtifactStore(rootURL: MeetingArtifactLocation.makeIsolatedRoot())
        let mono = ManualMonotonicClock(startingAt: 10)
        let wall = ManualWallClock(Date(timeIntervalSince1970: 1_700_000_000))
        let original = OfflineSessionCoordinator(
            store: store,
            artifacts: artifacts,
            clock: mono,
            wallClock: wall,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            bootSessionUUID: "boot-a"
        )
        try original.punchIn()

        let resumed = OfflineSessionCoordinator(
            store: store,
            artifacts: artifacts,
            clock: ManualMonotonicClock(startingAt: 80),
            wallClock: wall,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            bootSessionUUID: "boot-b"
        )
        #expect(resumed.snapshot().phase == .recording)
        do {
            _ = try resumed.punchOut()
            Issue.record("cross-boot punch-out must fail")
        } catch let error as OfflineMeetingError {
            #expect(error == .bootSessionChanged)
        }
    }

    @Test("snapshot exposes live elapsed and dropzone status")
    func snapshotLiveElapsedAndDropzone() throws {
        let harness = MeetingHarness()
        #expect(harness.coordinator.snapshot().phase == .idle)
        #expect(harness.coordinator.snapshot().elapsedCaption == "00:00:00")
        #expect(harness.coordinator.snapshot().canPunchIn)

        try harness.coordinator.punchIn()
        harness.mono.advance(by: 125)
        let recording = harness.coordinator.snapshot()
        #expect(recording.phase == .recording)
        #expect(recording.elapsedCaption == "00:02:05")
        #expect(recording.canPunchOut)
        #expect(!recording.canSubmit)
        #expect(recording.notes.caption.contains("MISSING"))

        harness.mono.advance(by: 775)
        harness.wall.advance(by: 900)
        try harness.coordinator.punchOut()
        try harness.attachNotes()
        try harness.attachReceipt()
        try harness.attachApplePhoto(exif: "2023:11:14 22:20:00")
        let ready = harness.coordinator.snapshot()
        #expect(ready.phase == .awaitingEvidence)
        #expect(ready.canSubmit)
        #expect(ready.elapsedCaption == "00:15:00")
        #expect(ready.notes.isPresent)
        #expect(ready.receipt.isPresent)
        #expect(ready.photo.isPresent)

        _ = try harness.coordinator.submit()
        let submitted = harness.coordinator.snapshot()
        #expect(submitted.phase == .submitted)
        #expect(submitted.submissionCaption.contains("PENDING GEMINI"))
        #expect(submitted.photo.caption.contains("APPLE CAMERA"))
        #expect(!submitted.canSubmit)
    }

    @Test("proof snapshot describes a completed 47-minute triple-gate meeting")
    func proofSnapshotContract() {
        let proof = OfflineMeetingSnapshot.proof
        #expect(proof.phase == .submitted)
        #expect(proof.elapsedCaption == "00:47:00")
        #expect(proof.notes.isValid && proof.receipt.isValid && proof.photo.isValid)
        #expect(proof.photo.caption.contains("APPLE"))
        #expect(proof.submissionCaption.contains("PENDING GEMINI"))
        #expect(proof.retentionCaption.contains("30 DAYS"))
        #expect(proof.artifacts.count == 3)
    }

    @MainActor
    @Test("renders a high-resolution SUMI-E offline meeting proof PNG")
    func offlineMeetingProofPNG() throws {
        let url = OfflineMeetingProofRenderer.defaultProofURL
        try OfflineMeetingProofRenderer.renderPNG(snapshot: .proof, to: url, scale: 3)

        #expect(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        #expect(data.count > 12_000)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        let image = NSImage(data: data)
        #expect(image != nil)
        #expect((image?.size.width ?? 0) >= 440)
        #expect((image?.size.height ?? 0) >= 700)

        #expect(url.lastPathComponent == "offline_meeting_proof.png")
        #expect(url.path.contains("/screenshots/"))
    }

    @Test("receipt PNG and HEIC photo types are accepted by the format gate")
    func formatGateAcceptsPNGReceiptAndHEICPhoto() throws {
        let png = try TestImageFactory.png()
        try MeetingArtifactFormat.validate(kind: .receipt, data: png, fileExtension: "png")
        #expect(MeetingArtifactKind.environmentPhoto.allows(fileExtension: "heic"))
        #expect(!MeetingArtifactKind.environmentPhoto.allows(fileExtension: "png"))
        #expect(!MeetingArtifactKind.receipt.allows(fileExtension: "heic"))

        if let heic = TestImageFactory.heicOrNil() {
            try MeetingArtifactFormat.validate(kind: .environmentPhoto, data: heic, fileExtension: "heic")
        }

        do {
            try MeetingArtifactFormat.validate(kind: .receipt, data: png, fileExtension: "jpg")
            Issue.record("PNG bytes with a .jpg name must fail")
        } catch let error as OfflineMeetingError {
            guard case .invalidArtifact(.receipt, _) = error else {
                Issue.record("expected invalidArtifact, got \(error)")
                return
            }
        }
    }
}

private struct MeetingHarness {
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
            wallClock: wall,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            bootSessionUUID: "boot-test"
        )
    }

    func completeFifteenMinuteSession() throws {
        try coordinator.punchIn()
        mono.advance(by: 900)
        wall.advance(by: 900)
        try coordinator.punchOut()
    }

    func attachNotes() throws {
        let notes = Data("# Agenda\nQuarterly planning with the client.\n".utf8)
        _ = try coordinator.attach(kind: .notes, data: notes, fileExtension: "md")
    }

    func attachReceipt() throws {
        _ = try coordinator.attach(kind: .receipt, data: TestImageFactory.minimalPDF, fileExtension: "pdf")
    }

    func attachApplePhoto(exif: String) throws {
        let jpeg = try TestImageFactory.jpeg(dateTime: exif)
        _ = try coordinator.attach(kind: .environmentPhoto, data: jpeg, fileExtension: "jpg")
    }
}

private enum TestImageError: Error {
    case context
    case destination
    case finalize
}

private enum TestImageFactory {
    static let minimalPDF = Data("%PDF-1.4\n1 0 obj<< /Type /Catalog >>endobj\ntrailer<<>>\n%%EOF\n".utf8)

    static func jpeg(
        make: String? = "Apple",
        model: String? = "iPhone 15 Pro",
        dateTime: String? = "2023:11:14 22:20:00",
        software: String? = nil,
        offset: String? = nil
    ) throws -> Data {
        try encode(uti: UTType.jpeg, make: make, model: model, dateTime: dateTime, software: software, offset: offset)
    }

    static func png() throws -> Data {
        try encode(uti: UTType.png, make: nil, model: nil, dateTime: nil, software: nil, offset: nil)
    }

    static func heicOrNil() -> Data? {
        try? encode(uti: UTType.heic, make: "Apple", model: "iPhone 15 Pro", dateTime: "2023:11:14 22:20:00", software: nil, offset: nil)
    }

    private static func encode(
        uti: UTType,
        make: String?,
        model: String?,
        dateTime: String?,
        software: String?,
        offset: String?
    ) throws -> Data {
        let image = try makeCGImage()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            uti.identifier as CFString,
            1,
            nil
        ) else {
            throw TestImageError.destination
        }

        var tiff: [CFString: Any] = [:]
        if let make { tiff[kCGImagePropertyTIFFMake] = make }
        if let model { tiff[kCGImagePropertyTIFFModel] = model }
        if let dateTime { tiff[kCGImagePropertyTIFFDateTime] = dateTime }
        if let software { tiff[kCGImagePropertyTIFFSoftware] = software }

        var exif: [CFString: Any] = [:]
        if let dateTime { exif[kCGImagePropertyExifDateTimeOriginal] = dateTime }
        if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }

        var properties: [CFString: Any] = [:]
        if !tiff.isEmpty {
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if !exif.isEmpty {
            properties[kCGImagePropertyExifDictionary] = exif
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw TestImageError.finalize
        }
        return data as Data
    }

    private static func makeCGImage() throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: 48,
            height: 48,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestImageError.context
        }
        context.setFillColor(CGColor(red: 0.76, green: 0.23, blue: 0.18, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        guard let image = context.makeImage() else {
            throw TestImageError.context
        }
        return image
    }
}
