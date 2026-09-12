import Foundation

/// LaunchDaemon configuration for registration via `SMAppService.daemon(plistName:)`.
///
/// The plist must be packaged at `App.app/Contents/Library/LaunchDaemons/<plistName>`.
/// `ThrottleInterval` is 1 second so `KeepAlive` is not the launchd default of 10s.
public struct DaemonConfiguration: Sendable, Equatable {
    public static let label = ZoidLockInIdentity.daemonLabel
    public static let plistFileName = ZoidLockInIdentity.daemonPlistFileName
    public static let bundleProgram = "Contents/MacOS/ZoidLockInDaemon"
    public static let defaultThrottleInterval = 1

    public let label: String
    public let bundleProgram: String
    public let keepAlive: Bool
    public let runAtLoad: Bool
    public let throttleInterval: Int

    public init(
        label: String = DaemonConfiguration.label,
        bundleProgram: String = DaemonConfiguration.bundleProgram,
        keepAlive: Bool = true,
        runAtLoad: Bool = true,
        throttleInterval: Int = DaemonConfiguration.defaultThrottleInterval
    ) {
        self.label = label
        self.bundleProgram = bundleProgram
        self.keepAlive = keepAlive
        self.runAtLoad = runAtLoad
        self.throttleInterval = throttleInterval
    }

    /// Property-list dictionary suitable for `SMAppService.daemon` packaging.
    public var propertyList: [String: Any] {
        [
            "Label": label,
            "BundleProgram": bundleProgram,
            "KeepAlive": keepAlive,
            "RunAtLoad": runAtLoad,
            "ThrottleInterval": throttleInterval,
        ]
    }

    /// Serialized XML plist used as the LaunchDaemon definition.
    public func propertyListXML() -> String {
        let keepAliveValue = keepAlive ? "true" : "false"
        let runAtLoadValue = runAtLoad ? "true" : "false"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(label)</string>
        \t<key>BundleProgram</key>
        \t<string>\(bundleProgram)</string>
        \t<key>KeepAlive</key>
        \t<\(keepAliveValue)/>
        \t<key>RunAtLoad</key>
        \t<\(runAtLoadValue)/>
        \t<key>ThrottleInterval</key>
        \t<integer>\(throttleInterval)</integer>
        </dict>
        </plist>
        """
    }

    /// Validates required SMAppService LaunchDaemon keys.
    public func validate() -> [String] {
        var issues: [String] = []

        if label.isEmpty {
            issues.append("Label must not be empty")
        }
        if !label.hasPrefix("com.mavoid.zoidlockin") {
            issues.append("Label must use the com.mavoid.zoidlockin reverse-DNS namespace")
        }
        if bundleProgram.isEmpty {
            issues.append("BundleProgram must not be empty")
        }
        if !keepAlive {
            issues.append("KeepAlive must be true for fail-closed daemon respawn")
        }
        if throttleInterval != 1 {
            issues.append("ThrottleInterval must be 1 second so KeepAlive is not launchd's 10s default")
        }

        return issues
    }

    public var isValid: Bool {
        validate().isEmpty
    }
}
