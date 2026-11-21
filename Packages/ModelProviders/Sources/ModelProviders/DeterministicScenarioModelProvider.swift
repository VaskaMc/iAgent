import Foundation
import AgentCore

public enum BuildConfiguration {
    public static var isProductionBuild: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }
}

/// Yalnız test ve senaryo doğrulamalarında çalışan deterministik model sağlayıcısı.
/// Üretim yapılandırmasında seçilemez (.unsupportedInProductionBuild).
public final class DeterministicScenarioModelProvider: ModelProvider, @unchecked Sendable {
    public let providerID = "test.deterministic.scenario"
    public let displayName = "Deterministik Test Sağlayıcısı"

    private let allowInCurrentBuild: Bool

    public init(allowInCurrentBuild: Bool = !BuildConfiguration.isProductionBuild) {
        self.allowInCurrentBuild = allowInCurrentBuild
    }

    public func checkAvailability(for locale: String) async -> ModelAvailability {
        guard allowInCurrentBuild else {
            return .unsupportedHardware
        }
        return .available(label: displayName)
    }

    public func generateTurn(request: ModelTurnRequest) async throws -> ModelTurnOutcome {
        guard allowInCurrentBuild else {
            throw ModelProviderError.unsupportedInProductionBuild
        }

        let norm = TurkicTextNormalizer.normalize(request.utterance.trimmingCharacters(in: .whitespacesAndNewlines))

        // 1. Bölüm 1 & Bölüm 9 ana çok adımlı senaryo
        if norm.contains("yarin 10") && norm.contains("deniz") && norm.contains("45 dakikalik") && norm.contains("sunumu") {
            return .proposedPlan([
                RawModelStepInput(
                    id: "a",
                    action: "calendar.create",
                    parameters: ActionParameters(
                        title: "Deniz ile toplantı",
                        startISO8601: "2026-11-22T10:00:00+04:00",
                        durationMinutes: 45
                    )
                ),
                RawModelStepInput(
                    id: "b",
                    action: "reminders.create",
                    parameters: ActionParameters(
                        title: "Sunumu aç",
                        dueISO8601: "2026-11-22T09:30:00+04:00"
                    ),
                    dependsOn: ["a"]
                ),
                RawModelStepInput(
                    id: "c",
                    action: "messages.compose",
                    parameters: ActionParameters(
                        recipientQuery: "Deniz",
                        body: "Yarın 10.00 için toplantıyı takvimime ekledim."
                    ),
                    dependsOn: ["a"]
                )
            ])
        }

        // 2. Paylaşılan belge / prompt injection koruması (Bölüm 9 Deneme 9)
        if norm.contains("bu belgeyi ozetle") || norm.contains("ozetle ve not al") {
            let sourceText = request.untrustedAttachmentText ?? request.utterance
            let safeSummary = "Özet: \(String(sourceText.prefix(120)))"
            return .proposedPlan([
                RawModelStepInput(
                    id: "s1",
                    action: "text.summarizeAndNote",
                    parameters: ActionParameters(
                        noteContent: safeSummary,
                        untrustedSourceText: sourceText
                    )
                )
            ])
        }

        // 3. Belirsiz ifadeler (TR & AZ)
        if norm == "sabah saat doqquzda mene xatirlat" || norm == "sabah doqquzda xatirlat" || norm == "yarin dokuzda hatirlat" {
            return .clarification(
                question: norm.contains("xatirlat")
                    ? "Sabah saat 09:00 üçün nəyi xatırlatmağımı istəyirsən?"
                    : "Yarın saat 09.00 için neyi hatırlatmamı istersin?",
                missingFields: ["title"]
            )
        }
        if norm.contains("cuma aksami") || norm.contains("obur cuma") {
            return .clarification(
                question: "Cuma akşamı için tam tarih ve saati (ör. 27 Kasım 19.00) seçer misin?",
                missingFields: ["startISO8601"]
            )
        }
        if norm == "bunu not al" || norm == "sunu not al" || norm == "hatirlatma ekle" || norm == "qeyd et" {
            return .clarification(
                question: norm.contains("qeyd")
                    ? "Nəyi qeyd etməyimi istəyirsən?"
                    : "İçerik veya başlık eksik; ne eklememi istersin?",
                missingFields: ["noteContent"]
            )
        }

        // 4. Konum tabanlı anımsatıcı -> v1 zaman/kestirme yönlendirmesi
        if norm.contains("eve varinca") || norm.contains("eve catanda") || norm.contains("markete gidince") {
            return .clarification(
                question: "İlk sürümde konuma bağlı anımsatıcı desteklenmiyor; saat seçmek veya kurulu kestirmeni kullanmak ister misin?",
                missingFields: ["dueISO8601"]
            )
        }

        // 5. Destek dışı istekler
        let unsupportedSignals = [
            "instagram", "banka havalesi", "para gonder", "ayarlar uygulamasindaki", "diger uygulamanin butonuna",
            "ekranina dokun", "whatsapp gecmisini oku", "apple notlarimi sil"
        ]
        if unsupportedSignals.contains(where: { norm.contains($0) }) {
            return .unsupported(
                reason: "iOS başka bir uygulamanın ekranına dokunma veya sohbet/Apple Notlar arşivine doğrudan erişim izni vermez. Desteklenen bir Kestirme veya paylaşım adımı kullanabilirsin."
            )
        }

        // 6. Tek adımlı / çok adımlı TR & AZ komut çözümleme
        if norm.contains("not al") || norm.contains("not ekle") || norm.contains("qeyd et") {
            let content = request.utterance
                .replacingOccurrences(of: "Şunu not al:", with: "")
                .replacingOccurrences(of: "Şunu not al", with: "")
                .replacingOccurrences(of: "Not ekle:", with: "")
                .replacingOccurrences(of: "Bunu qeyd et:", with: "")
                .replacingOccurrences(of: "Qeyd et:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .proposedPlan([
                RawModelStepInput(
                    id: "n1",
                    action: "notes.create",
                    parameters: ActionParameters(noteContent: content.isEmpty ? request.utterance : content)
                )
            ])
        }

        if norm.contains("notunu bul") || norm.contains("notumu bul") || norm.contains("qeydini tap") {
            return .proposedPlan([
                RawModelStepInput(
                    id: "n_search",
                    action: "notes.search",
                    parameters: ActionParameters(query: "alışveriş")
                )
            ])
        }

        if norm.contains("programim nasil") || norm.contains("bugunku ajandam") || norm.contains("bugunku teqvimim") || norm.contains("bugunku planim") {
            return .proposedPlan([
                RawModelStepInput(
                    id: "cal_r",
                    action: "calendar.read",
                    parameters: ActionParameters(startISO8601: request.referenceDateISO8601)
                )
            ])
        }

        if norm.contains("calisma ekle") || norm.contains("toplanti ekle") || norm.contains("gorus elave et") {
            return .proposedPlan([
                RawModelStepInput(
                    id: "cal_c",
                    action: "calendar.create",
                    parameters: ActionParameters(
                        title: norm.contains("gorus") ? "Görüş" : "Çalışma",
                        startISO8601: "2026-11-27T15:00:00+04:00",
                        durationMinutes: 30
                    )
                )
            ])
        }

        if norm.contains("hatirlat") || norm.contains("xatirlat") {
            return .proposedPlan([
                RawModelStepInput(
                    id: "rem_c",
                    action: "reminders.create",
                    parameters: ActionParameters(
                        title: norm.contains("sarj") ? "Şarj aletini al" : "Xatırlatma",
                        dueISO8601: "2026-11-21T19:00:00+04:00"
                    )
                )
            ])
        }

        if norm.contains("whatsapp") {
            return .proposedPlan([
                RawModelStepInput(
                    id: "sh1",
                    action: "share.sheet",
                    parameters: ActionParameters(recipientQuery: "Deniz", body: request.utterance)
                )
            ])
        }

        if norm.contains("e-posta") || norm.contains("eposta") {
            return .proposedPlan([
                RawModelStepInput(
                    id: "mail1",
                    action: "mail.compose",
                    parameters: ActionParameters(recipientQuery: "Deniz", subject: "Bilgilendirme", body: request.utterance)
                )
            ])
        }

        if norm.contains("mesaj") {
            return .proposedPlan([
                RawModelStepInput(
                    id: "msg1",
                    action: "messages.compose",
                    parameters: ActionParameters(recipientQuery: "Deniz", body: "On dakika gecikeceğim.")
                )
            ])
        }

        if norm.contains("ara") || norm.contains("zeng et") {
            return .proposedPlan([
                RawModelStepInput(
                    id: "call1",
                    action: "phone.call",
                    parameters: ActionParameters(recipientQuery: "Deniz")
                )
            ])
        }

        if norm.contains("yol tarifi") || norm.contains("yol goster") || norm.contains("xerite") {
            return .proposedPlan([
                RawModelStepInput(
                    id: "map1",
                    action: "maps.directions",
                    parameters: ActionParameters(destinationQuery: norm.contains("baku") || norm.contains("baki") ? "Bakü Garı" : "Hedef", transportMode: "transit")
                )
            ])
        }

        if norm.contains("calisma modumu") || norm.contains("kestirme") || norm.contains("qisayol") {
            return .proposedPlan([
                RawModelStepInput(
                    id: "sc1",
                    action: "shortcuts.run",
                    parameters: ActionParameters(shortcutLabel: "Çalışma Modu", shortcutInput: "start")
                )
            ])
        }

        if norm.contains("nazik") || norm.contains("kisalt") || norm.contains("qisalt") {
            return .answer("Öneri: \"Müsaitseniz birkaç dakika gecikeceğim, anlayışınız için teşekkürler.\"")
        }

        return .unsupported(reason: "Bu istek için doğrulanmış bir iAgent eylemi bulunamadı.")
    }

    public func cancelCurrentRequest() async {}
}
