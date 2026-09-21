import Foundation
import Testing
import ZoidLockInEconomy

@Suite("ZoidZeroActivityCatalogTests")
struct ZoidZeroActivityCatalogTests {
    @Test("Zoid 0 work apps and websites mint focus; media and browsers do not")
    func zoidZeroDefaultsDriveProductivity() {
        let catalog = ZoidZeroActivityCatalog(storeURL: URL(fileURLWithPath: "/tmp/zoid-missing-store.json"))
        #expect(catalog.isProductive(bundleIdentifier: "com.apple.dt.Xcode"))
        #expect(catalog.isProductive(bundleIdentifier: "com.openai.chat"))
        #expect(catalog.isProductive(bundleIdentifier: "com.openai.codex"))
        #expect(catalog.isProductive(bundleIdentifier: "com.todesktop.230313mzl4w4u92"))
        #expect(!catalog.isProductive(bundleIdentifier: "com.apple.Music"))
        #expect(!catalog.isProductive(bundleIdentifier: "com.apple.Safari"))
        #expect(catalog.isProductive(bundleIdentifier: "com.apple.Safari", domain: "github.com"))
        #expect(catalog.isProductive(bundleIdentifier: "com.apple.Safari", domain: "www.notion.so"))
        #expect(!catalog.isProductive(bundleIdentifier: "com.apple.Safari", domain: "youtube.com"))
        #expect(catalog.category(for: .website(domain: "linear.app")) == .work)
        #expect(catalog.category(for: .website(domain: "instagram.com")) == .social)
        #expect(catalog.category(for: .application(bundleIdentifier: "com.apple.MobileSMS")) == .communication)
    }

    @Test("Live Zoid 0 store recategorizations override defaults")
    func liveStoreOverridesDefaults() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoid-zero-catalog-\(UUID().uuidString).json")
        let payload = "{\"categoryAssignments\":[{\"application\":{\"bundleIdentifier\":\"com.apple.Music\"}},\"work\",{\"website\":{\"domain\":\"youtube.com\"}},\"work\"]}"
        try Data(payload.utf8).write(to: url)
        let catalog = ZoidZeroActivityCatalog(storeURL: url, reloadInterval: 0)
        #expect(catalog.isProductive(bundleIdentifier: "com.apple.Music"))
        #expect(catalog.isProductive(bundleIdentifier: "com.apple.Safari", domain: "youtube.com"))
        #expect(catalog.category(for: .application(bundleIdentifier: "com.apple.Music")) == .work)
    }
}

