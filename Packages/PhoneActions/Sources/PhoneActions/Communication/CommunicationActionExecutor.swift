import Foundation
import AgentCore

public enum ComposerResult: String, Codable, Sendable, Equatable {
    case sent
    case cancelled
    case failed
    case notConfigured
}

public enum ShareHandoffResult: Equatable, Sendable {
    case shareSheetPresented(text: String, preferredApp: String?)
    case targetAppNotInstalledOfferStandardShare(appName: String, text: String)
    case callConfirmationPresented(phoneNumber: String)
    case invalidRecipientHandle
}

public protocol SystemCommunicationPresenterProtocol: Sendable {
    func canSendSMS() async -> Bool
    func canSendMail() async -> Bool
    func isURLSchemeInstalled(_ scheme: String) async -> Bool
    func presentSMSComposer(recipientHandle: String, body: String) async -> ComposerResult
    func presentMailComposer(recipientEmail: String, subject: String, body: String) async -> ComposerResult
    func presentShareSheet(text: String) async -> Bool
    func openDialConfirmation(phoneNumber: String) async -> Bool
}

public final class MockSystemCommunicationPresenter: SystemCommunicationPresenterProtocol, @unchecked Sendable {
    public var smsConfigured = true
    public var mailConfigured = true
    public var installedSchemes: Set<String> = []
    public var nextSMSResult: ComposerResult = .sent
    public var nextMailResult: ComposerResult = .sent
    public var dialOpened = false
    public var sharePresented = false

    public init() {}

    public func canSendSMS() async -> Bool { smsConfigured }
    public func canSendMail() async -> Bool { mailConfigured }
    public func isURLSchemeInstalled(_ scheme: String) async -> Bool {
        installedSchemes.contains(scheme.lowercased())
    }

    public func presentSMSComposer(recipientHandle: String, body: String) async -> ComposerResult {
        guard smsConfigured else { return .notConfigured }
        return nextSMSResult
    }

    public func presentMailComposer(recipientEmail: String, subject: String, body: String) async -> ComposerResult {
        guard mailConfigured else { return .notConfigured }
        return nextMailResult
    }

    public func presentShareSheet(text: String) async -> Bool {
        sharePresented = true
        return true
    }

    public func openDialConfirmation(phoneNumber: String) async -> Bool {
        dialOpened = true
        return true
    }
}

/// Sistem mesaj/e-posta düzenleyicisi, paylaşım sayfası ve telefon araması yürütücüsü.
/// Gönderim durumunu yalnız düzenleyici dönüşünden üretir; teslim durumu uydurmaz.
public final class CommunicationActionExecutor: @unchecked Sendable {
    private let presenter: SystemCommunicationPresenterProtocol

    public init(presenter: SystemCommunicationPresenterProtocol) {
        self.presenter = presenter
    }

    public func composeSMS(
        taskId: UUID,
        revisionNumber: Int,
        stepId: String,
        recipientHandle: String,
        body: String,
        now: Date
    ) async -> ActionReceipt {
        guard await presenter.canSendSMS() else {
            return ActionReceipt(
                taskId: taskId,
                revisionNumber: revisionNumber,
                stepId: stepId,
                executorName: "MessageUI.SMS",
                outcome: .failed,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Bu cihazda SMS gönderimi yapılandırılmamış",
                spokenVerbAZ: "Bu cihazda SMS göndərişi quraşdırılmayıb",
                detail: "MFMessageComposeViewController.canSendText() == false"
            )
        }

        let result = await presenter.presentSMSComposer(recipientHandle: recipientHandle, body: body)
        switch result {
        case .sent:
            return ActionReceipt(
                taskId: taskId,
                revisionNumber: revisionNumber,
                stepId: stepId,
                executorName: "MessageUI.SMS",
                outcome: .succeeded,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Mesaj düzenleyicisinde gönderildi",
                spokenVerbAZ: "Mesaj redaktorunda göndərildi",
                detail: "Sistem mesaj düzenleyicisi gönderildi döndürdü (alıcı teslim bilgisi izlenmez)."
            )
        case .cancelled:
            return ActionReceipt(
                taskId: taskId,
                revisionNumber: revisionNumber,
                stepId: stepId,
                executorName: "MessageUI.SMS",
                outcome: .cancelled,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Mesaj taslağı iptal edildi",
                spokenVerbAZ: "Mesaj qaralaması ləğv edildi",
                detail: "Kullanıcı mesaj düzenleyicisini göndermeden kapattı."
            )
        case .failed, .notConfigured:
            return ActionReceipt(
                taskId: taskId,
                revisionNumber: revisionNumber,
                stepId: stepId,
                executorName: "MessageUI.SMS",
                outcome: .failed,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Mesaj düzenleyicisi hata verdi",
                spokenVerbAZ: "Mesaj redaktoru xəta verdi",
                detail: "Düzenleyici gönderimi tamamlayamadı."
            )
        }
    }

    public func composeMail(
        taskId: UUID,
        revisionNumber: Int,
        stepId: String,
        recipientEmail: String,
        subject: String,
        body: String,
        now: Date
    ) async -> ActionReceipt {
        guard await presenter.canSendMail() else {
            return ActionReceipt(
                taskId: taskId,
                revisionNumber: revisionNumber,
                stepId: stepId,
                executorName: "MessageUI.Mail",
                outcome: .failed,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Bu cihazda e-posta hesabı yapılandırılmamış",
                spokenVerbAZ: "Bu cihazda e-poçt hesabı quraşdırılmayıb",
                detail: "MFMailComposeViewController.canSendMail() == false"
            )
        }

        let result = await presenter.presentMailComposer(
            recipientEmail: recipientEmail,
            subject: subject,
            body: body
        )
        switch result {
        case .sent:
            return ActionReceipt(
                taskId: taskId,
                revisionNumber: revisionNumber,
                stepId: stepId,
                executorName: "MessageUI.Mail",
                outcome: .succeeded,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "E-posta düzenleyicisinde gönderildi",
                spokenVerbAZ: "E-poçt redaktorunda göndərildi",
                detail: "Sistem e-posta düzenleyicisi gönderildi döndürdü."
            )
        case .cancelled:
            return ActionReceipt(
                taskId: taskId,
                revisionNumber: revisionNumber,
                stepId: stepId,
                executorName: "MessageUI.Mail",
                outcome: .cancelled,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "E-posta taslağı iptal edildi",
                spokenVerbAZ: "E-poçt qaralaması ləğv edildi",
                detail: "Kullanıcı e-posta taslağını iptal etti."
            )
        case .failed, .notConfigured:
            return ActionReceipt(
                taskId: taskId,
                revisionNumber: revisionNumber,
                stepId: stepId,
                executorName: "MessageUI.Mail",
                outcome: .failed,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "E-posta gönderilemedi",
                spokenVerbAZ: "E-poçt göndərilə bilmədi",
                detail: "E-posta düzenleyicisi hata verdi."
            )
        }
    }

    public func shareToApp(text: String, preferredAppScheme: String?) async -> ShareHandoffResult {
        if let scheme = preferredAppScheme, !scheme.isEmpty {
            let isInstalled = await presenter.isURLSchemeInstalled(scheme)
            if !isInstalled {
                // Kurulu olmayan paylaşım hedefinde başarı uydurulmaz.
                return .targetAppNotInstalledOfferStandardShare(appName: scheme, text: text)
            }
        }
        _ = await presenter.presentShareSheet(text: text)
        return .shareSheetPresented(text: text, preferredApp: preferredAppScheme)
    }

    public func handoffPhoneCall(phoneNumber: String) async -> ShareHandoffResult {
        let digits = phoneNumber.filter { $0.isNumber || $0 == "+" }
        guard digits.count >= 3 else {
            return .invalidRecipientHandle
        }
        _ = await presenter.openDialConfirmation(phoneNumber: digits)
        return .callConfirmationPresented(phoneNumber: digits)
    }
}
