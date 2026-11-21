import Foundation
import AgentCore

public enum ModelUserPreference: String, Codable, Sendable, Equatable {
    case automatic
    case onDeviceOnly
    case customProvider
}

public enum ModelAvailability: Equatable, Sendable {
    case available(label: String)
    case preparingAssets
    case unsupportedHardware
    case disabledInSettings
    case unsupportedLanguage
    case needsAPIKey
    case needsExternalConsent

    public var isReady: Bool {
        if case .available = self { return true }
        return false
    }

    public var userFacingReasonTR: String {
        switch self {
        case .available(let label):
            return label
        case .preparingAssets:
            return "Apple Intelligence model varlıkları bu iPhone'a indiriliyor. Daha sonra yeniden kontrol edebilirsiniz."
        case .unsupportedHardware:
            return "Bu iPhone donanımı cihaz içi Apple Intelligence modelini desteklemiyor. Sabit yerel komutlarla veya harici sağlayıcıyla devam edebilirsiniz."
        case .disabledInSettings:
            return "Apple Intelligence sistem ayarlarında kapalı. Ayarlar'dan açabilir veya harici sağlayıcı bağlayabilirsiniz."
        case .unsupportedLanguage:
            return "Seçili istek dili cihaz içi model tarafından desteklenmiyor."
        case .needsAPIKey:
            return "Harici sağlayıcı için API anahtarı girilmedi."
        case .needsExternalConsent:
            return "Dış sağlayıcıya veri gönderimi için açık izin gerekli."
        }
    }
}

public enum ModelTurnOutcome: Equatable, Sendable {
    case answer(String)
    case clarification(question: String, missingFields: [String])
    case proposedPlan([RawModelStepInput])
    case unsupported(reason: String)
}

public enum ModelProviderError: Error, Equatable, Sendable {
    case cancelled
    case redirectBlocked(destinationHost: String)
    case truncatedOrMalformedJSON
    case safetyRefusal(String)
    case invalidAPIKey
    case networkUnavailable
    case rateLimited
    case insufficientBalance
    case payloadTooLarge
    case consentRequired
    case unsupportedInProductionBuild
    case providerUnavailable(ModelAvailability)
}

public struct ModelTurnRequest: Sendable, Equatable {
    public let taskId: UUID
    public let utterance: String
    public let locale: String
    public let referenceDateISO8601: String
    public let timeZoneIdentifier: String
    public let conversationHistory: [String]
    public let untrustedAttachmentText: String?

    public init(
        taskId: UUID,
        utterance: String,
        locale: String = "tr_TR",
        referenceDateISO8601: String,
        timeZoneIdentifier: String = "Asia/Baku",
        conversationHistory: [String] = [],
        untrustedAttachmentText: String? = nil
    ) {
        self.taskId = taskId
        self.utterance = utterance
        self.locale = locale
        self.referenceDateISO8601 = referenceDateISO8601
        self.timeZoneIdentifier = timeZoneIdentifier
        self.conversationHistory = conversationHistory
        self.untrustedAttachmentText = untrustedAttachmentText
    }
}

public protocol ModelProvider: Sendable {
    var providerID: String { get }
    var displayName: String { get }
    func checkAvailability(for locale: String) async -> ModelAvailability
    func generateTurn(request: ModelTurnRequest) async throws -> ModelTurnOutcome
    func cancelCurrentRequest() async
}

/// Kullanıcı tercihine göre cihaz içi Apple modeli, harici sağlayıcı veya sabit komut yolunu seçer.
public actor ModelRouter {
    private let onDeviceProvider: ModelProvider
    private let externalProvider: ModelProvider?
    private let consentManager: ExternalDataConsentManager

    public init(
        onDeviceProvider: ModelProvider,
        externalProvider: ModelProvider?,
        consentManager: ExternalDataConsentManager
    ) {
        self.onDeviceProvider = onDeviceProvider
        self.externalProvider = externalProvider
        self.consentManager = consentManager
    }

    public func routeAndGenerate(
        request: ModelTurnRequest,
        preference: ModelUserPreference,
        requiredScope: ExternalDataScope = .commandTextOnly
    ) async throws -> (providerLabel: String, outcome: ModelTurnOutcome) {
        switch preference {
        case .onDeviceOnly:
            let availability = await onDeviceProvider.checkAvailability(for: request.locale)
            guard availability.isReady else {
                throw ModelProviderError.providerUnavailable(availability)
            }
            let outcome = try await onDeviceProvider.generateTurn(request: request)
            return (onDeviceProvider.displayName, outcome)

        case .customProvider:
            guard let externalProvider else {
                throw ModelProviderError.providerUnavailable(.needsAPIKey)
            }
            guard consentManager.isConsentGranted(forProviderID: externalProvider.providerID, scope: requiredScope) else {
                throw ModelProviderError.consentRequired
            }
            let outcome = try await externalProvider.generateTurn(request: request)
            return (externalProvider.displayName, outcome)

        case .automatic:
            let onDeviceStatus = await onDeviceProvider.checkAvailability(for: request.locale)
            if onDeviceStatus.isReady {
                do {
                    let outcome = try await onDeviceProvider.generateTurn(request: request)
                    return (onDeviceProvider.displayName, outcome)
                } catch let error as ModelProviderError {
                    // Güvenlik reddi başka sağlayıcıya otomatik gönderilmez.
                    if case .safetyRefusal = error {
                        throw error
                    }
                    throw error
                }
            }
            guard let externalProvider else {
                throw ModelProviderError.providerUnavailable(onDeviceStatus)
            }
            guard consentManager.isConsentGranted(forProviderID: externalProvider.providerID, scope: requiredScope) else {
                throw ModelProviderError.consentRequired
            }
            let outcome = try await externalProvider.generateTurn(request: request)
            return (externalProvider.displayName, outcome)
        }
    }
}
