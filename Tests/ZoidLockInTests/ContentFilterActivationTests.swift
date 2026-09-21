import Foundation
import NetworkExtension
import SystemExtensions
import Testing
import ZoidLockInCore
import ZoidLockInFilterExtension

final class MockFilterManager: FilterManaging, @unchecked Sendable {
    var isEnabled: Bool = false
    var localizedDescription: String?
    var providerConfiguration: NEFilterProviderConfiguration?
    var loadError: (any Error)?
    var saveError: (any Error)?
    var loadCallsCount = 0
    var saveCallsCount = 0
    var disabledEncryptedDNSCount = 0

    func loadFromPreferences(completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        loadCallsCount += 1
        completionHandler(loadError)
    }

    func saveToPreferences(completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        saveCallsCount += 1
        completionHandler(saveError)
    }

    func applyDisableEncryptedDNSSettings() {
        disabledEncryptedDNSCount += 1
    }
}

final class MockSystemExtensionRequester: SystemExtensionRequesting, @unchecked Sendable {
    var submittedIdentifier: String?
    var submittedDelegate: (any OSSystemExtensionRequestDelegate)?

    func submitActivationRequest(identifier: String, delegate: any OSSystemExtensionRequestDelegate) {
        submittedIdentifier = identifier
        submittedDelegate = delegate
    }
}

@Suite("Content filter manager activation tests")
struct ContentFilterManagerTests {
    @MainActor
    @Test("initial status is disabled and refreshes synchronously via callback when filter is enabled")
    func initialStatusAndRefresh() async {
        let mockManager = MockFilterManager()
        mockManager.isEnabled = true
        let requester = MockSystemExtensionRequester()
        let manager = ContentFilterManager(
            filterManager: mockManager,
            extensionRequester: requester
        )
        #expect(manager.status == .disabled)

        await withCheckedContinuation { continuation in
            manager.refreshStatus { status in
                #expect(status == .enabled)
                continuation.resume()
            }
        }

        #expect(manager.status == .enabled)
        #expect(mockManager.loadCallsCount == 1)
    }

    @MainActor
    @Test("requestActivation stays pendingApproval until sysex completes, then enables filter")
    func requestActivationAndSysexCompletionFlow() async {
        let mockManager = MockFilterManager()
        let requester = MockSystemExtensionRequester()
        let manager = ContentFilterManager(
            filterManager: mockManager,
            extensionRequester: requester
        )
        manager.requestActivation()
        #expect(manager.status == .pendingApproval)
        #expect(requester.submittedIdentifier == ContentFilterActivation.systemExtensionBundleIdentifier)
        // Invariant: filter prefs must NOT be saved before sysex approval
        #expect(mockManager.saveCallsCount == 0)
        #expect(mockManager.isEnabled == false)

        // Simulate OSSystemExtension approval
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: ContentFilterActivation.systemExtensionBundleIdentifier,
            queue: .main
        )
        await withCheckedContinuation { continuation in
            manager.request(request, didFinishWithResult: .completed) { success in
                #expect(success == true)
                continuation.resume()
            }
        }

        #expect(mockManager.loadCallsCount >= 1)
        #expect(mockManager.saveCallsCount == 1)
        #expect(mockManager.isEnabled == true)
        #expect(mockManager.localizedDescription == "Zoid Lock In Content Filter")
        #expect(mockManager.providerConfiguration?.filterSockets == true)
        #expect(mockManager.providerConfiguration?.filterPackets == false)
        #expect(mockManager.disabledEncryptedDNSCount == 1)
        #expect(manager.status == .enabled)
    }

    @MainActor
    @Test("requestNeedsUserApproval sets status to pendingApproval")
    func userApprovalStatus() async {
        let mockManager = MockFilterManager()
        let requester = MockSystemExtensionRequester()
        let manager = ContentFilterManager(
            filterManager: mockManager,
            extensionRequester: requester
        )
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: "test.id",
            queue: .main
        )
        manager.requestNeedsUserApproval(request)
        #expect(manager.status == .pendingApproval)
    }

    @MainActor
    @Test("didFailWithError sets status to failed with error message")
    func failureStatus() async {
        let mockManager = MockFilterManager()
        let requester = MockSystemExtensionRequester()
        let manager = ContentFilterManager(
            filterManager: mockManager,
            extensionRequester: requester
        )
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: "test.id",
            queue: .main
        )
        let error = NSError(domain: "OSSystemExtensionErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Extension not found"])
        manager.request(request, didFailWithError: error)
        #expect(manager.status == .failed)
        #expect(manager.errorMessage.contains("Extension not found"))
    }
}
