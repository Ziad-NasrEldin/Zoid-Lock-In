import Foundation
import ZoidLockInCore

extension SQLiteEconomicLedger: OfflineMeetingStoring {
    public func upsert(_ record: OfflineMeetingRecord) throws {
        try performAtomically {
            try database.execute(
                """
                INSERT INTO offline_meetings (
                    id, punch_in_time, punch_out_time, punch_in_monotonic, punch_out_monotonic,
                    punch_in_uptime, punch_out_uptime,
                    duration_seconds, boot_session_uuid, agenda_notes, notes_sha256,
                    receipt_image_sha256, photo_image_sha256, notes_local_path,
                    receipt_local_path, photo_local_path, artifacts_purge_date,
                    artifacts_purged_at, audit_status, denial_count, ai_reasoning,
                    credits_minted, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    punch_in_time = excluded.punch_in_time,
                    punch_out_time = excluded.punch_out_time,
                    punch_in_monotonic = excluded.punch_in_monotonic,
                    punch_out_monotonic = excluded.punch_out_monotonic,
                    punch_in_uptime = excluded.punch_in_uptime,
                    punch_out_uptime = excluded.punch_out_uptime,
                    duration_seconds = excluded.duration_seconds,
                    boot_session_uuid = excluded.boot_session_uuid,
                    agenda_notes = excluded.agenda_notes,
                    notes_sha256 = excluded.notes_sha256,
                    receipt_image_sha256 = excluded.receipt_image_sha256,
                    photo_image_sha256 = excluded.photo_image_sha256,
                    notes_local_path = excluded.notes_local_path,
                    receipt_local_path = excluded.receipt_local_path,
                    photo_local_path = excluded.photo_local_path,
                    artifacts_purge_date = excluded.artifacts_purge_date,
                    artifacts_purged_at = excluded.artifacts_purged_at,
                    audit_status = excluded.audit_status,
                    denial_count = excluded.denial_count,
                    ai_reasoning = excluded.ai_reasoning,
                    credits_minted = excluded.credits_minted,
                    created_at = excluded.created_at;
                """,
                Self.meetingBindings(record)
            )
        }
    }

    public func meeting(id: UUID) throws -> OfflineMeetingRecord? {
        let rows = try database.query(
            Self.meetingSelectSQL + " WHERE id = ?;",
            [.text(id.uuidString)]
        )
        return try rows.first.map(Self.meeting(from:))
    }

    public func allMeetings() throws -> [OfflineMeetingRecord] {
        let rows = try database.query(
            Self.meetingSelectSQL + " ORDER BY created_at ASC, rowid ASC;"
        )
        return try rows.map(Self.meeting(from:))
    }

    public func recordingMeeting() throws -> OfflineMeetingRecord? {
        let rows = try database.query(
            Self.meetingSelectSQL + " WHERE punch_out_time IS NULL AND audit_status = ? LIMIT 1;",
            [.text(OfflineMeetingAuditStatus.inProgress.rawValue)]
        )
        return try rows.first.map(Self.meeting(from:))
    }

    public func meetingsEligibleForPurge(at now: Date) throws -> [OfflineMeetingRecord] {
        let rows = try database.query(
            Self.meetingSelectSQL + """
             WHERE artifacts_purged_at IS NULL
               AND artifacts_purge_date IS NOT NULL
               AND artifacts_purge_date <= ?
               AND (
                    notes_local_path IS NOT NULL
                 OR receipt_local_path IS NOT NULL
                 OR photo_local_path IS NOT NULL
               );
            """,
            [.text(LedgerISO8601.string(from: now))]
        )
        return try rows.map(Self.meeting(from:))
    }

    public func markArtifactsPurged(id: UUID, at date: Date) throws {
        guard var record = try meeting(id: id) else { return }
        record.notesLocalPath = nil
        record.receiptLocalPath = nil
        record.photoLocalPath = nil
        record.artifactsPurgedAt = date
        try upsert(record)
    }

    private static var meetingSelectSQL: String {
        """
        SELECT id, punch_in_time, punch_out_time, punch_in_monotonic, punch_out_monotonic,
               punch_in_uptime, punch_out_uptime,
               duration_seconds, boot_session_uuid, agenda_notes, notes_sha256,
               receipt_image_sha256, photo_image_sha256, notes_local_path,
               receipt_local_path, photo_local_path, artifacts_purge_date,
               artifacts_purged_at, audit_status, denial_count, ai_reasoning,
               credits_minted, created_at
        FROM offline_meetings
        """
    }

    public func hasRegisteredArtifactHash(
        _ sha256: String,
        kind: MeetingArtifactKind,
        excluding meetingID: UUID
    ) throws -> Bool {
        let column: String
        switch kind {
        case .notes:
            column = "notes_sha256"
        case .receipt:
            column = "receipt_image_sha256"
        case .environmentPhoto:
            column = "photo_image_sha256"
        }
        let rows = try database.query(
            """
            SELECT id FROM offline_meetings
             WHERE \(column) = ?
               AND id != ?
               AND audit_status != ?
             LIMIT 1;
            """,
            [.text(sha256), .text(meetingID.uuidString), .text(OfflineMeetingAuditStatus.abandoned.rawValue)]
        )
        return !rows.isEmpty
    }

    private static func meetingBindings(_ record: OfflineMeetingRecord) -> [SQLiteValue] {
        [
            .text(record.id.uuidString),
            .text(LedgerISO8601.string(from: record.punchInUTC)),
            record.punchOutUTC.map { .text(LedgerISO8601.string(from: $0)) } ?? .null,
            .double(record.punchInMonotonic),
            record.punchOutMonotonic.map { .double($0) } ?? .null,
            .double(record.punchInUptime),
            record.punchOutUptime.map { .double($0) } ?? .null,
            .integer(Int64(record.durationSeconds.rounded(.down))),
            .text(record.bootSessionUUID),
            .text(record.agendaNotes),
            record.notesSHA256.map(SQLiteValue.text) ?? .null,
            record.receiptSHA256.map(SQLiteValue.text) ?? .null,
            record.photoSHA256.map(SQLiteValue.text) ?? .null,
            record.notesLocalPath.map(SQLiteValue.text) ?? .null,
            record.receiptLocalPath.map(SQLiteValue.text) ?? .null,
            record.photoLocalPath.map(SQLiteValue.text) ?? .null,
            record.artifactsPurgeDate.map { .text(LedgerISO8601.string(from: $0)) } ?? .null,
            record.artifactsPurgedAt.map { .text(LedgerISO8601.string(from: $0)) } ?? .null,
            .text(record.auditStatus.rawValue),
            .integer(Int64(record.denialCount)),
            record.aiReasoning.map(SQLiteValue.text) ?? .null,
            .double(record.creditsMinted),
            .text(LedgerISO8601.string(from: record.createdAt)),
        ]
    }

    private static func meeting(from row: [String: SQLiteValue]) throws -> OfflineMeetingRecord {
        guard case let .text(idString)? = row["id"],
              let id = UUID(uuidString: idString),
              case let .text(punchInString)? = row["punch_in_time"],
              let punchIn = LedgerISO8601.date(from: punchInString),
              case let .text(boot)? = row["boot_session_uuid"],
              case let .text(statusString)? = row["audit_status"],
              let status = OfflineMeetingAuditStatus(rawValue: statusString),
              case let .text(createdString)? = row["created_at"],
              let created = LedgerISO8601.date(from: createdString)
        else {
            throw EconomicLedgerError.invalidSchema
        }

        let agenda: String
        if case let .text(notes)? = row["agenda_notes"] {
            agenda = notes
        } else {
            agenda = ""
        }

        return OfflineMeetingRecord(
            id: id,
            punchInUTC: punchIn,
            punchOutUTC: textDate(row["punch_out_time"]),
            punchInMonotonic: double(row["punch_in_monotonic"]),
            punchOutMonotonic: optionalDouble(row["punch_out_monotonic"]),
            punchInUptime: optionalDouble(row["punch_in_uptime"]),
            punchOutUptime: optionalDouble(row["punch_out_uptime"]),
            durationSeconds: Double(int(row["duration_seconds"])),
            bootSessionUUID: boot,
            agendaNotes: agenda,
            notesSHA256: text(row["notes_sha256"]),
            receiptSHA256: text(row["receipt_image_sha256"]),
            photoSHA256: text(row["photo_image_sha256"]),
            notesLocalPath: text(row["notes_local_path"]),
            receiptLocalPath: text(row["receipt_local_path"]),
            photoLocalPath: text(row["photo_local_path"]),
            artifactsPurgeDate: textDate(row["artifacts_purge_date"]),
            artifactsPurgedAt: textDate(row["artifacts_purged_at"]),
            auditStatus: status,
            denialCount: Int(int(row["denial_count"])),
            aiReasoning: text(row["ai_reasoning"]),
            creditsMinted: double(row["credits_minted"]),
            createdAt: created
        )
    }

    private static func text(_ value: SQLiteValue?) -> String? {
        if case let .text(string)? = value {
            return string
        }
        return nil
    }

    private static func textDate(_ value: SQLiteValue?) -> Date? {
        guard case let .text(string)? = value else { return nil }
        return LedgerISO8601.date(from: string)
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
