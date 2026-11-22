import XCTest
import AgentCore
@testable import ModelProviders

private final class SpyHTTPTransport: HTTPTransportProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var _lastRequest: URLRequest?
    private var _handler: (@Sendable (URLRequest, String) throws -> (Data, HTTPURLResponse))?

    var callCount: Int {
        lock.withLock { _callCount }
    }

    var lastRequest: URLRequest? {
        lock.withLock { _lastRequest }
    }

    func setHandler(_ handler: (@Sendable (URLRequest, String) throws -> (Data, HTTPURLResponse))?) {
        lock.withLock { _handler = handler }
    }

    func send(request: URLRequest, allowedHost: String) async throws -> (Data, HTTPURLResponse) {
        let currentHandler = lock.withLock { () -> (@Sendable (URLRequest, String) throws -> (Data, HTTPURLResponse))? in
            _callCount += 1
            _lastRequest = request
            return _handler
        }
        guard let currentHandler else {
            throw ModelProviderError.networkUnavailable
        }
        return try currentHandler(request, allowedHost)
    }
}

private struct StubAppleAdapter: AppleModelSessionAdapter {
    var availability: ModelAvailability
    var outcome: ModelTurnOutcome = .answer("Cihaz içi yanıt")
    var errorToThrow: Error?

    func currentAvailability(for locale: String) async -> ModelAvailability {
        availability
    }

    func runStructuredTurn(request: ModelTurnRequest) async throws -> ModelTurnOutcome {
        if let errorToThrow { throw errorToThrow }
        return outcome
    }
}

final class JarvisModelProvidersTests: XCTestCase {
    // MARK: - TaskComplexityClassifier

    func testTaskComplexityClassifierRoutesTier0Tier1AndTier2Accurately() {
        let classifier = TaskComplexityClassifier()

        let tier0Utterances = [
            "Şunu not al: Akşam süt al",
            "Not ekle: Sunum 14.30 kontrolü",
            "Bunu qeyd et: Sabah iclas sənədlərini yoxla",
            "Sabah 07.30'a alarm kur",
            "Sabah brifingi hazırla",
            "Günlük brifing"
        ]
        for utterance in tier0Utterances {
            let tier = classifier.classify(utterance: utterance, locale: "tr_TR")
            XCTAssertEqual(tier, .tier0Deterministic, "Expected Tier 0 for: \(utterance)")
        }

        let tier1Utterances = [
            "Deniz'e mesaj hazırla",
            "Cuma 15.00'e 30 dakikalık toplantı ekle",
            "Bakü Garı'na yol tarifi aç"
        ]
        for utterance in tier1Utterances {
            let tier = classifier.classify(utterance: utterance, locale: "tr_TR")
            XCTAssertEqual(tier, .tier1OnDevice, "Expected Tier 1 for: \(utterance)")
        }

        let multiStep = "Yarın 10'da Deniz'le 45 dakikalık toplantı ekle. Yarım saat önce sunumu açmamı hatırlat. Deniz'e de mesaj hazırla."
        XCTAssertEqual(classifier.classify(utterance: multiStep, locale: "tr_TR"), .tier2CloudReasoning)

        let complexReasoning = "Bu haftaki toplantılarımı analiz et ve öncelik sırasına göre stratejik bir planla."
        XCTAssertEqual(classifier.classify(utterance: complexReasoning, locale: "tr_TR"), .tier2CloudReasoning)
    }

    // MARK: - StrictEndpointValidator & PinnedHTTPSDelegate

    func testStrictEndpointValidatorBlocksSSRFAndHTTPAndAllowsValidHTTPS() throws {
        let blockedURLStrings = [
            "http://api.deepseek.com/v1/chat/completions",
            "https://localhost/v1/chat/completions",
            "https://api.localhost:8443/v1/chat/completions",
            "https://macmini.local/v1/chat/completions",
            "https://0.0.0.0/v1/chat/completions",
            "https://127.0.0.1/v1/chat/completions",
            "https://127.10.20.30/v1/chat/completions",
            "https://10.0.0.1/v1/chat/completions",
            "https://192.168.1.1/v1/chat/completions",
            "https://172.16.0.1/v1/chat/completions",
            "https://172.31.255.254/v1/chat/completions",
            "https://169.254.169.254/latest/meta-data",
            "https://[::1]/v1/chat/completions",
            "https://[fc00::1]/v1/chat/completions",
            "https://[fd12:3456::1]/v1/chat/completions",
            "https://[fe80::1]/v1/chat/completions",
            "https://[::ffff:127.0.0.1]/v1/chat/completions",
            "https://api.deepseek.com@127.0.0.1/v1/chat/completions",
            "https://2130706433/v1/chat/completions"
        ]

        for urlString in blockedURLStrings {
            let url = try XCTUnwrap(URL(string: urlString), "Invalid test URL: \(urlString)")
            XCTAssertFalse(StrictEndpointValidator.isValidRemoteHTTPS(url), "Should reject: \(urlString)")
            XCTAssertThrowsError(try StrictEndpointValidator.validateHTTPS(url: url), "Should throw for: \(urlString)")
        }

        let validURLs = [
            "https://api.deepseek.com/v1/chat/completions",
            "https://api.openai.com/v1/responses",
            "https://api.anthropic.com/v1/messages",
            "https://172.32.0.1/v1/chat/completions"
        ]
        for urlString in validURLs {
            let url = try XCTUnwrap(URL(string: urlString))
            XCTAssertTrue(StrictEndpointValidator.isValidRemoteHTTPS(url), "Should allow: \(urlString)")
            XCTAssertNoThrow(try StrictEndpointValidator.validateHTTPS(url: url))
        }
    }

    func testPinnedHTTPSDelegateBlocksCrossHostRedirectAndNormalizesSPKIPins() async throws {
        let pinBase64 = "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
        let delegate = PinnedHTTPSDelegate(
            allowedHost: "api.deepseek.com",
            pinnedSPKIHashes: ["sha256/\(pinBase64)"]
        )

        XCTAssertTrue(delegate.matchesPinnedSPKIHash(pinBase64))
        XCTAssertTrue(delegate.matchesPinnedSPKIHash("sha256/\(pinBase64)"))
        XCTAssertFalse(delegate.matchesPinnedSPKIHash("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="))

        let originURL = URL(string: "https://api.deepseek.com/v1/chat/completions")!
        let crossHostURL = URL(string: "https://evil.example.net/steal")!
        let privateRedirectURL = URL(string: "https://127.0.0.1/internal")!
        let sameHostURL = URL(string: "https://api.deepseek.com/v2/chat/completions")!

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let dummyTask = session.dataTask(with: URLRequest(url: originURL))
        let redirectResp = HTTPURLResponse(url: originURL, statusCode: 302, httpVersion: nil, headerFields: nil)!

        let crossHostExpectation = expectation(description: "Cross-host redirect blocked")
        delegate.urlSession(session, task: dummyTask, willPerformHTTPRedirection: redirectResp, newRequest: URLRequest(url: crossHostURL)) { req in
            XCTAssertNil(req)
            crossHostExpectation.fulfill()
        }

        let privateExpectation = expectation(description: "Private IP redirect blocked")
        delegate.urlSession(session, task: dummyTask, willPerformHTTPRedirection: redirectResp, newRequest: URLRequest(url: privateRedirectURL)) { req in
            XCTAssertNil(req)
            privateExpectation.fulfill()
        }

        let sameHostExpectation = expectation(description: "Same-host HTTPS redirect allowed")
        delegate.urlSession(session, task: dummyTask, willPerformHTTPRedirection: redirectResp, newRequest: URLRequest(url: sameHostURL)) { req in
            XCTAssertEqual(req?.url, sameHostURL)
            sameHostExpectation.fulfill()
        }

        await fulfillment(of: [crossHostExpectation, privateExpectation, sameHostExpectation], timeout: 2.0)
    }

    // MARK: - CircuitBreakerRegistry

    func testCircuitBreakerPermanentLatch401402VsExponentialBackoff429() async {
        let registry = CircuitBreakerRegistry(baseBackoffSeconds: 5.0, maxBackoffSeconds: 60.0)
        let baseDate = Date(timeIntervalSince1970: 1_795_000_000)

        let authKey = ProviderCircuitKey(providerID: "deepseek.reasoning", endpointHost: "api.deepseek.com")
        let initialState = await registry.state(for: authKey)
        XCTAssertEqual(initialState, .closed)
        let initialAttempt = await registry.canAttempt(for: authKey, now: baseDate)
        XCTAssertTrue(initialAttempt)

        // 401 kalıcı mandal -> uzak gelecekte bile açılmaz, ancak reset(for:) sonrası sıfırlanır.
        await registry.recordFailure(for: authKey, statusCode: 401, now: baseDate)
        let latchedState = await registry.state(for: authKey)
        XCTAssertEqual(latchedState, .open(until: .distantFuture, permanent: true))
        let attemptLater = await registry.canAttempt(for: authKey, now: baseDate.addingTimeInterval(86_400 * 365))
        XCTAssertFalse(attemptLater)

        await registry.reset(for: authKey)
        let resetState = await registry.state(for: authKey)
        XCTAssertEqual(resetState, .closed)
        let attemptAfterReset = await registry.canAttempt(for: authKey, now: baseDate)
        XCTAssertTrue(attemptAfterReset)

        // 402 yetersiz bakiye de kalıcı mandal kurar.
        await registry.recordFailure(for: authKey, statusCode: 402, now: baseDate)
        let balanceState = await registry.state(for: authKey)
        XCTAssertEqual(balanceState, .open(until: .distantFuture, permanent: true))
        let attemptBalance = await registry.canAttempt(for: authKey, now: baseDate.addingTimeInterval(3600))
        XCTAssertFalse(attemptBalance)

        // 429 geçici üstel soğuma (5s -> 10s) ve halfOpen -> closed toparlanma.
        let rateKey = ProviderCircuitKey(providerID: "openai.responses", endpointHost: "api.openai.com")
        await registry.recordFailure(for: rateKey, statusCode: 429, now: baseDate)
        let firstOpen = await registry.state(for: rateKey)
        XCTAssertEqual(firstOpen, .open(until: baseDate.addingTimeInterval(5.0), permanent: false))

        let attemptAt2s = await registry.canAttempt(for: rateKey, now: baseDate.addingTimeInterval(2.0))
        XCTAssertFalse(attemptAt2s)

        let attemptAt5s = await registry.canAttempt(for: rateKey, now: baseDate.addingTimeInterval(5.0))
        XCTAssertTrue(attemptAt5s)
        let halfOpenState = await registry.state(for: rateKey)
        XCTAssertEqual(halfOpenState, .halfOpen)

        // İkinci ardışık hata 10s bekletir.
        await registry.recordFailure(for: rateKey, statusCode: 429, now: baseDate.addingTimeInterval(5.0))
        let secondOpen = await registry.state(for: rateKey)
        XCTAssertEqual(secondOpen, .open(until: baseDate.addingTimeInterval(15.0), permanent: false))

        await registry.recordSuccess(for: rateKey)
        let recoveredState = await registry.state(for: rateKey)
        XCTAssertEqual(recoveredState, .closed)
    }

    // MARK: - SessionTokenLedger

    func testSessionTokenLedgerAccumulatesVerifiedTokensAndComputesTurkicMargin() async {
        let ledger = SessionTokenLedger()

        let trBudget = await ledger.safeOutputBudget(requestedMax: 600, locale: "tr_TR")
        let azBudget = await ledger.safeOutputBudget(requestedMax: 600, locale: "az_AZ")
        let enBudget = await ledger.safeOutputBudget(requestedMax: 600, locale: "en_US")
        XCTAssertEqual(trBudget, 900)
        XCTAssertEqual(azBudget, 900)
        XCTAssertEqual(enBudget, 600)

        await ledger.recordUsage(providerID: "deepseek.reasoning", promptTokens: 120, completionTokens: 45)
        await ledger.recordUsage(providerID: "deepseek.reasoning", promptTokens: 80, completionTokens: 55)
        await ledger.recordUsage(providerID: "anthropic.messages", promptTokens: 200, completionTokens: 100)

        let deepSeekUsage = await ledger.totalUsage(for: "deepseek.reasoning")
        XCTAssertEqual(deepSeekUsage.promptTokens, 200)
        XCTAssertEqual(deepSeekUsage.completionTokens, 100)
        XCTAssertEqual(deepSeekUsage.totalTokens, 300)
        XCTAssertEqual(deepSeekUsage.requestCount, 2)

        let overall = await ledger.overallTotals()
        XCTAssertEqual(overall.promptTokens, 400)
        XCTAssertEqual(overall.completionTokens, 200)
        XCTAssertEqual(overall.totalTokens, 600)
        XCTAssertEqual(overall.requestCount, 3)
    }

    // MARK: - ToolCallDeltaAccumulator & ToolSchemaRegistry

    func testToolCallDeltaAccumulatorHandlesSplitTurkishUTF8AndRejectsLengthOrRefusal() async throws {
        // Tüm ActionCatalog.allSpecs eylemleri wire şemasında kapsanmalıdır.
        XCTAssertEqual(ToolSchemaRegistry.wireToAction.count, ActionCatalog.allSpecs.count)
        XCTAssertEqual(ToolSchemaRegistry.allToolDefinitions().count, ActionCatalog.allSpecs.count)

        let fixedNow = Date(timeIntervalSince1970: 1_795_000_000)
        let taskId = UUID()

        // 1. Çok-baytlı Türkçe/Azerbaycanca UTF-8 karakterlerini bayt ortasından bölerek gönder.
        let accumulator = ToolCallDeltaAccumulator()
        let rawJSON = #"{"noteContent":"Şğüöçıİə çok baytlı test"}"#
        let fullBytes = Data(rawJSON.utf8)

        await accumulator.ingest(.toolCallStarted(index: 0, id: "s1", name: "notes_create"))
        // 3 baytlık parçalara bölerek multi-byte karakter sınırlarını kasıtlı kes
        var offset = 0
        while offset < fullBytes.count {
            let end = min(offset + 3, fullBytes.count)
            let chunk = fullBytes.subdata(in: offset..<end)
            await accumulator.ingest(.argumentsDelta(index: 0, utf8Fragment: chunk))
            offset = end
        }
        await accumulator.ingest(.terminated(reason: .toolCalls))
        await accumulator.ingest(.completedSentinel)

        let result = await accumulator.finalize(taskId: taskId, revisionNumber: 1, now: fixedNow)
        guard case .validPlan(let revision) = result else {
            return XCTFail("Expected validPlan, got: \(result)")
        }
        XCTAssertEqual(revision.steps.count, 1)
        XCTAssertEqual(revision.steps.first?.action, .notesCreate)
        XCTAssertEqual(revision.steps.first?.parameters.noteContent, "Şğüöçıİə çok baytlı test")

        // 2. finish_reason == "length" tamponu imha etmeli ve sıfır adım döndürmelidir.
        let truncatedAcc = ToolCallDeltaAccumulator()
        await truncatedAcc.ingest(.toolCallStarted(index: 0, id: "s1", name: "notes_create"))
        await truncatedAcc.ingest(.argumentsDelta(index: 0, utf8Fragment: Data(#"{"noteContent":"Yarım"#.utf8)))
        await truncatedAcc.ingest(.terminated(reason: .init(wireReason: "length")))
        await truncatedAcc.ingest(.completedSentinel)

        let bytesAfterTruncate = await truncatedAcc.bufferedArgumentBytesCount
        XCTAssertEqual(bytesAfterTruncate, 0)
        let truncatedResult = await truncatedAcc.finalize(taskId: taskId, revisionNumber: 1, now: fixedNow)
        guard case .truncatedOrInvalid = truncatedResult else {
            return XCTFail("Expected truncatedOrInvalid on length termination")
        }

        // 3. Eksik sentinel reddedilmelidir.
        let missingSentinelAcc = ToolCallDeltaAccumulator()
        await missingSentinelAcc.ingest(.toolCallStarted(index: 0, id: "s1", name: "notes_create"))
        await missingSentinelAcc.ingest(.argumentsDelta(index: 0, utf8Fragment: Data(#"{"noteContent":"Tam"}"#.utf8)))
        await missingSentinelAcc.ingest(.terminated(reason: .toolCalls))
        let missingSentinelResult = await missingSentinelAcc.finalize(taskId: taskId, revisionNumber: 1, now: fixedNow)
        guard case .truncatedOrInvalid = missingSentinelResult else {
            return XCTFail("Expected truncatedOrInvalid when sentinel is missing")
        }

        // 4. Güvenlik reddi (refusal) tamponu imha etmeli ve .safetyRefusal döndürmelidir.
        let refusalAcc = ToolCallDeltaAccumulator()
        await refusalAcc.ingest(.toolCallStarted(index: 0, id: "s1", name: "notes_create"))
        await refusalAcc.ingest(.argumentsDelta(index: 0, utf8Fragment: Data(#"{"noteContent":"yasak"}"#.utf8)))
        await refusalAcc.ingest(.refusal("Güvenlik ilkesi reddi"))
        await refusalAcc.ingest(.completedSentinel)

        let refusalBytes = await refusalAcc.bufferedArgumentBytesCount
        XCTAssertEqual(refusalBytes, 0)
        let refusalResult = await refusalAcc.finalize(taskId: taskId, revisionNumber: 1, now: fixedNow)
        XCTAssertEqual(refusalResult, .safetyRefusal("Güvenlik ilkesi reddi"))

        // 5. Beyaz listede olmayan araç adı reddedilmelidir.
        let unknownToolAcc = ToolCallDeltaAccumulator()
        await unknownToolAcc.ingest(.toolCallStarted(index: 0, id: "s1", name: "shell_exec"))
        await unknownToolAcc.ingest(.argumentsDelta(index: 0, utf8Fragment: Data(#"{"cmd":"rm"}"#.utf8)))
        await unknownToolAcc.ingest(.terminated(reason: .toolCalls))
        await unknownToolAcc.ingest(.completedSentinel)
        let unknownToolResult = await unknownToolAcc.finalize(taskId: taskId, revisionNumber: 1, now: fixedNow)
        guard case .truncatedOrInvalid = unknownToolResult else {
            return XCTFail("Expected truncatedOrInvalid for unknown tool")
        }
    }

    // MARK: - Protocol Adapters (OpenAI Responses, Anthropic Messages, DeepSeek, Offline)

    func testProtocolAdaptersWireRequestsResponsesAndTokenLedger() async throws {
        let keyStore = InMemorySecretStore()
        try keyStore.saveKey("test-key-openai", forHost: "api.openai.com")
        try keyStore.saveKey("test-key-anthropic", forHost: "api.anthropic.com")
        try keyStore.saveKey("test-key-deepseek", forHost: "api.deepseek.com")

        let ledger = SessionTokenLedger()
        let transport = SpyHTTPTransport()

        // 1. OpenAI Responses API (/v1/responses, store: false, all ActionCatalog tools)
        let openAI = OpenAIResponsesProvider(keyStore: keyStore, transport: transport, tokenLedger: ledger)
        let responsesPayload = """
        {
          "status": "completed",
          "output": [{
            "type": "function_call",
            "call_id": "call_1",
            "name": "alarm_create",
            "arguments": "{\\"title\\":\\"Sabah Alarmı\\",\\"dueISO8601\\":\\"2026-11-22T07:30:00+04:00\\"}"
          }],
          "usage": { "input_tokens": 110, "output_tokens": 30 }
        }
        """.data(using: .utf8)!
        transport.setHandler { req, host in
            XCTAssertEqual(host, "api.openai.com")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-key-openai")
            let bodyObj = try JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any]
            XCTAssertEqual(bodyObj?["store"] as? Bool, false)
            let tools = bodyObj?["tools"] as? [[String: Any]]
            XCTAssertEqual(tools?.count, ActionCatalog.allSpecs.count)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (responsesPayload, resp)
        }
        let openAIOutcome = try await openAI.generateTurn(
            request: ModelTurnRequest(taskId: UUID(), utterance: "Sabah 07:30'a alarm kur", referenceDateISO8601: "2026-11-21T12:00:00+04:00")
        )
        guard case .proposedPlan(let openAISteps) = openAIOutcome else {
            return XCTFail("Expected proposedPlan from OpenAIResponsesProvider")
        }
        XCTAssertEqual(openAISteps.first?.action, "alarm.create")

        // 2. Anthropic Messages API (/v1/messages, x-api-key, 529 overloaded)
        let anthropic = AnthropicMessagesProvider(keyStore: keyStore, transport: transport, tokenLedger: ledger)
        let anthropicPayload = """
        {
          "stop_reason": "tool_use",
          "content": [
            { "type": "thinking", "thinking": "Kullanıcı hafıza kaydı istiyor." },
            { "type": "tool_use", "id": "toolu_1", "name": "memory_remember", "input": { "noteContent": "Kahvemi şekersiz içerim" } }
          ],
          "usage": { "input_tokens": 140, "output_tokens": 40 }
        }
        """.data(using: .utf8)!
        transport.setHandler { req, host in
            XCTAssertEqual(host, "api.anthropic.com")
            XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "test-key-anthropic")
            XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), AnthropicMessagesProvider.anthropicVersion)
            let bodyObj = try JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any]
            let tools = bodyObj?["tools"] as? [[String: Any]]
            XCTAssertEqual(tools?.count, ActionCatalog.allSpecs.count)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (anthropicPayload, resp)
        }
        let anthropicOutcome = try await anthropic.generateTurn(
            request: ModelTurnRequest(taskId: UUID(), utterance: "Bunu hatırla: Kahvemi şekersiz içerim", referenceDateISO8601: "2026-11-21T12:00:00+04:00")
        )
        guard case .proposedPlan(let anthropicSteps) = anthropicOutcome else {
            return XCTFail("Expected proposedPlan from AnthropicMessagesProvider")
        }
        XCTAssertEqual(anthropicSteps.first?.action, "memory.remember")

        // Anthropic 529 overloaded -> rateLimited
        transport.setHandler { req, _ in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 529, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }
        do {
            _ = try await anthropic.generateTurn(
                request: ModelTurnRequest(taskId: UUID(), utterance: "Test", referenceDateISO8601: "2026-11-21T12:00:00+04:00")
            )
            XCTFail("Expected rateLimited for 529")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error, .rateLimited)
        }

        // 3. DeepSeek SSE streaming consumption
        let sseLines = [
            #"data: {"choices":[{"delta":{"reasoning_content":"Analiz ediliyor... "}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"ds_1","function":{"name":"briefing_compose","arguments":"{\"title\":\"Sab"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ah Brifingi\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":90,"completion_tokens":20}}"#,
            "data: [DONE]"
        ]
        let sseOutcome = await DeepSeekProvider.consumeSSELines(sseLines)
        XCTAssertEqual(sseOutcome.reasoningContent, "Analiz ediliyor... ")
        XCTAssertEqual(sseOutcome.usage?.promptTokens, 90)
        XCTAssertEqual(sseOutcome.usage?.completionTokens, 20)
        guard case .validPlan(let sseRev) = sseOutcome.result else {
            return XCTFail("Expected validPlan from DeepSeek SSE")
        }
        XCTAssertEqual(sseRev.steps.first?.action, .briefingCompose)

        // Ledger doğrulanmış token toplamları
        let total = await ledger.overallTotals()
        XCTAssertEqual(total.promptTokens, 250)
        XCTAssertEqual(total.completionTokens, 70)
    }

    // MARK: - ExternalDataConsentManager Host Isolation

    func testExternalDataConsentManagerHostIsolationAndLegacyCompatibility() {
        let consent = ExternalDataConsentManager()

        XCTAssertEqual(ExternalDataScope.approvedMemoryContext.displayTitleTR, "Onaylı hafıza özeti")
        XCTAssertEqual(ExternalDataScope.sharedDocumentOCRText.displayTitleTR, "Paylaşılan belge OCR metni")
        XCTAssertEqual(ExternalDataScope.visualImagePayload.displayTitleTR, "Görsel içerik verisi")

        let hostAKey = ProviderConsentKey(providerID: "custom.llm", endpointHost: "api.trusted-a.com")
        let hostBKey = ProviderConsentKey(providerID: "custom.llm", endpointHost: "api.other-b.com")

        consent.grantConsent(for: hostAKey, scopes: [.commandTextOnly, .approvedMemoryContext])
        XCTAssertTrue(consent.isConsentGranted(for: hostAKey, scope: .commandTextOnly))
        XCTAssertTrue(consent.isConsentGranted(for: hostAKey, scope: .approvedMemoryContext))
        // Aynı providerID fakat farklı endpointHost kesinlikle reddedilmelidir!
        XCTAssertFalse(consent.isConsentGranted(for: hostBKey, scope: .commandTextOnly))
        XCTAssertFalse(consent.isConsentGranted(for: hostAKey, scope: .visualImagePayload))

        // Farklı hosta geçildiğinde önceki izin geçersiz kalır.
        consent.switchProvider(to: hostBKey)
        XCTAssertFalse(consent.isConsentGranted(for: hostAKey, scope: .commandTextOnly))

        // Eski tekil providerID API'si %100 korunmalıdır.
        consent.grantConsent(forProviderID: "deepseek.chat", scopes: [.commandTextOnly])
        XCTAssertTrue(consent.isConsentGranted(forProviderID: "deepseek.chat", scope: .commandTextOnly))
        consent.revokeConsent()
        XCTAssertFalse(consent.isConsentGranted(forProviderID: "deepseek.chat", scope: .commandTextOnly))
    }

    // MARK: - HybridModelRouter Integration

    func testHybridModelRouterZeroNetworkTier0FallbackAndSafetyRefusalIsolation() async throws {
        let keyStore = InMemorySecretStore()
        let deepSeekURL = URL(string: "https://api.deepseek.com/v1/chat/completions")!
        try keyStore.saveKey("test-ds-key", forHost: "api.deepseek.com")

        let transport = SpyHTTPTransport()
        let ledger = SessionTokenLedger()
        let circuit = CircuitBreakerRegistry(baseBackoffSeconds: 10, maxBackoffSeconds: 60)
        let consent = ExternalDataConsentManager()
        let thermal = MockThermalStateProvider(state: .nominal)

        let deepSeek = DeepSeekProvider(keyStore: keyStore, transport: transport, tokenLedger: ledger)
        let appleDisabled = AppleFoundationModelProvider(adapter: StubAppleAdapter(availability: .disabledInSettings))

        let router = HybridModelRouter(
            onDeviceProvider: appleDisabled,
            externalEndpoints: [
                ExternalModelEndpoint(provider: deepSeek, endpointURL: deepSeekURL, protocolKind: .deepSeekReasoning)
            ],
            consentManager: consent,
            circuitRegistry: circuit,
            tokenLedger: ledger,
            thermalStateProvider: thermal
        )

        // 1. Tier-0 sabit komut dış ağa ve izne hiç dokunmaz.
        let tier0Result = try await router.routeAndGenerate(
            request: ModelTurnRequest(taskId: UUID(), utterance: "Sabah brifingi hazırla", referenceDateISO8601: "2026-11-21T08:00:00+04:00"),
            preference: .automatic
        )
        XCTAssertEqual(tier0Result.tier, .tier0Deterministic)
        XCTAssertEqual(transport.callCount, 0)

        // 2. Tier-2 komut izinsizken 0 ağ çağrısı ile consentRequired verir.
        let complexReq = ModelTurnRequest(
            taskId: UUID(),
            utterance: "Haftalık toplantılarımı analiz et ve stratejik bir planla.",
            referenceDateISO8601: "2026-11-21T08:00:00+04:00"
        )
        do {
            _ = try await router.routeAndGenerate(request: complexReq, preference: .automatic)
            XCTFail("Expected consentRequired")
        } catch let err as ModelProviderError {
            XCTAssertEqual(err, .consentRequired)
        }
        XCTAssertEqual(transport.callCount, 0)

        // 3. Farklı host için verilen izin DeepSeek hostunda geçerli sayılmaz.
        consent.grantConsent(
            for: ProviderConsentKey(providerID: deepSeek.providerID, endpointHost: "wrong.host.example.com"),
            scopes: [.commandTextOnly]
        )
        do {
            _ = try await router.routeAndGenerate(request: complexReq, preference: .automatic)
            XCTFail("Expected consentRequired for mismatched host")
        } catch let err as ModelProviderError {
            XCTAssertEqual(err, .consentRequired)
        }
        XCTAssertEqual(transport.callCount, 0)

        // 4. Doğru host izni + 401 -> kalıcı devre kesici mandalı.
        consent.grantConsent(
            for: ProviderConsentKey(providerID: deepSeek.providerID, endpointHost: "api.deepseek.com"),
            scopes: [.commandTextOnly]
        )
        transport.setHandler { req, _ in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }
        do {
            _ = try await router.routeAndGenerate(request: complexReq, preference: .automatic)
            XCTFail("Expected invalidAPIKey")
        } catch let err as ModelProviderError {
            XCTAssertEqual(err, .invalidAPIKey)
        }
        let circuitKey = ProviderCircuitKey(providerID: deepSeek.providerID, endpointHost: "api.deepseek.com")
        let latchedState = await router.circuitState(for: circuitKey)
        XCTAssertEqual(latchedState, .open(until: .distantFuture, permanent: true))

        // Kalıcı mandal varken sonraki istek ağa hiç çıkmaz.
        let callsBeforeBlocked = transport.callCount
        do {
            _ = try await router.routeAndGenerate(request: complexReq, preference: .automatic)
            XCTFail("Expected circuit to block request")
        } catch let err as ModelProviderError {
            XCTAssertEqual(err, .invalidAPIKey)
        }
        XCTAssertEqual(transport.callCount, callsBeforeBlocked)

        // 5. Devre sıfırlandıktan sonra safetyRefusal asla fallback'e düşmez.
        await router.resetCircuit(for: circuitKey)
        let refusalPayload = """
        {
          "choices": [{
            "finish_reason": "stop",
            "message": { "refusal": "Güvenlik engeli" }
          }]
        }
        """.data(using: .utf8)!
        transport.setHandler { req, _ in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (refusalPayload, resp)
        }
        do {
            _ = try await router.routeAndGenerate(
                request: ModelTurnRequest(taskId: UUID(), utterance: "Sabah 07.30'a alarm kur ve analiz et", referenceDateISO8601: "2026-11-21T08:00:00+04:00"),
                preference: .automatic
            )
            XCTFail("Expected safetyRefusal")
        } catch let err as ModelProviderError {
            XCTAssertEqual(err, .safetyRefusal("Güvenlik engeli"))
        }

        // 6. finish_reason == "length" kesik yanıtı Tier-0 uyumlu komutta OfflineDeterministicFallbackProvider'a düşer,
        // Tier-0 dışı komutta ise truncatedOrMalformedJSON fırlatır.
        let truncatedPayload = """
        {
          "choices": [{
            "finish_reason": "length",
            "message": { "content": "{\\"kind\\": \\"plan\\"" }
          }]
        }
        """.data(using: .utf8)!
        transport.setHandler { req, _ in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (truncatedPayload, resp)
        }
        let fallbackResult = try await router.routeAndGenerate(
            request: ModelTurnRequest(
                taskId: UUID(),
                utterance: "Sabah 07.30'a alarm kur ve sonra toplantıları analiz et",
                referenceDateISO8601: "2026-11-21T08:00:00+04:00"
            ),
            preference: .automatic
        )
        XCTAssertTrue(fallbackResult.usedFallback)
        XCTAssertEqual(fallbackResult.tier, .tier0Deterministic)
        if case .proposedPlan(let fallbackSteps) = fallbackResult.outcome {
            XCTAssertEqual(fallbackSteps.first?.action, "alarm.create")
        } else {
            XCTFail("Expected Tier-0 alarm.create fallback")
        }

        do {
            _ = try await router.routeAndGenerate(request: complexReq, preference: .automatic)
            XCTFail("Expected truncatedOrMalformedJSON when Tier-0 cannot satisfy complex request")
        } catch let err as ModelProviderError {
            XCTAssertEqual(err, .truncatedOrMalformedJSON)
        }

        // 7. Termal kritik durumda cihaz içi model atlanır, SSRF uç noktası kesin reddedilir.
        thermal.setState(.critical)
        let appleAvailable = AppleFoundationModelProvider(adapter: StubAppleAdapter(availability: .available(label: "Apple Intelligence")))
        let ssrfRouter = HybridModelRouter(
            onDeviceProvider: appleAvailable,
            externalEndpoints: [
                ExternalModelEndpoint(
                    provider: deepSeek,
                    endpointURL: URL(string: "http://127.0.0.1:8080/v1/chat/completions")!,
                    protocolKind: .deepSeekReasoning
                )
            ],
            consentManager: consent,
            thermalStateProvider: thermal
        )
        do {
            _ = try await ssrfRouter.routeAndGenerate(
                request: ModelTurnRequest(taskId: UUID(), utterance: "Deniz'e mesaj hazırla", referenceDateISO8601: "2026-11-21T08:00:00+04:00"),
                preference: .automatic
            )
            XCTFail("Expected EndpointValidationError for SSRF endpoint")
        } catch let err as EndpointValidationError {
            XCTAssertEqual(err, .insecureScheme("http"))
        }
    }

    // MARK: - DeterministicScenarioModelProvider New JARVIS Routes

    func testDeterministicScenarioModelProviderNewJarvisRoutesPassPlanValidator() async throws {
        let provider = DeterministicScenarioModelProvider(allowInCurrentBuild: true)
        let fixedNow = Date(timeIntervalSince1970: 1_795_000_000)
        let refISO = "2026-11-21T12:00:00+04:00"

        let cases: [(utterance: String, expectedAction: String, expectedStepID: String)] = [
            ("Sabah brifingi", "briefing.compose", "brief1"),
            ("Günlük brifing hazırla", "briefing.compose", "brief1"),
            ("Akşam brifingi ver", "briefing.compose", "brief1"),
            ("Hafızaya kaydet: Kahvemi şekersiz içerim", "memory.remember", "mem_w"),
            ("Bunu hatırla: Sabahları erken toplantı sevmem", "memory.remember", "mem_w"),
            ("Yaddaşda saxla: İş görüşlərini gündüzə sal", "memory.remember", "mem_w"),
            ("Hafızadan bul: kahve", "memory.recall", "mem_r"),
            ("Tercihlerimi göster", "memory.recall", "mem_r"),
            ("Alarm kur", "alarm.create", "alm1")
        ]

        for testCase in cases {
            let req = ModelTurnRequest(taskId: UUID(), utterance: testCase.utterance, referenceDateISO8601: refISO)
            let outcome = try await provider.generateTurn(request: req)
            guard case .proposedPlan(let rawSteps) = outcome else {
                XCTFail("Expected proposedPlan for: \(testCase.utterance)")
                continue
            }
            XCTAssertEqual(rawSteps.first?.id, testCase.expectedStepID)
            XCTAssertEqual(rawSteps.first?.action, testCase.expectedAction)

            let revision = try PlanValidator.validateAndBuildRevision(
                taskId: req.taskId,
                revisionNumber: 1,
                rawSteps: rawSteps,
                now: fixedNow
            )
            XCTAssertEqual(revision.steps.count, 1)
        }
    }
}
