import AppIntents
import Foundation
#if os(iOS) && canImport(UIKit)
import UIKit
#endif

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
        #if os(iOS) && canImport(UIKit)
        AppCoordinator.shared.isDeviceLocked = !UIApplication.shared.isProtectedDataAvailable
        #endif

        let resolvedUtterance: String
        if let utterance, !utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedUtterance = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            resolvedUtterance = try await $utterance.requestValue(IntentDialog("Ne yapmamı istersin?"))
        }

        let responseText = await AppCoordinator.shared.submitUserUtterance(resolvedUtterance, source: .siri)

        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // Kişi seçimi, çok adımlı onay veya sistem düzenleyicisi gerektiren akışta uygulama ön plana getirilir (sürüş hariç).
            let needsForeground = AppCoordinator.shared.activePlanState != nil && !AppCoordinator.shared.isDrivingSafetyActive
            if needsForeground && systemContext.currentMode.canContinueInForeground {
                try await continueInForeground(
                    IntentDialog("Devam etmek için iAgent açılıyor."),
                    alwaysConfirm: false
                )
            }
        }
        #endif

        return .result(dialog: IntentDialog(stringLiteral: responseText))
    }
}

/// Kilit açıkken günlük takvim, anımsatıcı ve ETA brifingini sentezleyen App Intent.
struct MorningBriefingIntent: AppIntent {
    static let title: LocalizedStringResource = "iAgent Sabah Brifingi"
    static let description = IntentDescription(
        "Bugünün takvim etkinliklerini, açık anımsatıcıları ve tahmini yol süresini özetler."
    )

    #if compiler(>=6.2)
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    #else
    static let openAppWhenRun: Bool = false
    #endif

    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let summary = await AppCoordinator.shared.runMorningBriefing(source: .siri)
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

/// Sesli Kestirmeler ve Eylem Düğmesi üzerinden anlık JARVIS ses yakalamayı başlatan App Intent.
struct QuickVoiceJarvisIntent: AppIntent {
    static let title: LocalizedStringResource = "Jarvis Dinle"
    static let description = IntentDescription(
        "Eylem Düğmesi veya Sesli Kestirmeler ile doğrudan iAgent sesli dinlemeyi başlatır."
    )

    #if compiler(>=6.2)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    #else
    static let openAppWhenRun: Bool = true
    #endif

    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AppCoordinator.shared.speechController.beginPushToTalk(source: .vocalShortcut)
        return .result(dialog: IntentDialog("Dinliyorum."))
    }
}
