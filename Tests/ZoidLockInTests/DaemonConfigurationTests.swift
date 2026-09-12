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
        #expect(config.label == "com.mavoid.zoidlockin.helper")
        #expect(config.bundleProgram == "Contents/MacOS/ZoidLockInDaemon")
    }

    @Test("property list contains required LaunchDaemon keys")
    func propertyListContainsRequiredKeys() {
        let plist = DaemonConfiguration().propertyList

        #expect(plist["Label"] as? String == "com.mavoid.zoidlockin.helper")
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/ZoidLockInDaemon")
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["RunAtLoad"] as? Bool == true)
    }

    @Test("generated XML plist serializes KeepAlive true for launchd")
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
    }

    @Test("EnforcementDaemon exposes the same LaunchDaemon plist payload")
    func enforcementDaemonExposesPlist() {
        let daemon = EnforcementDaemon()
        #expect(daemon.launchDaemonPropertyList["KeepAlive"] as? Bool == true)
        #expect(daemon.configuration.isValid)

        let registrar = DaemonServiceRegistrar()
        #expect(throws: Never.self) {
            try registrar.validateForRegistration()
        }
    }

    @Test("invalid configuration is rejected before SMAppService registration")
    func rejectsInvalidConfiguration() {
        let invalid = DaemonConfiguration(label: "", keepAlive: false)
        #expect(!invalid.isValid)

        let registrar = DaemonServiceRegistrar(configuration: invalid)
        #expect(throws: DaemonRegistrationError.self) {
            try registrar.validateForRegistration()
        }
    }
}
