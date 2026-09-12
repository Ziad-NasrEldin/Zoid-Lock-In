import Foundation
import ZoidLockInCore
import ZoidLockInEnforcer

/// Privileged LaunchDaemon entrypoint.
///
/// Does not import `ZoidLockInFilterExtension`. The content filter lives in the
/// `com.mavoid.zoidlockin.filter` system extension; this process only runs the
/// process sentinel and, in Slice 2, the authenticated XPC listener.
@main
struct ZoidLockInDaemonMain {
    static func main() {
        let daemon = EnforcementDaemon()

        // Fail-closed: apply full lockdown immediately on boot / respawn.
        daemon.applyPolicy(.lockedDown)
        daemon.start()

        FileHandle.standardError.write(
            Data(
                "[ZoidLockInDaemon] \(DaemonConfiguration.label) started (KeepAlive + ThrottleInterval=1)\n"
                    .utf8
            )
        )

        // Keep the LaunchDaemon process alive; launchd restarts us if we exit.
        dispatchMain()
    }
}
