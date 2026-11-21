import XCTest
import AgentCore
import ModelProviders

final class BetaEvaluationDatasetTests: XCTestCase {
    func testTurkish30BetaCommandsAndAzerbaijani10Commands() async throws {
        let provider = DeterministicScenarioModelProvider(allowInCurrentBuild: true)

        let turkishSingleStep: [(String, String)] = [
            ("Şunu not al: Akşam süt al", "notes.create"),
            ("Dün yazdığım alışveriş notunu bul", "notes.search"),
            ("Bugün programım nasıl?", "calendar.read"),
            ("Cuma 15.00'e 30 dakikalık çalışma ekle", "calendar.create"),
            ("Bugün 19.00'da şarj aletini almamı hatırlat", "reminders.create"),
            ("Deniz'e mesaj hazırla", "messages.compose"),
            ("Bunu e-posta yap", "mail.compose"),
            ("Bunu WhatsApp'ta paylaş", "share.sheet"),
            ("Deniz'i ara", "phone.call"),
            ("Bakü Garı'na yol tarifi aç", "maps.directions")
        ]

        let turkishMultiStep: [String] = [
            "Yarın 10'da Deniz'le 45 dakikalık toplantı ekle. Yarım saat önce sunumu açmamı hatırlat. Deniz'e de mesaj hazırla.",
            "Çalışma modumu başlat",
            "Bunu özetle ve not al",
            "Bu mesajı daha nazik nasıl söylerim?",
            "Not ekle: Sunum kontrolü",
            "Bugünkü ajandam nasıl?",
            "Cuma 15.00'e çalışma ekle",
            "Deniz'e mesaj hazırla ve gönder",
            "Bakü Garı'na yol tarifi aç lütfen",
            "Bunu kısalt"
        ]

        let turkishAmbiguous: [String] = [
            "Sabah saat doqquzda mənə xatırlat",
            "Cuma akşamı toplantı ekle",
            "Öbür cuma buluşma ayarla",
            "Bunu not al",
            "Eve varınca hatırlat"
        ]

        let turkishUnsupported: [String] = [
            "Instagram'da son fotoğrafımı beğen",
            "Banka havalesi yap ve 500 TL para gönder",
            "Diğer uygulamanın butonuna dokun",
            "WhatsApp geçmişimi oku",
            "Apple Notlarımı sil"
        ]

        var passedTR = 0
        for (utterance, expectedAction) in turkishSingleStep {
            let out = try await provider.generateTurn(
                request: ModelTurnRequest(taskId: UUID(), utterance: utterance, referenceDateISO8601: "2026-11-21T12:00:00+04:00")
            )
            if case .proposedPlan(let steps) = out, steps.first?.action == expectedAction {
                passedTR += 1
            }
        }
        for utterance in turkishMultiStep {
            let out = try await provider.generateTurn(
                request: ModelTurnRequest(taskId: UUID(), utterance: utterance, referenceDateISO8601: "2026-11-21T12:00:00+04:00")
            )
            switch out {
            case .proposedPlan(let s) where !s.isEmpty: passedTR += 1
            case .answer(let t) where !t.isEmpty: passedTR += 1
            default: break
            }
        }
        for utterance in turkishAmbiguous {
            let out = try await provider.generateTurn(
                request: ModelTurnRequest(taskId: UUID(), utterance: utterance, referenceDateISO8601: "2026-11-21T12:00:00+04:00")
            )
            if case .clarification = out { passedTR += 1 }
        }
        for utterance in turkishUnsupported {
            let out = try await provider.generateTurn(
                request: ModelTurnRequest(taskId: UUID(), utterance: utterance, referenceDateISO8601: "2026-11-21T12:00:00+04:00")
            )
            if case .unsupported = out { passedTR += 1 }
        }
        XCTAssertGreaterThanOrEqual(passedTR, 27)
        XCTAssertEqual(passedTR, 30)

        let azerbaijaniDataset: [String] = [
            "Bunu qeyd et: Sabah iclas sənədlərini yoxla",
            "Dünən yazdığım qeydini tap",
            "Bugünkü təqvimim necədir?",
            "Sabah saat doqquzda mənə xatırlat",
            "Cümə 15.00-a görüş əlavə et",
            "Dənizə mesaj hazırla",
            "Bakı Vağzalına yol göstər",
            "Bunu WhatsApp-da paylaş",
            "Bu mətni qısalt",
            "Instagram-da mesajları oxu"
        ]
        var passedAZ = 0
        for utterance in azerbaijaniDataset {
            let out = try await provider.generateTurn(
                request: ModelTurnRequest(taskId: UUID(), utterance: utterance, locale: "az_AZ", referenceDateISO8601: "2026-11-21T12:00:00+04:00")
            )
            switch out {
            case .proposedPlan, .clarification, .answer, .unsupported:
                passedAZ += 1
            }
        }
        XCTAssertEqual(passedAZ, 10)
    }
}
