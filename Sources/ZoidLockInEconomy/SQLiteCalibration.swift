import Foundation
import ZoidLockInCore

extension SQLiteEconomicLedger: CalibrationStoring {
    public func loadCalibrationState() throws -> CalibrationState? {
        let rows = try database.query(
            """
            SELECT calibration_started_at, calibration_started_monotonic, boot_session_uuid,
                   is_completed, transition_to_hard_at, last_observed_wall,
                   last_observed_monotonic, accrued_monotonic_elapsed, is_tampered, seal_sequence
            FROM calibration_state WHERE id = 1;
            """
        )
        guard let row = rows.first else { return nil }
        return try Self.calibration(from: row)
    }

    public func saveCalibrationState(_ state: CalibrationState) throws {
        try withCalibrationWritePermit {
            try database.execute(
                """
                INSERT INTO calibration_state (
                    id, calibration_started_at, calibration_started_monotonic, boot_session_uuid,
                    is_completed, transition_to_hard_at, last_observed_wall,
                    last_observed_monotonic, accrued_monotonic_elapsed, is_tampered, seal_sequence
                ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    calibration_started_at = excluded.calibration_started_at,
                    calibration_started_monotonic = excluded.calibration_started_monotonic,
                    boot_session_uuid = excluded.boot_session_uuid,
                    is_completed = excluded.is_completed,
                    transition_to_hard_at = excluded.transition_to_hard_at,
                    last_observed_wall = excluded.last_observed_wall,
                    last_observed_monotonic = excluded.last_observed_monotonic,
                    accrued_monotonic_elapsed = excluded.accrued_monotonic_elapsed,
                    is_tampered = excluded.is_tampered,
                    seal_sequence = excluded.seal_sequence;
                """,
                [
                    .text(CalibrationISO8601.string(from: state.calibrationStartedAt)),
                    .double(state.calibrationStartedMonotonic),
                    .text(state.bootSessionUUID),
                    .integer(state.isCompleted ? 1 : 0),
                    .text(CalibrationISO8601.string(from: state.transitionToHardAt)),
                    state.lastObservedWall.map { .text(CalibrationISO8601.string(from: $0)) } ?? .null,
                    state.lastObservedMonotonic.map(SQLiteValue.double) ?? .null,
                    .double(state.accruedMonotonicElapsed),
                    .integer(state.isTampered ? 1 : 0),
                    .integer(Int64(state.sequence)),
                ]
            )
        }
    }

    public func loadCalibrationEnvelope() throws -> CalibrationSealEnvelope? {
        let rows = try database.query(
            "SELECT envelope_json FROM calibration_seal WHERE id = 1;"
        )
        guard case let .text(json)? = rows.first?["envelope_json"],
              let data = json.data(using: .utf8)
        else {
            return nil
        }
        return try CalibrationSeal.decode(data)
    }

    public func saveCalibrationEnvelope(_ envelope: CalibrationSealEnvelope) throws {
        let data = try CalibrationSeal.encode(envelope)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EconomicLedgerError.invalidSchema
        }
        try withCalibrationWritePermit {
            try database.execute(
                """
                INSERT INTO calibration_seal (id, envelope_json) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET envelope_json = excluded.envelope_json;
                """,
                [.text(json)]
            )
        }
    }

    public func recordSoftInfraction(_ event: SoftInfractionEvent) throws {
        try performAtomically {
            try database.execute(
                """
                INSERT INTO calibration_infractions (recorded_at, hostname, port, transport)
                VALUES (?, ?, ?, ?);
                """,
                [
                    .text(LedgerISO8601.string(from: event.recordedAt)),
                    event.hostname.map(SQLiteValue.text) ?? .null,
                    event.port.map { SQLiteValue.integer(Int64($0)) } ?? .null,
                    .text(event.transport.rawValue),
                ]
            )
        }
    }

    public func softInfractionCount() throws -> Int {
        let rows = try database.query("SELECT COUNT(*) AS count FROM calibration_infractions;")
        return Int(Self.int(rows.first?["count"]))
    }

    private static func calibration(from row: [String: SQLiteValue]) throws -> CalibrationState {
        guard case let .text(startedString)? = row["calibration_started_at"],
              let startedAt = CalibrationISO8601.date(from: startedString),
              case let .text(boot)? = row["boot_session_uuid"],
              case let .text(transitionString)? = row["transition_to_hard_at"],
              let transition = CalibrationISO8601.date(from: transitionString)
        else {
            throw EconomicLedgerError.invalidSchema
        }

        let lastWall: Date?
        if case let .text(value)? = row["last_observed_wall"] {
            lastWall = CalibrationISO8601.date(from: value)
        } else {
            lastWall = nil
        }

        let lastMono: TimeInterval?
        switch row["last_observed_monotonic"] {
        case .double(let number):
            lastMono = number
        case .integer(let number):
            lastMono = TimeInterval(number)
        default:
            lastMono = nil
        }

        return CalibrationState(
            calibrationStartedAt: startedAt,
            calibrationStartedMonotonic: double(row["calibration_started_monotonic"]),
            bootSessionUUID: boot,
            isCompleted: int(row["is_completed"]) != 0,
            transitionToHardAt: transition,
            lastObservedWall: lastWall,
            lastObservedMonotonic: lastMono,
            accruedMonotonicElapsed: double(row["accrued_monotonic_elapsed"]),
            isTampered: int(row["is_tampered"]) != 0,
            sequence: UInt64(max(0, int(row["seal_sequence"])))
        )
    }
}

private enum CalibrationISO8601 {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
