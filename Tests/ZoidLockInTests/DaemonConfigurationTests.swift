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
    }

    @Test("property list contains required LaunchDaemon keys including ThrottleInterval")
    func propertyListContainsRequiredKeys() {
        let plist = DaemonConfiguration().propertyList

        #expect(plist["Label"] as? String == "com.mavoid.zoidlockin.helper")
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/ZoidLockInDaemon")
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["ThrottleInterval"] as? Int == 1)
        #expect(plist["MachServices"] == nil)
    }

    @Test("generated XML plist serializes KeepAlive true and ThrottleInterval 1")
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
        #expect(dictionary["MachServices"] == nil)
    }

    @Test("EnforcementDaemon exposes the same LaunchDaemon plist payload")
    func enforcementDaemonExposesPlist() {
        let daemon = EnforcementDaemon()
        #expect(daemon.launchDaemonPropertyList["KeepAlive"] as? Bool == true)
        #expect(daemon.launchDaemonPropertyList["ThrottleInterval"] as? Int == 1)
        #expect(daemon.configuration.isValid)

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
}
