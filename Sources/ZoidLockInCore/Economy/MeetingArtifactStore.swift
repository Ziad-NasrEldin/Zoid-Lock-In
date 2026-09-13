import Foundation

/// A file written into `meetings/<id>/` with its SHA-256.
public struct StoredMeetingArtifact: Sendable, Equatable {
    public var kind: MeetingArtifactKind
    public var fileName: String
    public var absoluteURL: URL
    public var sha256: String
    public var byteCount: Int

    public init(
        kind: MeetingArtifactKind,
        fileName: String,
        absoluteURL: URL,
        sha256: String,
        byteCount: Int
    ) {
        self.kind = kind
        self.fileName = fileName
        self.absoluteURL = absoluteURL
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

/// Copies triple-gate artifacts into Application Support and hashes them.
public struct MeetingArtifactStore: @unchecked Sendable {
    public let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public static func `default`(fileManager: FileManager = .default) -> MeetingArtifactStore {
        MeetingArtifactStore(rootURL: MeetingArtifactLocation.defaultRoot(fileManager: fileManager), fileManager: fileManager)
    }

    public func directoryURL(for meetingID: UUID) -> URL {
        MeetingArtifactLocation.directory(for: meetingID, root: rootURL)
    }

    public func write(
        meetingID: UUID,
        kind: MeetingArtifactKind,
        data: Data,
        sourceExtension: String
    ) throws -> StoredMeetingArtifact {
        try MeetingArtifactFormat.validate(kind: kind, data: data, fileExtension: sourceExtension)
        let fileName = kind.canonicalFileName(fileExtension: sourceExtension)
        let directory = try ensureDirectory(for: meetingID)
        try removeExisting(kind: kind, in: directory)
        let destination = directory.appendingPathComponent(fileName)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw OfflineMeetingError.storageFailed(error.localizedDescription)
        }
        return StoredMeetingArtifact(
            kind: kind,
            fileName: fileName,
            absoluteURL: destination,
            sha256: ArtifactDigest.sha256Hex(data),
            byteCount: data.count
        )
    }

    public func write(
        meetingID: UUID,
        kind: MeetingArtifactKind,
        from source: URL
    ) throws -> StoredMeetingArtifact {
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw OfflineMeetingError.storageFailed(error.localizedDescription)
        }
        return try write(
            meetingID: meetingID,
            kind: kind,
            data: data,
            sourceExtension: source.pathExtension
        )
    }

    public func load(kind: MeetingArtifactKind, path: String) throws -> Data {
        let url = URL(fileURLWithPath: path)
        guard isInsideRoot(url) else {
            throw OfflineMeetingError.storageFailed("Refusing to read artifact outside the meetings root.")
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw OfflineMeetingError.storageFailed(error.localizedDescription)
        }
    }

    /// Deletes raw binaries for a meeting. SQLite hashes are left untouched.
    @discardableResult
    public func deleteBinaries(for record: OfflineMeetingRecord) throws -> Int {
        var deleted = 0
        let paths = [record.notesLocalPath, record.receiptLocalPath, record.photoLocalPath].compactMap { $0 }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard isInsideRoot(url) else { continue }
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                deleted += 1
            }
        }
        let directory = directoryURL(for: record.id)
        if isInsideRoot(directory),
           fileManager.fileExists(atPath: directory.path) {
            let remaining = try fileManager.contentsOfDirectory(atPath: directory.path)
            if remaining.isEmpty {
                try fileManager.removeItem(at: directory)
            }
        }
        return deleted
    }

    private func ensureDirectory(for meetingID: UUID) throws -> URL {
        let directory = directoryURL(for: meetingID)
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw OfflineMeetingError.storageFailed(error.localizedDescription)
        }
        return directory
    }

    private func removeExisting(kind: MeetingArtifactKind, in directory: URL) throws {
        let prefix: String
        switch kind {
        case .notes: prefix = "notes."
        case .receipt: prefix = "receipt."
        case .environmentPhoto: prefix = "environment."
        }
        let items = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.lowercased().hasPrefix(prefix) {
            try fileManager.removeItem(at: item)
        }
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let root = rootURL.standardizedFileURL.path
        if path == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }
}

/// Magic-byte and UTF-8 checks so a renamed file cannot satisfy the triple gate.
public enum MeetingArtifactFormat: Sendable {
    public static func validate(kind: MeetingArtifactKind, data: Data, fileExtension: String) throws {
        guard kind.allows(fileExtension: fileExtension) else {
            throw OfflineMeetingError.invalidArtifact(
                kind,
                reason: "unsupported file type '.\(MeetingArtifactKind.normalizedExtension(fileExtension))' (expected \(kind.dropzoneCaption))"
            )
        }
        guard !data.isEmpty else {
            throw OfflineMeetingError.invalidArtifact(kind, reason: "file is empty")
        }
        switch kind {
        case .notes:
            guard let text = String(data: data, encoding: .utf8) else {
                throw OfflineMeetingError.invalidArtifact(kind, reason: "notes.md must be UTF-8 markdown")
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw OfflineMeetingError.invalidArtifact(kind, reason: "agenda notes are empty")
            }
        case .receipt:
            try validateReceipt(data, fileExtension: fileExtension)
        case .environmentPhoto:
            try validatePhoto(data, fileExtension: fileExtension)
        }
    }

    private static func validateReceipt(_ data: Data, fileExtension: String) throws {
        let ext = MeetingArtifactKind.canonicalExtension(fileExtension)
        switch ext {
        case "jpg":
            guard isJPEG(data) else {
                throw OfflineMeetingError.invalidArtifact(.receipt, reason: "receipt.jpg is not a JPEG binary")
            }
        case "png":
            guard isPNG(data) else {
                throw OfflineMeetingError.invalidArtifact(.receipt, reason: "receipt.png is not a PNG binary")
            }
        case "pdf":
            guard isPDF(data) else {
                throw OfflineMeetingError.invalidArtifact(.receipt, reason: "receipt.pdf is not a PDF binary")
            }
        default:
            throw OfflineMeetingError.invalidArtifact(.receipt, reason: "unsupported receipt type")
        }
    }

    private static func validatePhoto(_ data: Data, fileExtension: String) throws {
        let ext = MeetingArtifactKind.canonicalExtension(fileExtension)
        switch ext {
        case "jpg":
            guard isJPEG(data) else {
                throw OfflineMeetingError.invalidArtifact(.environmentPhoto, reason: "environment.jpg is not a JPEG binary")
            }
        case "heic":
            guard isHEIC(data) else {
                throw OfflineMeetingError.invalidArtifact(.environmentPhoto, reason: "environment.heic is not a HEIC/HEIF binary")
            }
        default:
            throw OfflineMeetingError.invalidArtifact(.environmentPhoto, reason: "unsupported photo type")
        }
    }

    public static func isJPEG(_ data: Data) -> Bool {
        data.count >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF
    }

    public static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    public static func isPDF(_ data: Data) -> Bool {
        data.starts(with: Array("%PDF".utf8))
    }

    public static func isHEIC(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let ftyp = data.subdata(in: 4..<8)
        guard ftyp == Data("ftyp".utf8) else { return false }
        let brand = data.subdata(in: 8..<12)
        let brands = ["heic", "heix", "heif", "mif1", "msf1", "hevc"]
        return brands.contains { Data($0.utf8) == brand }
    }
}
