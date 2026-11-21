import AppIntents
import Foundation

/// Siri ve Kestirmeler üzerinden iAgent'e tek bir serbest metin isteği iletmek için ana App Intent.
struct AskIAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "iAgent ile Konuş"
    static let description = IntentDescription(
        "Siri veya Kestirmeler aracılığıyla iAgent'e günlük bir görev verir."
    )

    // Kısa ve yetkili işler arka planda tamamlanabilir; etkileşim gerektiğinde ön plana geçilir.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    // Genel komut girişi kilit ekranında başlatılabilir; hassas işlemler çekirdekte kilit/doğrulama ister.
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(
        title: "İstek",
        description: "iAgent'in yapmasını istediğiniz işlem.",
        requestValueDialog: IntentDialog("Ne yapmamı istersin?")
    )
    var utterance: String?

    init() {}

    init(utterance: String) {
        self.utterance = utterance
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let resolvedUtterance: String
        if let utterance, !utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedUtterance = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            resolvedUtterance = try await $utterance.requestValue(IntentDialog("Ne yapmamı istersin?"))
        }

        let responseText = AppCoordinator.shared.handleSiriUtterance(resolvedUtterance)

        // Kişi seçimi, mesaj düzenleyicisi veya onay gerektiren durumlarda ön plana geçiş hazır tutulur.
        let requiresForeground = resolvedUtterance.localizedCaseInsensitiveContains("mesaj")
            || resolvedUtterance.localizedCaseInsensitiveContains("e-posta")
            || resolvedUtterance.localizedCaseInsensitiveContains("ara")

        if requiresForeground && systemContext.currentMode.canContinueInForeground {
            try await continueInForeground(
                IntentDialog("Devam etmek için iAgent açılıyor."),
                alwaysConfirm: false
            )
        }

        return .result(dialog: IntentDialog(stringLiteral: responseText))
    }
}
