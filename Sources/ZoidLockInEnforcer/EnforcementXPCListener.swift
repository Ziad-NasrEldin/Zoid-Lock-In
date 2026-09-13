import Foundation
import ZoidLockInCore
import ZoidLockInIPC

/// NSXPC listener that admits connections only after `audit_token_t` validation.
public final class EnforcementXPCListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let daemon: EnforcementDaemon
    private let exporter: EnforcementXPCExporter

    public init(daemon: EnforcementDaemon) {
        self.daemon = daemon
        self.exporter = EnforcementXPCExporter(service: daemon)
        super.init()
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let token = AuditTokenExtraction.data(fromConnection: newConnection) ?? Data()
        let pid = newConnection.processIdentifier
        guard daemon.admitIncomingConnection(auditToken: token, pid: pid) else {
            newConnection.invalidate()
            return false
        }

        let clientRequirement = daemon.gatekeeper.requirementString
        if CodeRequirement.isTeamIDPinned(clientRequirement) {
            newConnection.setCodeSigningRequirement(clientRequirement)
        }

        newConnection.exportedInterface = NSXPCInterface(with: ZoidLockInEnforcementXPC.self)
        newConnection.exportedObject = exporter
        newConnection.invalidationHandler = { [weak daemon] in
            daemon?.noteClientDisconnected()
        }
        newConnection.interruptionHandler = { [weak daemon] in
            daemon?.noteClientDisconnected()
        }
        daemon.noteClientConnected()
        newConnection.resume()
        return true
    }
}

/// Bridges the ObjC NSXPC protocol onto `ZoidLockInEnforcementServicing`.
public final class EnforcementXPCExporter: NSObject, ZoidLockInEnforcementXPC, @unchecked Sendable {
    private let service: any ZoidLockInEnforcementServicing

    public init(service: any ZoidLockInEnforcementServicing) {
        self.service = service
        super.init()
    }

    public func applyPolicy(_ snapshotJSON: Data, withReply reply: @escaping (NSError?) -> Void) {
        let reply = UncheckedSendableClosure(reply)
        Task {
            do {
                let snapshot = try JSONDecoder().decode(
                    EnforcementPolicySnapshot.self,
                    from: snapshotJSON
                )
                try await service.applyPolicy(snapshot)
                reply.call(nil)
            } catch {
                reply.call(error as NSError)
            }
        }
    }

    public func openPassWithKind(
        _ kind: String,
        durationSeconds: Int,
        nonce: String,
        withReply reply: @escaping (NSError?) -> Void
    ) {
        let reply = UncheckedSendableClosure(reply)
        Task {
            do {
                guard let passKind = PassKind(rawValue: kind) else {
                    throw ZoidLockInXPCError.make(5, message: "Unknown pass kind")
                }
                try await service.openPass(
                    kind: passKind,
                    durationSeconds: durationSeconds,
                    nonce: nonce
                )
                reply.call(nil)
            } catch {
                reply.call(error as NSError)
            }
        }
    }

    public func redeemAmenityVoucher(_ voucherJSON: Data, withReply reply: @escaping (NSError?) -> Void) {
        let reply = UncheckedSendableClosure(reply)
        Task {
            do {
                let voucher = try JSONDecoder().decode(AmenityPassVoucher.self, from: voucherJSON)
                try await service.redeemAmenityVoucher(voucher)
                reply.call(nil)
            } catch {
                reply.call(error as NSError)
            }
        }
    }

    public func revokePassWithKind(_ kind: String, withReply reply: @escaping (NSError?) -> Void) {
        let reply = UncheckedSendableClosure(reply)
        Task {
            do {
                guard let passKind = PassKind(rawValue: kind) else {
                    throw ZoidLockInXPCError.make(5, message: "Unknown pass kind")
                }
                try await service.revokePass(kind: passKind)
                reply.call(nil)
            } catch {
                reply.call(error as NSError)
            }
        }
    }

    public func queryStatus(withReply reply: @escaping (Data?, NSError?) -> Void) {
        let reply = UncheckedSendableStatusReply(reply)
        Task {
            do {
                let status = try await service.queryStatus()
                let data = try JSONEncoder().encode(status)
                reply.call(data, nil)
            } catch {
                reply.call(nil, error as NSError)
            }
        }
    }

    public func engageEmergencySafetyValve(withReply reply: @escaping (NSError?) -> Void) {
        let reply = UncheckedSendableClosure(reply)
        Task {
            do {
                try await service.engageEmergencySafetyValve()
                reply.call(nil)
            } catch {
                reply.call(error as NSError)
            }
        }
    }

    public func heartbeat(withReply reply: @escaping (NSError?) -> Void) {
        let reply = UncheckedSendableClosure(reply)
        Task {
            do {
                try await service.heartbeat()
                reply.call(nil)
            } catch {
                reply.call(error as NSError)
            }
        }
    }

    public func queryUnleviedEmergencyIncidents(withReply reply: @escaping (Data?, NSError?) -> Void) {
        let reply = UncheckedSendableStatusReply(reply)
        Task {
            do {
                let incidents = try await service.queryUnleviedEmergencyIncidents()
                let data = try JSONEncoder().encode(incidents)
                reply.call(data, nil)
            } catch {
                reply.call(nil, error as NSError)
            }
        }
    }

    public func markEmergencyIncidentLeviedWithUUID(_ uuid: String, withReply reply: @escaping (NSError?) -> Void) {
        let reply = UncheckedSendableClosure(reply)
        Task {
            do {
                guard let id = UUID(uuidString: uuid) else {
                    throw ZoidLockInXPCError.make(6, message: "Invalid incident UUID")
                }
                try await service.markEmergencyIncidentLevied(uuid: id)
                reply.call(nil)
            } catch {
                reply.call(error as NSError)
            }
        }
    }
}

private struct UncheckedSendableClosure: @unchecked Sendable {
    private let body: (NSError?) -> Void

    init(_ body: @escaping (NSError?) -> Void) {
        self.body = body
    }

    func call(_ error: NSError?) {
        body(error)
    }
}

private struct UncheckedSendableStatusReply: @unchecked Sendable {
    private let body: (Data?, NSError?) -> Void

    init(_ body: @escaping (Data?, NSError?) -> Void) {
        self.body = body
    }

    func call(_ data: Data?, _ error: NSError?) {
        body(data, error)
    }
}
