import Foundation
import AgentCore

public enum ShortcutCallbackEvent: Equatable, Sendable {
    case success(token: String, outputText: String?)
    case cancelled(token: String)
    case error(token: String, errorCode: Int?, errorMessage: String)
}

public struct ShortcutLaunchPlan: Equatable, Sendable {
    public let binding: ShortcutBinding
    public let callbackToken: String
    public let xCallbackURL: URL
    public let sanitizedInput: String?

    public init(binding: ShortcutBinding, callbackToken: String, xCallbackURL: URL, sanitizedInput: String?) {
        self.binding = binding
        self.callbackToken = callbackToken
        self.xCallbackURL = xCallbackURL
        self.sanitizedInput = sanitizedInput
    }
}

public enum ShortcutBridgeError: Error, Equatable, Sendable {
    case bindingNotFound(label: String)
    case arbitraryModelURLRejected
    case secretOrBulkDataRejected
    case unknownOrExpiredCallbackToken(String)
}

public protocol ShortcutURLOpenerProtocol: Sendable {
    func openShortcutURL(_ url: URL) async -> Bool
}

public final class MockShortcutURLOpener: ShortcutURLOpenerProtocol, @unchecked Sendable {
    public var shouldOpenSucceed = true
    public var lastOpenedURL: URL?

    public init() {}

    public func openShortcutURL(_ url: URL) async -> Bool {
        lastOpenedURL = url
        return shouldOpenSucceed
    }
}

/// Kullanıcının açıkça eşlediği ve sınadığı adlı kestirmeleri tek kullanımlık x-callback token ile çalıştırır.
public final class ShortcutsBridgeExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var bindings: [UUID: ShortcutBinding] = [:]
    private var pendingCallbacks: [String: (taskId: UUID, revisionNumber: Int, stepId: String, bindingId: UUID)] = [:]
    private let opener: ShortcutURLOpenerProtocol

    public init(opener: ShortcutURLOpenerProtocol, initialBindings: [ShortcutBinding] = []) {
        self.opener = opener
        for b in initialBindings {
            bindings[b.id] = b
        }
    }

    public func registerBinding(_ binding: ShortcutBinding) {
        lock.withLock {
            bindings[binding.id] = binding
        }
    }

    public func binding(forLabel label: String) -> ShortcutBinding? {
        let norm = TurkicTextNormalizer.normalize(label.trimmingCharacters(in: .whitespacesAndNewlines))
        return lock.withLock {
            bindings.values.first { TurkicTextNormalizer.normalize($0.userLabel) == norm }
        }
    }

    public func allBindings() -> [ShortcutBinding] {
        lock.withLock { Array(bindings.values).sorted { $0.userLabel < $1.userLabel } }
    }

    public func prepareLaunch(
        label: String,
        input: String?,
        taskId: UUID,
        revisionNumber: Int,
        stepId: String
    ) throws -> ShortcutLaunchPlan {
        guard let binding = binding(forLabel: label) else {
            throw ShortcutBridgeError.bindingNotFound(label: label)
        }

        // Kestirme köprüsüne sır veya toplu kişisel kayıt taşınmaz.
        if let input, Self.looksLikeSecretOrBulkPayload(input) {
            throw ShortcutBridgeError.secretOrBulkDataRejected
        }

        let token = UUID().uuidString
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"

        var items = [
            URLQueryItem(name: "name", value: binding.shortcutName),
            URLQueryItem(name: "x-success", value: "iagent://shortcut-callback?status=success&token=\(token)"),
            URLQueryItem(name: "x-cancel", value: "iagent://shortcut-callback?status=cancel&token=\(token)"),
            URLQueryItem(name: "x-error", value: "iagent://shortcut-callback?status=error&token=\(token)")
        ]

        let sanitizedInput: String?
        if binding.acceptedInput == .text, let input, !input.isEmpty {
            sanitizedInput = String(input.prefix(512))
            items.append(URLQueryItem(name: "input", value: "text"))
            items.append(URLQueryItem(name: "text", value: sanitizedInput))
        } else {
            sanitizedInput = nil
        }
        components.queryItems = items

        guard let url = components.url else {
            throw ShortcutBridgeError.arbitraryModelURLRejected
        }

        lock.withLock {
            pendingCallbacks[token] = (taskId, revisionNumber, stepId, binding.id)
        }

        return ShortcutLaunchPlan(
            binding: binding,
            callbackToken: token,
            xCallbackURL: url,
            sanitizedInput: sanitizedInput
        )
    }

    public func launch(_ plan: ShortcutLaunchPlan, now: Date) async -> ActionReceipt? {
        let opened = await opener.openShortcutURL(plan.xCallbackURL)
        if !opened {
            return ActionReceipt(
                taskId: plan.binding.id,
                revisionNumber: 1,
                stepId: "shortcut",
                executorName: "ShortcutsBridge",
                outcome: .failed,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Kestirmeler uygulaması açılamadı",
                spokenVerbAZ: "Qısayollar tətbiqi açıla bilmədi",
                detail: "shortcuts:// URL açılamadı."
            )
        }
        return nil
    }

    public func handleCallbackURL(_ url: URL, now: Date) throws -> ActionReceipt {
        guard url.scheme == "iagent", url.host == "shortcut-callback",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ShortcutBridgeError.unknownOrExpiredCallbackToken("invalid-url")
        }

        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        guard let token = query["token"],
              let pending = lock.withLock({ pendingCallbacks.removeValue(forKey: token) }) else {
            throw ShortcutBridgeError.unknownOrExpiredCallbackToken(query["token"] ?? "")
        }

        let status = query["status"] ?? "error"
        switch status {
        case "success":
            lock.withLock {
                bindings[pending.bindingId]?.lastTestedAt = now
                bindings[pending.bindingId]?.lastTestStatus = .verified
            }
            let output = query["result"] ?? ""
            return ActionReceipt(
                taskId: pending.taskId,
                revisionNumber: pending.revisionNumber,
                stepId: pending.stepId,
                executorName: "ShortcutsBridge",
                outcome: .succeeded,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Kestirme tamamlandı",
                spokenVerbAZ: "Qısayol tamamlandı",
                detail: output.isEmpty ? "Kestirme başarıyla döndü." : "Kestirme dönüşü alındı."
            )
        case "cancel":
            return ActionReceipt(
                taskId: pending.taskId,
                revisionNumber: pending.revisionNumber,
                stepId: pending.stepId,
                executorName: "ShortcutsBridge",
                outcome: .cancelled,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Kestirme iptal edildi",
                spokenVerbAZ: "Qısayol ləğv edildi",
                detail: "Kullanıcı Kestirmeler akışını iptal etti."
            )
        default:
            let errMsg = query["errorMessage"] ?? "Kestirme bulunamadı veya yeniden adlandırıldı."
            lock.withLock {
                bindings[pending.bindingId]?.lastTestedAt = now
                bindings[pending.bindingId]?.lastTestStatus = .missingOrRenamed
            }
            return ActionReceipt(
                taskId: pending.taskId,
                revisionNumber: pending.revisionNumber,
                stepId: pending.stepId,
                executorName: "ShortcutsBridge",
                outcome: .failed,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Kestirme çalıştırılamadı",
                spokenVerbAZ: "Qısayol işə salına bilmədi",
                detail: errMsg
            )
        }
    }

    /// Geri çağrı dönmediğinde sahte başarı uydurmaz; sonucu belirsiz olarak işaretler.
    public func finalizeTimedOutToken(_ token: String, now: Date) throws -> ActionReceipt {
        guard let pending = lock.withLock({ pendingCallbacks.removeValue(forKey: token) }) else {
            throw ShortcutBridgeError.unknownOrExpiredCallbackToken(token)
        }
        return ActionReceipt(
            taskId: pending.taskId,
            revisionNumber: pending.revisionNumber,
            stepId: pending.stepId,
            executorName: "ShortcutsBridge",
            outcome: .uncertain,
            timestamp: now,
            canUndo: false,
            spokenVerbTR: "Kestirmeden dönüş alınamadı",
            spokenVerbAZ: "Qısayoldan cavab alınmadı",
            detail: "Kestirme geri çağrısı dönmedi; işlem doğrulanamadı."
        )
    }

    private static func looksLikeSecretOrBulkPayload(_ input: String) -> Bool {
        let lower = input.lowercased()
        if lower.contains("sk-") || lower.contains("bearer ") || lower.contains("api_key") {
            return true
        }
        if input.utf8.count > 2048 {
            return true
        }
        return false
    }
}
