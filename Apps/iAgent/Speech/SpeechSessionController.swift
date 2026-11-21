import Foundation
import Observation
import AgentCore

#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Speech)
import Speech
#endif

public enum SpeechInputPermissionState: String, Codable, Sendable, Equatable {
    case notRequested
    case authorized
    case denied
    case unsupportedLanguage
}

public enum ActiveAudioOwner: String, Sendable, Equatable {
    case none
    case siriDialog
    case inAppSpeechSynthesis
    case inAppMicrophoneCapture
}

/// Uygulama içi bas-konuş dikte ve konuşma sentezini yönetir.
/// - Siri `IntentDialog` ile aynı anda konuşmaz.
/// - Kendi sesli yanıtını yeniden komut olarak dinlemez (eko kilidi).
/// - Kullanıcı söz aldığında sentezi anında keser (barge-in).
@MainActor
@Observable
public final class SpeechSessionController: NSObject {
    public var permissionState: SpeechInputPermissionState = .notRequested
    public var activeOwner: ActiveAudioOwner = .none
    public var isListening: Bool = false
    public var isSpeaking: Bool = false
    public var isMicrophoneLockedForPlayback: Bool = false
    public var liveTranscript: String = ""
    public var lastSpokenText: String?
    public var selectedLanguage: AgentLanguage = .turkish
    public var statusMessage: String?

    #if canImport(AVFoundation)
    private let synthesizer = AVSpeechSynthesizer()
    #endif

    public override init() {
        super.init()
        #if canImport(AVFoundation)
        synthesizer.delegate = self
        #endif
    }

    /// Uygulama içi bas-konuş oturumu başlatır. Siri üzerinden gelen görevlerde mikrofon açılmaz.
    public func beginPushToTalk(source: TaskSource) async {
        guard source != .siri else {
            statusMessage = "Siri oturumundan gelen istek için uygulama mikrofonu otomatik açılmaz."
            return
        }

        // Kullanıcı yanıtı kesip yeni söz aldığında sentez anında durur.
        if isSpeaking {
            interruptSpeechSynthesis()
        }

        guard !isMicrophoneLockedForPlayback else { return }

        if permissionState == .denied {
            statusMessage = "Mikrofon veya konuşma tanıma izni kapalı; yazılı girişi kullanabilirsiniz."
            return
        }

        if permissionState == .notRequested {
            await requestSpeechAndMicPermissionsIfNeeded()
        }

        guard permissionState == .authorized else {
            statusMessage = "Sesli giriş kullanılamıyor; klavyeyle devam edebilirsiniz."
            return
        }

        if selectedLanguage == .azerbaijani {
            // Cihaz içi sesli tanıma desteklenmeyen dil/ses birleşimini yazıya yönlendirir.
            let supported = await isOnDeviceSpeechSupported(for: "az-AZ")
            if !supported {
                permissionState = .unsupportedLanguage
                statusMessage = "Azerbaycanca sesli dikte bu cihazda hazır değil; lütfen yazılı girişi kullanın."
                return
            }
        }

        activeOwner = .inAppMicrophoneCapture
        isListening = true
        statusMessage = "Dinleniyor..."
    }

    public func stopPushToTalkAndReturnTranscript() -> String {
        isListening = false
        if activeOwner == .inAppMicrophoneCapture {
            activeOwner = .none
        }
        return liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func speakInApp(_ text: String, source: TaskSource) {
        lastSpokenText = text
        // Siri akışında yanıt IntentDialog ile okunur; uygulama aynı anda konuşmaz.
        guard source != .siri else {
            activeOwner = .siriDialog
            return
        }

        stopListeningWithoutSending()
        isMicrophoneLockedForPlayback = true
        isSpeaking = true
        activeOwner = .inAppSpeechSynthesis

        #if canImport(AVFoundation)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(
            language: selectedLanguage == .azerbaijani ? "az-AZ" : "tr-TR"
        ) ?? AVSpeechSynthesisVoice(language: "tr-TR")
        synthesizer.speak(utterance)
        #endif
    }

    public func interruptSpeechSynthesis() {
        #if canImport(AVFoundation)
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        #endif
        isSpeaking = false
        isMicrophoneLockedForPlayback = false
        if activeOwner == .inAppSpeechSynthesis {
            activeOwner = .none
        }
    }

    public func stopListeningWithoutSending() {
        isListening = false
        if activeOwner == .inAppMicrophoneCapture {
            activeOwner = .none
        }
    }

    private func requestSpeechAndMicPermissionsIfNeeded() async {
        #if canImport(Speech)
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authStatus in
                continuation.resume(returning: authStatus)
            }
        }
        permissionState = (status == .authorized) ? .authorized : .denied
        #else
        permissionState = .denied
        #endif
    }

    private func isOnDeviceSpeechSupported(for localeIdentifier: String) async -> Bool {
        #if canImport(Speech)
        if #available(iOS 26.0, *) {
            let target = Locale(identifier: localeIdentifier)
            return await SpeechTranscriber.supportedLocale(equivalentTo: target) != nil
        }
        return SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))?.isAvailable ?? false
        #else
        return false
        #endif
    }
}

#if canImport(AVFoundation)
extension SpeechSessionController: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
            self?.isMicrophoneLockedForPlayback = false
            if self?.activeOwner == .inAppSpeechSynthesis {
                self?.activeOwner = .none
            }
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
            self?.isMicrophoneLockedForPlayback = false
            if self?.activeOwner == .inAppSpeechSynthesis {
                self?.activeOwner = .none
            }
        }
    }
}
#endif
