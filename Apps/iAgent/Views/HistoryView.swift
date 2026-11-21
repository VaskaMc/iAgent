import SwiftUI
import AgentCore

public enum HistoryRetentionPolicy: String, CaseIterable, Codable, Sendable {
    case thirtyDays = "30 Gün"
    case doNotKeep = "Geçmişi Tutma"
}

/// "Ne yaptın?" geçmiş ekranı: gerçek makbuzları ve görev durumlarını gösterir.
/// Kalıcı iAgent notları geçmiş silme işleminden ayrı tutulur.
struct HistoryView: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        List {
            Section("Saklama Politikası") {
                Picker("Görev Geçmişi", selection: $coordinator.historyRetention) {
                    ForEach(HistoryRetentionPolicy.allCases, id: \.self) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                Button("Görev Geçmişini Temizle (Notlar Korunur)", role: .destructive) {
                    coordinator.clearTaskHistoryPreservingNotes()
                }
            }

            Section("Görev Kayıtları") {
                if coordinator.taskHistory.isEmpty {
                    Text("Henüz kaydedilmiş görev geçmişi yok.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(coordinator.taskHistory) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.task.rawUtterance)
                                    .font(.headline)
                                Spacer()
                                Text(summaryBadge(item.task.state))
                                    .font(.caption.bold())
                            }
                            Text("Model: \(item.task.selectedModelPath)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(item.receipts) { receipt in
                                Text("• \(receipt.stepId): \(receipt.spokenVerbTR) (\(receipt.detail))")
                                    .font(.caption)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Ne Yaptın?")
    }

    private func summaryBadge(_ state: TaskLifecycleState) -> String {
        switch state {
        case .received: return "Alındı"
        case .awaitingClarification: return "Açıklama Bekliyor"
        case .awaitingConfirmation: return "Onay Bekliyor"
        case .executing: return "Yürütülüyor"
        case .finished(let summary):
            switch summary {
            case .completed: return "Başarılı"
            case .partiallyCompleted: return "Kısmen Tamamlandı"
            case .cancelled: return "İptal Edildi"
            case .awaitingUserAction: return "Kullanıcı İşlemi Bekleniyor"
            case .unknownOutcome: return "Sonucu Bilinmiyor"
            case .unsupported: return "Desteklenmiyor"
            case .refused: return "Güvenlik Reddi"
            }
        }
    }
}
