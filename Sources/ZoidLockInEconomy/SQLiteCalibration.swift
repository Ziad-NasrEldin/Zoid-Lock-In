import Foundation
import ZoidLockInCore

extension SQLiteEconomicLedger: CalibrationStoring {
    public func loadCalibrationState() throws -> CalibrationState? {
        let rows = try database.query(
            """
            SELECT calibration_started_at, calibration_started_monotonic, boot_session_uuid,
                   is_completed, transition_to_hard_at, last_observed_wall,
                   last_observed_monotonic, accrued_monotonic_elapsed
            FROM calibration_state WHERE id = 1;
            """
        )
        guard let row = rows.first else { return nil }
        return try Self.calibration(from: row)
    }

    public func saveCalibrationState(_ state: CalibrationState) throws {
        try performAtomically {
            try database.execute(
                """
                INSERT INTO calibration_state (
                    id, calibration_started_at, calibration_started_monotonic, boot_session_uuid,
                    is_completed, transition_to_hard_at, last_observed_wall,
                    last_observed_monotonic, accrued_monotonic_elapsed
                ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    calibration_started_at = excluded.calibration_started_at,
                    calibration_started_monotonic = excluded.calibration_started_monotonic,
                    boot_session_uuid = excluded.boot_session_uuid,
                    is_completed = excluded.is_completed,
                    transition_to_hard_at = excluded.transition_to_hard_at,
                    last_observed_wall = excluded.last_observed_wall,
                    last_observed_monotonic = excluded.last_observed_monotonic,
                    accrued_monotonic_elapsed = excluded.accrued_monotonic_elapsed;
                """,
                [
                    .text(LedgerISO8601.string(from: state.calibrationStartedAt)),
                    .double(state.calibrationStartedMonotonic),
                    .text(state.bootSessionUUID),
                    .integer(state.isCompleted ? 1 : 0),
                    .text(LedgerISO8601.string(from: state.transitionToHardAt)),
                    state.lastObservedWall.map { .text(LedgerISO8601.string(from: $0)) } ?? .null,
                    state.lastObservedMonotonic.map(SQLiteValue.double) ?? .null,
                    .double(state.accruedMonotonicElapsed),
                ]
            )
        }
    }

    private static func calibration(from row: [String: SQLiteValue]) throws -> CalibrationState {
        guard case let .text(startedString)? = row["calibration_started_at"],
              let startedAt = LedgerISO8601.date(from: startedString),
              case let .text(boot)? = row["boot_session_uuid"],
              case let .text(transitionString)? = row["transition_to_hard_at"],
              let transition = LedgerISO8601.date(from: transitionString)
        else {
            throw EconomicLedgerError.invalidSchema
        }

        let lastWall: Date?
        if case let .text(value)? = row["last_observed_wall"] {
            lastWall = LedgerISO8601.date(from: value)
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
            accruedMonotonicElapsed: double(row["accrued_monotonic_elapsed"])
        )
    }
}
