import Foundation
import ZoidLockInCore

extension SQLiteEconomicLedger: AdminAuditPersisting {
    public func appendAdminAudit(_ record: AdminAuditRecord) throws {
        let metadata = try Self.encodeMetadata(record)
        try performAtomically {
            try database.execute(
                """
                INSERT INTO admin_audit_events (
                    id, event_type, metadata_json, email_dispatched, created_at
                ) VALUES (?, ?, ?, ?, ?);
                """,
                [
                    .text(record.id.uuidString),
                    .text(record.kind.rawValue),
                    .text(metadata),
                    .integer(record.emailDispatched ? 1 : 0),
                    .text(LedgerISO8601.string(from: record.timestamp)),
                ]
            )
        }
    }

    public func allAdminAuditEvents() throws -> [AdminAuditRecord] {
        let rows = try database.query(
            """
            SELECT id, event_type, metadata_json, email_dispatched, created_at
            FROM admin_audit_events
            ORDER BY created_at ASC, rowid ASC;
            """
        )
        return try rows.compactMap(Self.adminAudit(from:))
    }

    private static func adminAudit(from row: [String: SQLiteValue]) throws -> AdminAuditRecord? {
        guard case let .text(idText)? = row["id"],
              let id = UUID(uuidString: idText),
              case let .text(eventType)? = row["event_type"],
              let kind = AdminAlertKind(rawValue: eventType),
              case let .text(metadataJSON)? = row["metadata_json"],
              case let .text(createdAt)? = row["created_at"],
              let timestamp = LedgerISO8601.date(from: createdAt)
        else {
            return nil
        }
        let metadata = decodeMetadata(metadataJSON)
        return AdminAuditRecord(
            kind: kind,
            timestamp: timestamp,
            recipient: metadata.recipient,
            emailDispatched: int(row["email_dispatched"]) != 0,
            errorDescription: metadata.errorDescription,
            id: id,
            detail: metadata.detail
        )
    }

    private static func encodeMetadata(_ record: AdminAuditRecord) throws -> String {
        let payload = AdminAuditMetadataPayload(
            recipient: record.recipient,
            detail: record.detail,
            errorDescription: record.errorDescription
        )
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EconomicLedgerError.invalidSchema
        }
        return json
    }

    private static func decodeMetadata(_ json: String) -> AdminAuditMetadataPayload {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AdminAuditMetadataPayload.self, from: data)
        else {
            return AdminAuditMetadataPayload(recipient: "", detail: "", errorDescription: nil)
        }
        return payload
    }
}

private struct AdminAuditMetadataPayload: Codable {
    var recipient: String
    var detail: String
    var errorDescription: String?
}

