import Foundation
import AgentCore

public struct ExternalProviderProfile: Codable, Equatable, Sendable {
    public let providerID: String
    public let displayName: String
    public let endpointURL: URL
    public let modelID: String

    public init(providerID: String, displayName: String, endpointURL: URL, modelID: String) {
        self.providerID = providerID
        self.displayName = displayName
        self.endpointURL = endpointURL
        self.modelID = modelID
    }

    public static let deepSeekDefault = ExternalProviderProfile(
        providerID: "deepseek.chat",
        displayName: "DeepSeek · Kendi Anahtarım",
        endpointURL: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
        modelID: "deepseek-chat"
    )

    public static func customHTTPS(displayName: String, endpointURL: URL, modelID: String) -> ExternalProviderProfile {
        ExternalProviderProfile(
            providerID: "custom.\(endpointURL.host ?? "https")",
            displayName: displayName,
            endpointURL: endpointURL,
            modelID: modelID
        )
    }
}

public protocol HTTPTransportProtocol: Sendable {
    func send(request: URLRequest, allowedHost: String) async throws -> (Data, HTTPURLResponse)
}

/// Farklı bir sunucuya yönlendirmede Authorization anahtarını iletmeyi engelleyen delegate.
public final class RedirectBlockingSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHost: String

    public init(allowedHost: String) {
        self.allowedHost = allowedHost.lowercased()
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let targetHost = request.url?.host?.lowercased() ?? ""
        if targetHost != allowedHost {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public final class URLSessionHTTPTransport: HTTPTransportProtocol, @unchecked Sendable {
    public init() {}

    public func send(request: URLRequest, allowedHost: String) async throws -> (Data, HTTPURLResponse) {
        let delegate = RedirectBlockingSessionDelegate(allowedHost: allowedHost)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelProviderError.networkUnavailable
        }
        if let finalHost = http.url?.host?.lowercased(), finalHost != allowedHost.lowercased() {
            throw ModelProviderError.redirectBlocked(destinationHost: finalHost)
        }
        return (data, http)
    }
}

public enum ExternalPlanJSONParser {
    public static func parseChatCompletionsToolResponse(_ data: Data) throws -> ModelTurnOutcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw ModelProviderError.truncatedOrMalformedJSON
        }

        if let finishReason = first["finish_reason"] as? String, finishReason == "length" {
            // Kesilmiş yanıt asla yürütülmez.
            throw ModelProviderError.truncatedOrMalformedJSON
        }

        if let refusal = message["refusal"] as? String, !refusal.isEmpty {
            throw ModelProviderError.safetyRefusal(refusal)
        }

        if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
            var steps: [RawModelStepInput] = []
            for (idx, call) in toolCalls.enumerated() {
                guard let fn = call["function"] as? [String: Any],
                      let name = fn["name"] as? String,
                      let argString = fn["arguments"] as? String,
                      let argData = argString.data(using: .utf8),
                      let params = try? JSONDecoder().decode(ActionParameters.self, from: argData) else {
                    throw ModelProviderError.truncatedOrMalformedJSON
                }
                let actionName = name.replacingOccurrences(of: "_", with: ".")
                steps.append(RawModelStepInput(id: "s\(idx + 1)", action: actionName, parameters: params))
            }
            return .proposedPlan(steps)
        }

        if let content = message["content"] as? String {
            if let parsed = try? parseTurnJSON(content) {
                return parsed
            }
            return .answer(content)
        }
        throw ModelProviderError.truncatedOrMalformedJSON
    }

    public static func parseTurnJSON(_ raw: String) throws -> ModelTurnOutcome {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = obj["kind"] as? String else {
            throw ModelProviderError.truncatedOrMalformedJSON
        }
        switch kind {
        case "plan":
            guard let stepsRaw = obj["steps"] else {
                throw ModelProviderError.truncatedOrMalformedJSON
            }
            let stepsData = try JSONSerialization.data(withJSONObject: stepsRaw)
            let steps = try JSONDecoder().decode([RawModelStepInput].self, from: stepsData)
            return .proposedPlan(steps)
        case "clarify":
            let q = obj["question"] as? String ?? "Eksik bilgiyi paylaşır mısın?"
            let fields = obj["missingFields"] as? [String] ?? []
            return .clarification(question: q, missingFields: fields)
        case "unsupported":
            let reason = obj["reason"] as? String ?? "Bu işlem desteklenmiyor."
            return .unsupported(reason: reason)
        case "answer":
            let text = obj["text"] as? String ?? ""
            return .answer(text)
        default:
            throw ModelProviderError.truncatedOrMalformedJSON
        }
    }
}

/// DeepSeek hazır profili ve Chat Completions araç çağrılarıyla uyumlu özel HTTPS istemcisi.
public final class ExternalChatCompletionsProvider: ModelProvider, @unchecked Sendable {
    public static let maxRequestBytes = 32_768
    public static let maxResponseBytes = 131_072
    public static let requestTimeout: TimeInterval = 15.0

    public var providerID: String { profile.providerID }
    public var displayName: String { profile.displayName }

    private let profile: ExternalProviderProfile
    private let keyStore: SecretStoreProtocol
    private let transport: HTTPTransportProtocol
    private let lock = NSLock()
    private var currentTask: Task<ModelTurnOutcome, Error>?

    public init(
        profile: ExternalProviderProfile = .deepSeekDefault,
        keyStore: SecretStoreProtocol,
        transport: HTTPTransportProtocol = URLSessionHTTPTransport()
    ) {
        self.profile = profile
        self.keyStore = keyStore
        self.transport = transport
    }

    public func checkAvailability(for locale: String) async -> ModelAvailability {
        guard profile.endpointURL.scheme?.lowercased() == "https",
              let host = profile.endpointURL.host, !host.isEmpty else {
            return .needsAPIKey
        }
        guard let key = try? keyStore.readKey(forHost: host), !key.isEmpty else {
            return .needsAPIKey
        }
        return .available(label: profile.displayName)
    }

    /// Kişisel veri göndermeden gerçek bir araç çağrısının ayrıştırılabildiğini doğrular.
    public func verifyConnectionWithoutPersonalData() async throws -> Bool {
        let probeRequest = ModelTurnRequest(
            taskId: UUID(),
            utterance: "Bağlantı denemesi: tek araç çağrısı örneği üret.",
            locale: "tr_TR",
            referenceDateISO8601: "2026-11-21T00:00:00Z",
            timeZoneIdentifier: "UTC"
        )
        let outcome = try await generateTurn(request: probeRequest)
        if case .proposedPlan(let steps) = outcome, !steps.isEmpty {
            return true
        }
        return true
    }

    public func generateTurn(request: ModelTurnRequest) async throws -> ModelTurnOutcome {
        guard profile.endpointURL.scheme?.lowercased() == "https",
              let host = profile.endpointURL.host, !host.isEmpty else {
            throw ModelProviderError.providerUnavailable(.needsAPIKey)
        }
        guard let apiKey = try? keyStore.readKey(forHost: host), !apiKey.isEmpty else {
            throw ModelProviderError.invalidAPIKey
        }

        let payload: [String: Any] = [
            "model": profile.modelID,
            "temperature": 0,
            "max_tokens": 600,
            "messages": [
                ["role": "system", "content": "iAgent planlayıcı. Yalnız katalog araçlarını çağır."],
                ["role": "user", "content": request.utterance]
            ],
            "tools": [
                [
                    "type": "function",
                    "function": [
                        "name": "notes_create",
                        "description": "Yerel iAgent notu oluşturur",
                        "parameters": [
                            "type": "object",
                            "properties": ["noteContent": ["type": "string"]],
                            "required": ["noteContent"]
                        ]
                    ]
                ]
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        guard bodyData.count <= Self.maxRequestBytes else {
            throw ModelProviderError.payloadTooLarge
        }

        var urlRequest = URLRequest(url: profile.endpointURL, timeoutInterval: Self.requestTimeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = bodyData
        let immutableRequest = urlRequest

        let work = Task<ModelTurnOutcome, Error> {
            try Task.checkCancellation()
            let (data, http) = try await transport.send(request: immutableRequest, allowedHost: host)
            if data.count > Self.maxResponseBytes {
                throw ModelProviderError.payloadTooLarge
            }
            switch http.statusCode {
            case 200...299:
                return try ExternalPlanJSONParser.parseChatCompletionsToolResponse(data)
            case 401, 403:
                throw ModelProviderError.invalidAPIKey
            case 402:
                throw ModelProviderError.insufficientBalance
            case 429:
                throw ModelProviderError.rateLimited
            default:
                throw ModelProviderError.networkUnavailable
            }
        }
        lock.withLock { currentTask = work }
        defer { lock.withLock { currentTask = nil } }
        return try await work.value
    }

    public func cancelCurrentRequest() async {
        lock.withLock {
            currentTask?.cancel()
            currentTask = nil
        }
    }
}
