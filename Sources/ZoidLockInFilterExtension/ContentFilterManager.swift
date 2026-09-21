import Foundation
import NetworkExtension
import SystemExtensions
import ZoidLockInCore

/// Protocol abstracting system extension activation requests for testability.
public protocol SystemExtensionRequesting: AnyObject, Sendable {
    func submitActivationRequest(
        identifier: String,
        delegate: any OSSystemExtensionRequestDelegate
    )
}

/// Default implementation submitting requests to `OSSystemExtensionManager.shared`.
public final class DefaultSystemExtensionRequesting: SystemExtensionRequesting, @unchecked Sendable {
    public init() {}
    public func submitActivationRequest(
        identifier: String,
        delegate: any OSSystemExtensionRequestDelegate
    ) {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: identifier,
            queue: .main
        )
        request.delegate = delegate
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

/// Coordinator managing the full lifecycle of Network Extension Content Filter activation.
///
/// Coordinates system extension installation via `OSSystemExtensionRequest` and filter
/// configuration via `NEFilterManager.shared()`. Follows the unprivileged user-space flow
/// (PRD #21, SPEC §2.1, §5.2) where the app requests system extension authorization and
/// applies `NEFilterProviderConfiguration` with `disableEncryptedDNSSettings` on macOS 15+.
@MainActor
public final class ContentFilterManager: NSObject, ObservableObject, @preconcurrency OSSystemExtensionRequestDelegate {
    public static let shared = ContentFilterManager()

    @Published public private(set) var status: ContentFilterStatus = .disabled
    @Published public private(set) var errorMessage: String = ""

    public let extensionIdentifier: String
    private let filterManager: any FilterManaging
    private let extensionRequester: any SystemExtensionRequesting
    private let activator: ContentFilterActivation
    private var isExtensionApproved: Bool = false

    /// Non-IPC mock instance for previews and tests.
    public static let mockForTesting: ContentFilterManager = {
        final class StandinFilterManager: FilterManaging, @unchecked Sendable {
            var isEnabled: Bool = false
            var localizedDescription: String? = nil
            var providerConfiguration: NEFilterProviderConfiguration? = nil
            func loadFromPreferences(completionHandler: @escaping @Sendable ((any Error)?) -> Void) { completionHandler(nil) }
            func saveToPreferences(completionHandler: @escaping @Sendable ((any Error)?) -> Void) { completionHandler(nil) }
            func applyDisableEncryptedDNSSettings() {}
        }
        final class StandinRequester: SystemExtensionRequesting, @unchecked Sendable {
            func submitActivationRequest(identifier: String, delegate: any OSSystemExtensionRequestDelegate) {}
        }
        return ContentFilterManager(
            filterManager: StandinFilterManager(),
            extensionRequester: StandinRequester()
        )
    }()

    public init(
        extensionIdentifier: String = ContentFilterActivation.systemExtensionBundleIdentifier,
        filterManager: any FilterManaging = NEFilterManager.shared(),
        extensionRequester: any SystemExtensionRequesting = DefaultSystemExtensionRequesting(),
        activator: ContentFilterActivation = ContentFilterActivation()
    ) {
        self.extensionIdentifier = extensionIdentifier
        self.filterManager = filterManager
        self.extensionRequester = extensionRequester
        self.activator = activator
        super.init()
    }

    /// Refreshes the active status by querying `NEFilterManager.loadFromPreferences`.
    public func refreshStatus(completion: (@MainActor (ContentFilterStatus) -> Void)? = nil) {
        filterManager.loadFromPreferences { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    if self.status != .pendingApproval {
                        self.status = .disabled
                    }
                    self.errorMessage = error.localizedDescription
                    completion?(self.status)
                    return
                }
                if self.filterManager.isEnabled {
                    self.status = .enabled
                    self.errorMessage = ""
                } else if self.status != .pendingApproval {
                    self.status = .disabled
                }
                completion?(self.status)
            }
        }
    }

    /// Initiates user approval flow for OSSystemExtension without eagerly marking filter enabled.
    public func requestActivation() {
        status = .pendingApproval
        errorMessage = ""
        isExtensionApproved = false
        extensionRequester.submitActivationRequest(identifier: extensionIdentifier, delegate: self)
    }

    /// Loads existing preferences, configures socket filter provider and encrypted-DNS defeat, and saves.
    /// Invoked only after system extension approval/completion is verified.
    public func configureFilterPreferences(completion: (@MainActor (Bool) -> Void)? = nil) {
        filterManager.loadFromPreferences { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.status = .failed
                    self.errorMessage = error.localizedDescription
                    completion?(false)
                    return
                }

                self.filterManager.providerConfiguration = self.activator.makeProviderConfiguration()
                self.filterManager.localizedDescription = "Zoid Lock In Content Filter"
                self.filterManager.isEnabled = true
                self.activator.applyDisableEncryptedDNSSettings(to: self.filterManager)

                self.filterManager.saveToPreferences { [weak self] saveError in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let saveError {
                            self.status = .failed
                            self.errorMessage = saveError.localizedDescription
                            completion?(false)
                        } else {
                            // Verify post-save status from the manager and sysex approval
                            if self.isExtensionApproved && self.filterManager.isEnabled {
                                self.status = .enabled
                                self.errorMessage = ""
                                completion?(true)
                            } else {
                                self.status = .pendingApproval
                                completion?(false)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - OSSystemExtensionRequestDelegate

    public func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        self.status = .pendingApproval
    }

    public func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        self.handleExtensionRequestResult(result, completion: nil)
    }

    public func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result,
        completion: (@MainActor (Bool) -> Void)?
    ) {
        self.handleExtensionRequestResult(result, completion: completion)
    }

    private func handleExtensionRequestResult(
        _ result: OSSystemExtensionRequest.Result,
        completion: (@MainActor (Bool) -> Void)?
    ) {
        switch result {
        case .completed:
            self.isExtensionApproved = true
            self.configureFilterPreferences(completion: completion)
        case .willCompleteAfterReboot:
            self.status = .pendingApproval
            completion?(false)
        @unknown default:
            self.status = .pendingApproval
            completion?(false)
        }
    }

    public func request(
        _ request: OSSystemExtensionRequest,
        didFailWithError error: any Error
    ) {
        self.status = .failed
        self.errorMessage = error.localizedDescription
    }
}
