import Foundation
import AgentCore

#if canImport(FoundationModels)
import FoundationModels
#endif

public protocol AppleModelSessionAdapter: Sendable {
    func currentAvailability(for locale: String) async -> ModelAvailability
    func runStructuredTurn(request: ModelTurnRequest) async throws -> ModelTurnOutcome
}

/// iOS 26+ Apple Intelligence cihaz içi model sağlayıcısı.
/// Uygun olduğunda "Apple Intelligence · Bu iPhone" etiketiyle sıfır dış ağ çağrısı yaparak çalışır.
public final class AppleFoundationModelProvider: ModelProvider, @unchecked Sendable {
    public let providerID = "apple.foundation.ondevice"
    public let displayName = "Apple Intelligence · Bu iPhone"

    private let adapter: AppleModelSessionAdapter
    private let lock = NSLock()
    private var activeTask: Task<ModelTurnOutcome, Error>?

    public init(adapter: AppleModelSessionAdapter = LiveAppleFoundationAdapter()) {
        self.adapter = adapter
    }

    public func checkAvailability(for locale: String) async -> ModelAvailability {
        await adapter.currentAvailability(for: locale)
    }

    /// Model varlıkları hazırlanıyorsa durumu yeniden sorgular.
    public func recheckAvailability(for locale: String) async -> ModelAvailability {
        await adapter.currentAvailability(for: locale)
    }

    public func generateTurn(request: ModelTurnRequest) async throws -> ModelTurnOutcome {
        let status = await checkAvailability(for: request.locale)
        guard status.isReady else {
            throw ModelProviderError.providerUnavailable(status)
        }

        let task = Task<ModelTurnOutcome, Error> {
            try Task.checkCancellation()
            return try await adapter.runStructuredTurn(request: request)
        }
        lock.withLock { activeTask = task }
        defer { lock.withLock { activeTask = nil } }
        return try await task.value
    }

    public func cancelCurrentRequest() async {
        lock.withLock {
            activeTask?.cancel()
            activeTask = nil
        }
    }
}

public struct LiveAppleFoundationAdapter: AppleModelSessionAdapter, Sendable {
    public init() {}

    public func currentAvailability(for locale: String) async -> ModelAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                if locale.lowercased().hasPrefix("az") {
                    return .unsupportedLanguage
                }
                return .available(label: "Apple Intelligence · Bu iPhone")
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unsupportedHardware
                case .appleIntelligenceNotEnabled:
                    return .disabledInSettings
                case .modelNotReady:
                    return .preparingAssets
                @unknown default:
                    return .unsupportedHardware
                }
            @unknown default:
                return .unsupportedHardware
            }
        }
        #endif
        return .unsupportedHardware
    }

    public func runStructuredTurn(request: ModelTurnRequest) async throws -> ModelTurnOutcome {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let session = LanguageModelSession(
                instructions: """
                Sen iAgent kişisel asistanısın. Yanıtı JSON olarak üret:
                kind = "plan" | "clarify" | "answer" | "unsupported".
                """
            )
            let response = try await session.respond(to: request.utterance)
            if let decoded = try? ExternalPlanJSONParser.parseTurnJSON(response.content) {
                return decoded
            }
            return .answer(response.content)
        }
        #endif
        throw ModelProviderError.providerUnavailable(.unsupportedHardware)
    }
}
