import Foundation
import ZoidLockInCore
import ZoidLockInEnforcer

@main
struct ZoidLockInDaemonMain {
    static func main() {
        let daemon = EnforcementDaemon()

        // Fail-closed: apply full lockdown immediately on boot / respawn.
        daemon.applyPolicy(.lockedDown)
        daemon.start()

        FileHandle.standardError.write(
            Data(
                "[ZoidLockInDaemon] \(DaemonConfiguration.label) started (KeepAlive enforcement active)\n"
                    .utf8
            )
        )

        // Keep the LaunchDaemon process alive; launchd restarts us if we exit.
        dispatchMain()
    }
}
