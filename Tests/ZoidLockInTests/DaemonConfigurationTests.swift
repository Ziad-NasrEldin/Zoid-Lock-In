import Foundation
import Testing
import ZoidLockInCore
import ZoidLockInEnforcer

@Suite("Daemon configuration / SMAppService plist")
struct DaemonConfigurationTests {
    @Test("default configuration is valid for SMAppService.daemon")
    func defaultConfigurationIsValid() {
        let config = DaemonConfiguration()
        #expect(config.isValid)
        #expect(config.keepAlive)
        #expect(config.throttleInterval == 1)
        #expect(config.label == "com.mavoid.zoidlockin.helper")
        #expect(config.bundleProgram == "Contents/MacOS/ZoidLockInDaemon")
        #expect(config.label == ZoidLockInIdentity.daemonLabel)
        #expect(config.machServices[ZoidLockInIdentity.enforcementMachServiceName] == true)
    }

    @Test("property list contains MachServices alongside ThrottleInterval and KeepAlive")
    func propertyListContainsRequiredKeys() {
        let plist = DaemonConfiguration().propertyList

        #expect(plist["Label"] as? String == "com.mavoid.zoidlockin.helper")
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/ZoidLockInDaemon")
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["ThrottleInterval"] as? Int == 1)

        let machServices = plist["MachServices"] as? [String: Bool]
        #expect(machServices?[ZoidLockInIdentity.enforcementMachServiceName] == true)
    }

    @Test("generated XML plist serializes KeepAlive, ThrottleInterval, and MachServices")
    func generatedXMLContainsKeepAlive() throws {
        let xml = DaemonConfiguration().propertyListXML()
        let data = try #require(xml.data(using: .utf8))
        let parsed = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        let dictionary = try #require(parsed as? [String: Any])

        #expect(dictionary["Label"] as? String == DaemonConfiguration.label)
        #expect(dictionary["KeepAlive"] as? Bool == true)
        #expect(dictionary["BundleProgram"] as? String == DaemonConfiguration.bundleProgram)
        #expect(dictionary["RunAtLoad"] as? Bool == true)
        #expect(dictionary["ThrottleInterval"] as? Int == 1)
        #expect(xml.contains("<key>ThrottleInterval</key>"))
        #expect(xml.contains("<integer>1</integer>"))
        #expect(xml.contains("<key>MachServices</key>"))
        #expect(xml.contains("<key>com.mavoid.zoidlockin.enforcement</key>"))

        let machServices = try #require(dictionary["MachServices"] as? [String: Any])
        #expect(machServices["com.mavoid.zoidlockin.enforcement"] as? Bool == true)
    }

    @Test("bundled Resources plist matches SMAppService expectations")
    func bundledResourcesPlistIsValid() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ZoidLockInTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let plistURL = repoRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent(DaemonConfiguration.plistFileName)

        #expect(FileManager.default.fileExists(atPath: plistURL.path))

        let data = try Data(contentsOf: plistURL)
        let parsed = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        let dictionary = try #require(parsed as? [String: Any])

        #expect(dictionary["Label"] as? String == "com.mavoid.zoidlockin.helper")
        #expect(dictionary["KeepAlive"] as? Bool == true)
        #expect(dictionary["BundleProgram"] as? String == "Contents/MacOS/ZoidLockInDaemon")
        #expect(dictionary["RunAtLoad"] as? Bool == true)
        #expect(dictionary["ThrottleInterval"] as? Int == 1)

        let machServices = try #require(dictionary["MachServices"] as? [String: Any])
        #expect(machServices["com.mavoid.zoidlockin.enforcement"] as? Bool == true)
    }

    @Test("EnforcementDaemon exposes the same LaunchDaemon plist payload")
    func enforcementDaemonExposesPlist() {
        let daemon = EnforcementDaemon()
        #expect(daemon.launchDaemonPropertyList["KeepAlive"] as? Bool == true)
        #expect(daemon.launchDaemonPropertyList["ThrottleInterval"] as? Int == 1)
        #expect(daemon.configuration.isValid)

        let machServices = daemon.launchDaemonPropertyList["MachServices"] as? [String: Bool]
        #expect(machServices?[ZoidLockInIdentity.enforcementMachServiceName] == true)

        let registrar = DaemonServiceRegistrar()
        #expect(throws: Never.self) {
            try registrar.validateForRegistration()
        }
    }

    @Test("invalid configuration is rejected before SMAppService registration")
    func rejectsInvalidConfiguration() {
        let invalid = DaemonConfiguration(label: "", keepAlive: false, throttleInterval: 10)
        #expect(!invalid.isValid)

        let registrar = DaemonServiceRegistrar(configuration: invalid)
        #expect(throws: DaemonRegistrationError.self) {
            try registrar.validateForRegistration()
        }
    }

    @Test("configuration without the enforcement Mach service is invalid")
    func rejectsMissingMachServices() {
        let invalid = DaemonConfiguration(machServices: [:])
        #expect(!invalid.isValid)
        #expect(
            invalid.validate().contains {
                $0.contains("MachServices")
            }
        )
    }

    @Test("packaged layout paths match SMAppService LaunchDaemon conventions")
    func packagedLayoutPathsMatchConventions() {
        let config = DaemonConfiguration()
        let bundleURL = URL(fileURLWithPath: "/tmp/Zoid Lock In.app")

        #expect(DaemonConfiguration.packagedLaunchDaemonsDirectory == "Contents/Library/LaunchDaemons")
        #expect(
            DaemonConfiguration.packagedPlistRelativePath
                == "Contents/Library/LaunchDaemons/com.mavoid.zoidlockin.helper.plist"
        )
        #expect(
            config.packagedPlistURL(inAppBundle: bundleURL).path
                == "/tmp/Zoid Lock In.app/Contents/Library/LaunchDaemons/com.mavoid.zoidlockin.helper.plist"
        )
        #expect(
            config.packagedHelperURL(inAppBundle: bundleURL).path
                == "/tmp/Zoid Lock In.app/Contents/MacOS/ZoidLockInDaemon"
        )
    }

    @Test("missing packaged helper and plist fail closed")
    func missingPackagedHelperAndPlistFailClosed() {
        let config = DaemonConfiguration()
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoidLockIn-empty-\(UUID().uuidString).app")
        let issues = config.validatePackagedLayout(inAppBundle: bundleURL)

        #expect(issues.contains { $0.contains("Packaged helper missing") })
        #expect(issues.contains { $0.contains("Packaged LaunchDaemon plist missing") })

        let registrar = DaemonServiceRegistrar(configuration: config)
        #expect(throws: DaemonRegistrationError.self) {
            try registrar.validatePackagedLayout(inAppBundle: bundleURL)
        }
    }

    @Test("valid packaged helper layout is accepted without weakening fail-closed keys")
    func validPackagedHelperLayoutIsAccepted() throws {
        let config = DaemonConfiguration()
        let fileManager = FileManager.default
        let bundleURL = fileManager.temporaryDirectory
            .appendingPathComponent("ZoidLockIn-packaged-\(UUID().uuidString).app")
        let helperURL = config.packagedHelperURL(inAppBundle: bundleURL)
        let plistURL = config.packagedPlistURL(inAppBundle: bundleURL)

        try fileManager.createDirectory(
            at: helperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        fileManager.createFile(atPath: helperURL.path, contents: Data("helper".utf8))
        try config.propertyListXML().write(to: plistURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: bundleURL) }

        #expect(config.validatePackagedLayout(inAppBundle: bundleURL).isEmpty)
        #expect(throws: Never.self) {
            try DaemonServiceRegistrar(configuration: config)
                .validatePackagedLayout(inAppBundle: bundleURL)
        }
    }

    @Test("registrar status captions stay fail-closed")
    func registrarStatusCaptionsStayFailClosed() {
        #expect(DaemonServiceRegistrar.statusCaption(.enabled) == "ENABLED · ROOT SENTINEL")
        #expect(
            DaemonServiceRegistrar.statusCaption(.requiresApproval)
                == "APPROVAL REQUIRED IN SYSTEM SETTINGS"
        )
        #expect(DaemonServiceRegistrar.statusCaption(.notRegistered) == "NOT REGISTERED")
        #expect(DaemonServiceRegistrar.statusCaption(.notFound) == "BUNDLE HELPER NOT FOUND")
    }
}
