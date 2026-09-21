import Foundation
import Testing
import ZoidLockInCore

@Suite("Resend incident audit mail")
struct AlertMailServiceTests {
    @Test("formats Resend payload with incident metadata, duration, and recipient")
    func formatsEmergencyPayload() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let report = EmergencyIncidentReport(
            timestamp: timestamp,
            durationSeconds: 1800,
            recipient: "founder@mavoid.com",
            eventType: "EMERGENCY_OVERRIDE",
            creditDebt: -2.0
        )
        let payload = AlertMailService.makePayload(
            report: report,
            from: "Zoid Lock In <alerts@mavoid.com>"
        )

        #expect(payload.from == "Zoid Lock In <alerts@mavoid.com>")
        #expect(payload.to == ["founder@mavoid.com"])
        #expect(payload.subject.contains("Emergency Safety Valve"))
        #expect(payload.text.contains("EMERGENCY_OVERRIDE"))
        #expect(payload.text.contains("1800"))
        #expect(payload.text.contains("30 minutes"))
        #expect(payload.text.contains("founder@mavoid.com"))
        #expect(payload.text.contains("-2.0"))
        #expect(payload.text.contains(ISO8601DateFormatter().string(from: timestamp)))
    }

    @Test("POSTs JSON to api.resend.com with a Bearer API key")
    func dispatchesHTTPRequest() async throws {
        let transport = RecordingHTTPTransport()
        let service = AlertMailService(
            configuration: AlertMailConfiguration(
                apiKey: "re_test_key",
                recipient: "founder@mavoid.com"
            ),
            transport: transport,
            environment: [:],
            secrets: EmptySecrets()
        )
        let report = EmergencyIncidentReport(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 1800,
            recipient: "founder@mavoid.com"
        )

        try await service.dispatchEmergencyIncident(report)

        #expect(transport.requests.count == 1)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.resend.com/emails")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer re_test_key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(request.httpBody)
        let decoded = try JSONDecoder().decode(ResendEmailPayload.self, from: body)
        #expect(decoded.to == ["founder@mavoid.com"])
        #expect(decoded.text.contains("1800"))
        #expect(!String(data: body, encoding: .utf8)!.contains("re_test_key"))
    }

    @Test("resolves API key from configuration, then environment, then Keychain")
    func resolvesAPIKeySources() {
        let secrets = DictionarySecrets(values: [
            "com.mavoid.zoidlockin.resend": ["api-key": "re_from_keychain"],
        ])

        let configured = ResendAPIKeyResolver(
            configuration: AlertMailConfiguration(apiKey: "re_configured", recipient: "a@b.c"),
            environment: ["ZOID_LOCK_IN_RESEND_API_KEY": "re_env"],
            secrets: secrets
        )
        #expect(configured.resolve() == "re_configured")

        let fromEnv = ResendAPIKeyResolver(
            configuration: AlertMailConfiguration(recipient: "a@b.c"),
            environment: ["ZOID_LOCK_IN_RESEND_API_KEY": "re_env"],
            secrets: secrets
        )
        #expect(fromEnv.resolve() == "re_env")

        let fromKeychain = ResendAPIKeyResolver(
            configuration: AlertMailConfiguration(recipient: "a@b.c"),
            environment: [:],
            secrets: secrets
        )
        #expect(fromKeychain.resolve() == "re_from_keychain")
    }

    @Test("refuses to send when no API key is configured")
    func missingAPIKey() async {
        let service = AlertMailService(
            configuration: AlertMailConfiguration(recipient: "founder@mavoid.com"),
            transport: RecordingHTTPTransport(),
            environment: [:],
            secrets: EmptySecrets()
        )
        do {
            try await service.dispatchEmergencyIncident(
                EmergencyIncidentReport(
                    timestamp: Date(),
                    durationSeconds: 1800,
                    recipient: "founder@mavoid.com"
                )
            )
            Issue.record("expected missing API key")
        } catch let error as AlertMailError {
            #expect(error == .missingAPIKey)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("pending emergency debt is -2.0 credits for the next reconciliation")
    func pendingDebtIsMinusTwo() {
        let store = InMemoryPendingDebtStore()
        store.record(.emergencyPenalty(at: 42))
        #expect(store.totalSignedCreditsPendingReconciliation() == -2.0)
        #expect(PendingDebtRecord.emergencyPenaltyCredits == -2.0)
        #expect(store.recordsPendingReconciliation()[0].reason == .emergencyPenalty)
    }

    @Test("admin unlock mail uses PRODUCT §6 verbatim warning copy")
    func adminUnlockMailUsesProductCopy() {
        let event = AdminAlertEvent(
            kind: .settingsUnlocked,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            recipient: "founder@mavoid.com",
            detail: "2FA settings unlocked"
        )
        let payload = AlertMailService.makeAdminPayload(
            event: event,
            from: "Zoid Lock In <alerts@mavoid.com>"
        )
        #expect(payload.subject == "CRITICAL: You entered Admin Dashboard. Stand firm.")
        #expect(payload.text.contains("CRITICAL SECURITY & INTEGRITY ALERT: You have authenticated into the Zoid 0 Trading Center Admin Settings."))
        #expect(payload.text.contains("Do not lower prices, grant unearned credits, or negotiate with weakness."))
        #expect(payload.text.contains("ADMIN_LOGIN"))
        #expect(payload.text.contains("2FA settings unlocked"))
        #expect(payload.to == ["founder@mavoid.com"])
    }
}

private struct EmptySecrets: SecretProviding {
    func secret(service: String, account: String) -> String? { nil }
}

private struct DictionarySecrets: SecretProviding {
    var values: [String: [String: String]]

    func secret(service: String, account: String) -> String? {
        values[service]?[account]
    }
}

private final class RecordingHTTPTransport: HTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var statusCode: Int = 200

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        remember(request)
        let response = HTTPURLResponse(
            url: request.url ?? AlertMailConfiguration.defaultEndpoint,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data("{}".utf8), response)
    }

    private func remember(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
}
