import Foundation

/// LaunchDaemon configuration for registration via `SMAppService.daemon(plistName:)`.
///
/// The plist must be packaged at `App.app/Contents/Library/LaunchDaemons/<plistName>`.
/// `ThrottleInterval` is 1 second so `KeepAlive` is not the launchd default of 10s.
/// `MachServices` advertises the enforcement Mach service because `audit_token_t`
/// gatekeeping ships with Slice 2.
public struct DaemonConfiguration: Sendable, Equatable {
    public static let label = ZoidLockInIdentity.daemonLabel
    public static let plistFileName = ZoidLockInIdentity.daemonPlistFileName
    public static let bundleProgram = "Contents/MacOS/ZoidLockInDaemon"
    public static let defaultThrottleInterval = 1
    public static let defaultMachServices: [String: Bool] = [
        ZoidLockInIdentity.enforcementMachServiceName: true,
    ]
    public static let packagedLaunchDaemonsDirectory = "Contents/Library/LaunchDaemons"
    public static var packagedPlistRelativePath: String {
        packagedLaunchDaemonsDirectory + "/" + plistFileName
    }

    public let label: String
    public let bundleProgram: String
    public let keepAlive: Bool
    public let runAtLoad: Bool
    public let throttleInterval: Int
    public let machServices: [String: Bool]

    public init(
        label: String = DaemonConfiguration.label,
        bundleProgram: String = DaemonConfiguration.bundleProgram,
        keepAlive: Bool = true,
        runAtLoad: Bool = true,
        throttleInterval: Int = DaemonConfiguration.defaultThrottleInterval,
        machServices: [String: Bool] = DaemonConfiguration.defaultMachServices
    ) {
        self.label = label
        self.bundleProgram = bundleProgram
        self.keepAlive = keepAlive
        self.runAtLoad = runAtLoad
        self.throttleInterval = throttleInterval
        self.machServices = machServices
    }

    /// Property-list dictionary suitable for `SMAppService.daemon` packaging.
    public var propertyList: [String: Any] {
        [
            "Label": label,
            "BundleProgram": bundleProgram,
            "KeepAlive": keepAlive,
            "RunAtLoad": runAtLoad,
            "ThrottleInterval": throttleInterval,
            "MachServices": machServices,
        ]
    }

    /// Serialized XML plist used as the LaunchDaemon definition.
    public func propertyListXML() -> String {
        let keepAliveValue = keepAlive ? "true" : "false"
        let runAtLoadValue = runAtLoad ? "true" : "false"
        let machServiceLines = machServices.keys.sorted().map { key in
            let value = machServices[key] == true ? "true" : "false"
            return "\t\t<key>\(key)</key>\n\t\t<\(value)/>"
        }.joined(separator: "\n")

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
        \t<key>MachServices</key>
        \t<dict>
        \(machServiceLines)
        \t</dict>
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
        if machServices[ZoidLockInIdentity.enforcementMachServiceName] != true {
            issues.append(
                "MachServices must enable \(ZoidLockInIdentity.enforcementMachServiceName)"
            )
        }

        return issues
    }

    public var isValid: Bool {
        validate().isEmpty
    }

    public func packagedPlistURL(inAppBundle bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchDaemons")
            .appendingPathComponent(Self.plistFileName)
    }

    public func packagedHelperURL(inAppBundle bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(bundleProgram)
    }

    public func validatePackagedLayout(inAppBundle bundleURL: URL) -> [String] {
        var issues = validate()
        let fileManager = FileManager.default
        let helperURL = packagedHelperURL(inAppBundle: bundleURL)
        let plistURL = packagedPlistURL(inAppBundle: bundleURL)

        if !fileManager.fileExists(atPath: helperURL.path) {
            issues.append("Packaged helper missing at " + bundleProgram)
        }
        guard fileManager.fileExists(atPath: plistURL.path) else {
            issues.append("Packaged LaunchDaemon plist missing at " + Self.packagedPlistRelativePath)
            return issues
        }

        do {
            let data = try Data(contentsOf: plistURL)
            let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let dictionary = parsed as? [String: Any] else {
                issues.append("Packaged LaunchDaemon plist is not a dictionary")
                return issues
            }
            if dictionary["Label"] as? String != label {
                issues.append("Packaged LaunchDaemon Label must match the fail-closed helper identity")
            }
            if dictionary["BundleProgram"] as? String != bundleProgram {
                issues.append("Packaged LaunchDaemon BundleProgram must point at the helper binary")
            }
            if dictionary["KeepAlive"] as? Bool != true {
                issues.append("Packaged LaunchDaemon KeepAlive must stay true")
            }
            if dictionary["ThrottleInterval"] as? Int != 1 {
                issues.append("Packaged LaunchDaemon ThrottleInterval must stay 1")
            }
            let machServices = dictionary["MachServices"] as? [String: Any]
            if machServices?[ZoidLockInIdentity.enforcementMachServiceName] as? Bool != true {
                issues.append("Packaged LaunchDaemon MachServices must enable enforcement")
            }
        } catch {
            issues.append("Packaged LaunchDaemon plist could not be parsed")
        }

        return issues
    }
}
