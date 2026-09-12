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
}
