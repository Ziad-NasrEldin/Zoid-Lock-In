import Foundation
import ZoidLockInCore
import ZoidLockInEnforcer
import ZoidLockInIPC

/// Privileged LaunchDaemon entrypoint.
///
/// Does not import `ZoidLockInFilterExtension`. The content filter lives in the
/// `com.mavoid.zoidlockin.filter` system extension; this process only runs the
/// process sentinel, the authenticated XPC listener, and the durable incident log.
@main
struct ZoidLockInDaemonMain {
    static func main() {
        let storage = FileEmergencyIncidentStore.defaultPrivilegedDirectory
        let incidents = FileEmergencyIncidentStore(directory: storage)
        let filterStatus = FileFilterStatusStore(directory: storage)
        let daemon = EnforcementDaemon(
            clock: MachContinuousTimeClock(),
            incidentStore: incidents,
            filterStatusSink: filterStatus,
            bootSessionUUID: BootSession.currentUUID(),
            storageDirectory: storage
        )

        // Fail-closed: apply full lockdown immediately on boot / respawn.
        // Emergency passes do not resume across reboot; incidents and cooldown do.
        daemon.applyPolicy(.lockedDown)
        daemon.start()
        daemon.startMachServiceListener()

        FileHandle.standardError.write(
            Data(
                "[ZoidLockInDaemon] \(DaemonConfiguration.label) started (KeepAlive + ThrottleInterval=1, MachService=\(ZoidLockInIdentity.enforcementMachServiceName), incidents=\(FileEmergencyIncidentStore.defaultDirectoryPath)/\(FileEmergencyIncidentStore.defaultFileName))\n"
                    .utf8
            )
        )

        // Keep the LaunchDaemon process alive; launchd restarts us if we exit.
        dispatchMain()
    }
}
