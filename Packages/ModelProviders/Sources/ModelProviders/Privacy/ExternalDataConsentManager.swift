import Foundation

public enum ExternalDataScope: String, Codable, CaseIterable, Sendable {
    case commandTextOnly
    case calendarContext
    case notesContext
    case sharedDocumentText

    public var displayTitleTR: String {
        switch self {
        case .commandTextOnly: return "Yalnız komut metni"
        case .calendarContext: return "Takvim özeti"
        case .notesContext: return "Seçilen not metni"
        case .sharedDocumentText: return "Paylaşılan belge metni"
        }
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
/// Sağlayıcı değiştiğinde önceki onay geçersiz olur.
public final class ExternalDataConsentManager: @unchecked Sendable {
    private let lock = NSLock()
    private var activeProviderID: String?
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

    public func grantConsent(forProviderID providerID: String, scopes: Set<ExternalDataScope>) {
        lock.withLock {
            if activeProviderID != providerID {
                grantedScopes.removeAll()
                activeProviderID = providerID
            }
            grantedScopes.formUnion(scopes)
        }
    }

    public func revokeConsent() {
        lock.withLock {
            grantedScopes.removeAll()
            activeProviderID = nil
        }
    }

    public func switchProvider(to newProviderID: String) {
        lock.withLock {
            if activeProviderID != newProviderID {
                grantedScopes.removeAll()
                activeProviderID = newProviderID
            }
        }
    }

    public func isConsentGranted(forProviderID providerID: String, scope: ExternalDataScope) -> Bool {
        lock.withLock {
            activeProviderID == providerID && grantedScopes.contains(scope)
        }
    }
}
