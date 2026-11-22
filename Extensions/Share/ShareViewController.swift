import Foundation
import UniformTypeIdentifiers
import PhoneActions

#if canImport(UIKit)
import UIKit

/// Paylaş menüsünden gelen UTF-8 metni veya metin dosyasını App Group gelen kutusuna yazar.
/// Eklenti içinde ağır model çıkarımı çalıştırılmaz; içerik ana uygulamaya devredilir.
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let inboxManager = SharedInboxManager(inboxDirectory: SharedInboxManager.defaultInboxDirectory())

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "iAgent gelen kutusuna aktarılıyor..."
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])
        extractAndPersistSharedText()
    }

    private func extractAndPersistSharedText() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments else {
            completeExtension(message: "Paylaşılan metin bulunamadı.")
            return
        }

        let plainType = UTType.plainText.identifier
        guard let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(plainType) }) else {
            completeExtension(message: "İlk sürümde yalnız UTF-8 düz metin paylaşımı desteklenir.")
            return
        }

        provider.loadItem(forTypeIdentifier: plainType, options: nil) { [weak self] loaded, error in
            let loadedText = loaded as? String
            let loadedURL = loaded as? URL
            let loadErrorMessage = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                if let loadErrorMessage {
                    self.completeExtension(message: "İçerik okunamadı: \(loadErrorMessage)")
                    return
                }
                do {
                    if let loadedText {
                        _ = try self.inboxManager.enqueueText(loadedText, sourceAppHint: "ShareExtension", now: Date())
                    } else if let loadedURL {
                        if let fileSize = (try? loadedURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                           fileSize > SharedInboxManager.maxUTF8Bytes {
                            throw SharedInboxError.exceedsByteLimit(bytes: fileSize, maxBytes: SharedInboxManager.maxUTF8Bytes)
                        }
                        let data = try Data(contentsOf: loadedURL)
                        _ = try self.inboxManager.enqueueUTF8Data(data, sourceAppHint: loadedURL.lastPathComponent, now: Date())
                    } else {
                        self.completeExtension(message: "Desteklenmeyen metin biçimi.")
                        return
                    }
                    self.statusLabel.text = "iAgent gelen kutusuna eklendi. Ana uygulamadan özetleyip not alabilirsiniz."
                    self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                } catch {
                    self.completeExtension(message: "Paylaşım sınırı aşıldı veya UTF-8 geçersiz.")
                }
            }
        }
    }

    private func completeExtension(message: String) {
        statusLabel.text = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
}
#endif
