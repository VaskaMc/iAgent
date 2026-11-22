import Foundation

public enum ExternalDataScope: String, Codable, CaseIterable, Sendable {
    case commandTextOnly
    case calendarContext
    case notesContext
    case sharedDocumentText
    case approvedMemoryContext
    case sharedDocumentOCRText
    case visualImagePayload

    public var displayTitleTR: String {
        switch self {
        case .commandTextOnly: return "Yalnız komut metni"
        case .calendarContext: return "Takvim özeti"
        case .notesContext: return "Seçilen not metni"
        case .sharedDocumentText: return "Paylaşılan belge metni"
        case .approvedMemoryContext: return "Onaylı hafıza özeti"
        case .sharedDocumentOCRText: return "Paylaşılan belge OCR metni"
        case .visualImagePayload: return "Görsel içerik verisi"
        }
    }
}

public struct ProviderConsentKey: Hashable, Codable, Sendable {
    public let providerID: String
    public let endpointHost: String

    public init(providerID: String, endpointHost: String) {
        self.providerID = providerID
        self.endpointHost = endpointHost.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ConsentPreview: Equatable, Sendable {
    public let providerID: String
    public let providerDisplayName: String
    public let endpointHost: String
    public let scopes: [ExternalDataScope]
    public let samplePayloadDescription: String

    public init(
        providerID: String,
        providerDisplayName: String,
        endpointHost: String,
        scopes: [ExternalDataScope],
        samplePayloadDescription: String
    ) {
        self.providerID = providerID
        self.providerDisplayName = providerDisplayName
        self.endpointHost = endpointHost
        self.scopes = scopes
        self.samplePayloadDescription = samplePayloadDescription
    }
}

/// İlk kez bulut sağlayıcısına veri göndermeden önce açık izin ister.
/// İzin reddedildiğinde veya geri çekildiğinde sonraki istekte ağ çağrısı yapılmaz.
/// Sağlayıcı veya hedef sunucu (host) değiştiğinde önceki onay geçersiz olur.
public final class ExternalDataConsentManager: @unchecked Sendable {
    private let lock = NSLock()
    private var activeConsentKey: ProviderConsentKey?
    private var grantedScopes = Set<ExternalDataScope>()

    public init() {}

    public func previewForConsent(
        providerID: String,
        providerDisplayName: String,
        endpointHost: String,
        requestedScopes: [ExternalDataScope] = [.commandTextOnly]
    ) -> ConsentPreview {
        ConsentPreview(
            providerID: providerID,
            providerDisplayName: providerDisplayName,
            endpointHost: endpointHost,
            scopes: requestedScopes,
            samplePayloadDescription: "Örnek gönderim: {\"utterance\": \"Yarın 10'da toplantı ekle\"}"
        )
    }

    public func grantConsent(for key: ProviderConsentKey, scopes: Set<ExternalDataScope>) {
        lock.withLock {
            if activeConsentKey != key {
                grantedScopes.removeAll()
                activeConsentKey = key
            }
            grantedScopes.formUnion(scopes)
        }
    }

    public func grantConsent(forProviderID providerID: String, scopes: Set<ExternalDataScope>) {
        let key = ProviderConsentKey(providerID: providerID, endpointHost: "")
        lock.withLock {
            if activeConsentKey?.providerID != providerID || activeConsentKey?.endpointHost != "" {
                grantedScopes.removeAll()
                activeConsentKey = key
            }
            grantedScopes.formUnion(scopes)
        }
    }

    public func revokeConsent() {
        lock.withLock {
            grantedScopes.removeAll()
            activeConsentKey = nil
        }
    }

    public func revokeConsent(for key: ProviderConsentKey) {
        lock.withLock {
            if activeConsentKey == key {
                grantedScopes.removeAll()
                activeConsentKey = nil
            }
        }
    }

    public func switchProvider(to newProviderID: String) {
        let key = ProviderConsentKey(providerID: newProviderID, endpointHost: "")
        lock.withLock {
            if activeConsentKey?.providerID != newProviderID {
                grantedScopes.removeAll()
                activeConsentKey = key
            }
        }
    }

    public func switchProvider(to newKey: ProviderConsentKey) {
        lock.withLock {
            if activeConsentKey != newKey {
                grantedScopes.removeAll()
                activeConsentKey = newKey
            }
        }
    }

    public func isConsentGranted(forProviderID providerID: String, scope: ExternalDataScope) -> Bool {
        lock.withLock {
            activeConsentKey?.providerID == providerID && grantedScopes.contains(scope)
        }
    }

    public func isConsentGranted(for key: ProviderConsentKey, scope: ExternalDataScope) -> Bool {
        lock.withLock {
            activeConsentKey == key && grantedScopes.contains(scope)
        }
    }

    public func isConsentGranted(
        forProviderID providerID: String,
        endpointHost: String,
        scope: ExternalDataScope
    ) -> Bool {
        isConsentGranted(
            for: ProviderConsentKey(providerID: providerID, endpointHost: endpointHost),
            scope: scope
        )
    }

    public func activeConsentKeySnapshot() -> ProviderConsentKey? {
        lock.withLock { activeConsentKey }
    }
}
