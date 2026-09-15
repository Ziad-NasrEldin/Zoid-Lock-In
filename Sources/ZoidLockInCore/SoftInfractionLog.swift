import Foundation

/// One calibration-mode warning for a verified blacklisted hostname.
public struct SoftInfractionEvent: Sendable, Equatable {
    public var hostname: String?
    public var port: UInt16?
    public var transport: TransportProtocol
    public var recordedAt: Date

    public init(
        hostname: String?,
        port: UInt16?,
        transport: TransportProtocol,
        recordedAt: Date = Date()
    ) {
        self.hostname = hostname
        self.port = port
        self.transport = transport
        self.recordedAt = recordedAt
    }

    public init(_ request: FilterFlowRequest, recordedAt: Date = Date()) {
        self.init(
            hostname: request.hostname,
            port: request.port,
            transport: request.transport,
            recordedAt: recordedAt
        )
    }
}

public protocol SoftInfractionRecording: AnyObject, Sendable {
    func recordSoftInfraction(_ event: SoftInfractionEvent)
    var count: Int { get }
    var events: [SoftInfractionEvent] { get }
}

/// Process-local infraction log. The Network Extension cannot open the user
/// SQLite ledger; the app may mirror these events into `calibration_infractions`.
public final class InMemorySoftInfractionLog: SoftInfractionRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SoftInfractionEvent] = []

    public init() {}

    public func recordSoftInfraction(_ event: SoftInfractionEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored.count
    }

    public var events: [SoftInfractionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
