import XCTest
import AgentCore
@testable import ModelProviders

private final class RecordingHTTPTransport: HTTPTransportProtocol, @unchecked Sendable {
    var callCount = 0
    var handler: ((URLRequest, String) throws -> (Data, HTTPURLResponse))?

    func send(request: URLRequest, allowedHost: String) async throws -> (Data, HTTPURLResponse) {
        callCount += 1
        guard let handler else {
            throw ModelProviderError.networkUnavailable
        }
        return try handler(request, allowedHost)
    }
}

private struct MockAppleAdapter: AppleModelSessionAdapter {
    var availability: ModelAvailability
    var outcome: ModelTurnOutcome = .proposedPlan([
        RawModelStepInput(
            id: "n1",
            action: "notes.create",
            parameters: ActionParameters(noteContent: "Uçak modu çevrimdışı notu")
        )
    ])
    var errorToThrow: Error?

    func currentAvailability(for locale: String) async -> ModelAvailability {
        availability
    }

    func runStructuredTurn(request: ModelTurnRequest) async throws -> ModelTurnOutcome {
        if let errorToThrow { throw errorToThrow }
        return outcome
    }
}

final class ModelProvidersStage3Tests: XCTestCase {
    func testAppleOfflineModelGeneratesNoteWithZeroCloudCalls() async throws {
        let apple = AppleFoundationModelProvider(
            adapter: MockAppleAdapter(availability: .available(label: "Apple Intelligence · Bu iPhone"))
        )
        let transport = RecordingHTTPTransport()
        let keyStore = InMemorySecretStore()
        try keyStore.saveKey("sk-test", forHost: "api.deepseek.com")
        let external = ExternalChatCompletionsProvider(keyStore: keyStore, transport: transport)
        let consent = ExternalDataConsentManager()

        let router = ModelRouter(onDeviceProvider: apple, externalProvider: external, consentManager: consent)
        let request = ModelTurnRequest(
            taskId: UUID(),
            utterance: "Şunu not al: Uçak modu çevrimdışı notu",
            referenceDateISO8601: "2026-11-21T12:00:00+04:00"
        )
        let (label, outcome) = try await router.routeAndGenerate(request: request, preference: .automatic)

        XCTAssertEqual(label, "Apple Intelligence · Bu iPhone")
        XCTAssertEqual(transport.callCount, 0)
        guard case .proposedPlan(let steps) = outcome else {
            return XCTFail("Expected proposedPlan")
        }
        XCTAssertEqual(steps.first?.action, "notes.create")
    }

    func testConsentDeniedProducesZeroNetworkCallsAndSafetyRefusalDoesNotFallback() async throws {
        let appleDisabled = AppleFoundationModelProvider(
            adapter: MockAppleAdapter(availability: .disabledInSettings)
        )
        let transport = RecordingHTTPTransport()
        let keyStore = InMemorySecretStore()
        try keyStore.saveKey("sk-test", forHost: "api.deepseek.com")
        let external = ExternalChatCompletionsProvider(keyStore: keyStore, transport: transport)
        let consent = ExternalDataConsentManager()

        let router = ModelRouter(onDeviceProvider: appleDisabled, externalProvider: external, consentManager: consent)
        let request = ModelTurnRequest(
            taskId: UUID(),
            utterance: "Şunu not al: Test",
            referenceDateISO8601: "2026-11-21T12:00:00+04:00"
        )

        do {
            _ = try await router.routeAndGenerate(request: request, preference: .automatic)
            XCTFail("Expected consentRequired")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error, .consentRequired)
        }
        XCTAssertEqual(transport.callCount, 0)

        // Grant consent then revoke -> still 0 calls after revoke
        consent.grantConsent(forProviderID: external.providerID, scopes: [.commandTextOnly])
        consent.revokeConsent()
        do {
            _ = try await router.routeAndGenerate(request: request, preference: .customProvider)
            XCTFail("Expected consentRequired after revoke")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error, .consentRequired)
        }
        XCTAssertEqual(transport.callCount, 0)

        // Safety refusal on Apple model must NOT fallback to external provider
        let appleSafetyRefusal = AppleFoundationModelProvider(
            adapter: MockAppleAdapter(
                availability: .available(label: "Apple Intelligence · Bu iPhone"),
                errorToThrow: ModelProviderError.safetyRefusal("Güvenlik politikası")
            )
        )
        consent.grantConsent(forProviderID: external.providerID, scopes: [.commandTextOnly])
        let safetyRouter = ModelRouter(onDeviceProvider: appleSafetyRefusal, externalProvider: external, consentManager: consent)
        do {
            _ = try await safetyRouter.routeAndGenerate(request: request, preference: .automatic)
            XCTFail("Expected safetyRefusal")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error, .safetyRefusal("Güvenlik politikası"))
        }
        XCTAssertEqual(transport.callCount, 0)
    }

    func testCustomHTTPSProfileTruncatedJSONAndRedirectBlocking() async throws {
        let transport = RecordingHTTPTransport()
        let keyStore = InMemorySecretStore()
        let customURL = URL(string: "https://llm.example.com/v1/chat/completions")!
        try keyStore.saveKey("sk-custom", forHost: "llm.example.com")
        let provider = ExternalChatCompletionsProvider(
            profile: .customHTTPS(displayName: "Özel Uç Nokta", endpointURL: customURL, modelID: "custom-v1"),
            keyStore: keyStore,
            transport: transport
        )

        // 1. Valid tool call response
        let validJSON = """
        {
          "choices": [{
            "finish_reason": "tool_calls",
            "message": {
              "tool_calls": [{
                "function": {
                  "name": "notes_create",
                  "arguments": "{\\"noteContent\\": \\"Özel sunucu notu\\"}"
                }
              }]
            }
          }]
        }
        """.data(using: .utf8)!

        transport.handler = { req, host in
            XCTAssertEqual(host, "llm.example.com")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (validJSON, resp)
        }
        let verified = try await provider.verifyConnectionWithoutPersonalData()
        XCTAssertTrue(verified)

        // 2. Truncated finish_reason == "length" must fail and never execute
        let truncatedJSON = """
        {
          "choices": [{
            "finish_reason": "length",
            "message": { "content": "{\\"kind\\": \\"plan\\"" }
          }]
        }
        """.data(using: .utf8)!
        transport.handler = { req, _ in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (truncatedJSON, resp)
        }
        do {
            _ = try await provider.generateTurn(
                request: ModelTurnRequest(taskId: UUID(), utterance: "Not ekle", referenceDateISO8601: "2026-11-21T12:00:00Z")
            )
            XCTFail("Truncated response must throw")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error, .truncatedOrMalformedJSON)
        }

        // 3. Redirect delegate blocks cross-host redirects
        let delegate = RedirectBlockingSessionDelegate(allowedHost: "llm.example.com")
        let redirectURL = URL(string: "https://evil.example.net/steal")!
        let redirectReq = URLRequest(url: redirectURL)
        let session = URLSession(configuration: .ephemeral)
        let dummyTask = session.dataTask(with: URLRequest(url: customURL))
        let dummyResp = HTTPURLResponse(url: customURL, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let expectation = expectation(description: "Redirect blocked")
        delegate.urlSession(session, task: dummyTask, willPerformHTTPRedirection: dummyResp, newRequest: redirectReq) { result in
            XCTAssertNil(result)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2.0)

        // 4. Deterministic test provider refuses production build
        let prodProvider = DeterministicScenarioModelProvider(allowInCurrentBuild: false)
        do {
            _ = try await prodProvider.generateTurn(
                request: ModelTurnRequest(taskId: UUID(), utterance: "Not ekle", referenceDateISO8601: "2026-11-21T12:00:00Z")
            )
            XCTFail("Must fail in production config")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error, .unsupportedInProductionBuild)
        }
    }
}
