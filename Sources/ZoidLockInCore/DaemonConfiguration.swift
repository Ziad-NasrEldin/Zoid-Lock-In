import Foundation

/// LaunchDaemon configuration for registration via `SMAppService.daemon(plistName:)`.
public struct DaemonConfiguration: Sendable, Equatable {
    public static let label = "com.mavoid.zoidlockin.helper"
    public static let plistFileName = "com.mavoid.zoidlockin.helper.plist"
    public static let bundleProgram = "Contents/MacOS/ZoidLockInDaemon"

    public let label: String
    public let bundleProgram: String
    public let keepAlive: Bool
    public let runAtLoad: Bool

    public init(
        label: String = DaemonConfiguration.label,
        bundleProgram: String = DaemonConfiguration.bundleProgram,
        keepAlive: Bool = true,
        runAtLoad: Bool = true
    ) {
        self.label = label
        self.bundleProgram = bundleProgram
        self.keepAlive = keepAlive
        self.runAtLoad = runAtLoad
    }

    /// Property-list dictionary suitable for `SMAppService.daemon` packaging.
    public var propertyList: [String: Any] {
        [
            "Label": label,
            "BundleProgram": bundleProgram,
            "KeepAlive": keepAlive,
            "RunAtLoad": runAtLoad,
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

        return issues
    }

    public var isValid: Bool {
        validate().isEmpty
    }
}
