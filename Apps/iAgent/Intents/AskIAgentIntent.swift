import AppIntents
import Foundation

/// Siri ve Kestirmeler üzerinden iAgent'e tek bir serbest metin isteği iletmek için ana App Intent.
struct AskIAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "iAgent ile Konuş"
    static let description = IntentDescription(
        "Siri veya Kestirmeler aracılığıyla iAgent'e günlük bir görev verir."
    )

    #if compiler(>=6.2)
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    #else
    static let openAppWhenRun: Bool = false
    #endif

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

        let responseText = await AppCoordinator.shared.submitUserUtterance(resolvedUtterance, source: .siri)

        #if compiler(>=6.2)
        // Kişi seçimi, çok adımlı onay veya sistem düzenleyicisi gerektiren akışta uygulama ön plana getirilir.
        let needsForeground = AppCoordinator.shared.activePlanState != nil
        if needsForeground && systemContext.currentMode.canContinueInForeground {
            try await continueInForeground(
                IntentDialog("Devam etmek için iAgent açılıyor."),
                alwaysConfirm: false
            )
        }
        #endif

        return .result(dialog: IntentDialog(stringLiteral: responseText))
    }
}
