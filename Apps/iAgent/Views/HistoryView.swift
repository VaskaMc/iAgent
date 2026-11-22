import SwiftUI
import AgentCore

public enum HistoryRetentionPolicy: String, CaseIterable, Codable, Sendable {
    case thirtyDays = "30 Gün"
    case doNotKeep = "Geçmişi Tutma"
}

/// "Ne yaptın?" geçmiş ekranı: kriptografik denetim izi doğrulama rozeti, bağımsız JARVIS Hafıza Kasası ve gerçek makbuzlar.
/// Kalıcı iAgent notları, hafıza kayıtları ve brifing ürünleri geçmiş silme işleminden ayrı tutulur.
struct HistoryView: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        List {
            Section("Kriptografik Denetim İzi") {
                HStack(spacing: 10) {
                    Image(systemName: coordinator.isAuditTrailVerified ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.title3)
                        .foregroundStyle(coordinator.isAuditTrailVerified ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coordinator.isAuditTrailVerified ? "Kriptografik Denetim İzi: Doğrulandı" : "Bütünlük Uyarısı")
                            .font(.subheadline.bold())
                            .foregroundStyle(coordinator.isAuditTrailVerified ? Color.primary : Color.red)
                        Text("\(coordinator.auditTrail.allEntries().count) zincirli makbuz · SHA-256 + HMAC")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Doğrula") {
                        _ = coordinator.verifyAuditTrailIntegrity()
                    }
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 2)
            }

            Section("Saklama Politikası") {
                Picker("Görev Geçmişi", selection: $coordinator.historyRetention) {
                    ForEach(HistoryRetentionPolicy.allCases, id: \.self) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                Button("Görev Geçmişini Temizle (Notlar, Hafıza ve Brifingler Korunur)", role: .destructive) {
                    coordinator.clearTaskHistoryPreservingNotes()
                }
            }

            Section("JARVIS Hafıza Kasası") {
                Text("Notlar: \(coordinator.notes.count) · Tercihler: \(coordinator.memoryEntries.count) · Brifing/Ürün: \(coordinator.latestArtifacts.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if coordinator.memoryEntries.isEmpty {
                    Text("Kayıtlı kişisel tercih yok. Geçmiş temizlense de bu bölüm korunur.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(coordinator.memoryEntries) { entry in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.key)
                                    .font(.subheadline.bold())
                                Text(entry.value)
                                    .font(.subheadline)
                                Text("\(tierLabel(entry.privacyTier)) · Kaynak: \(entry.provenance.sourceChannel)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Unut", role: .destructive) {
                                coordinator.forgetMemory(id: entry.id)
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 2)
                    }
                }

                if let latestArtifact = coordinator.latestArtifacts.first {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Son Korunan Ürün: \(latestArtifact.title) (Rev \(latestArtifact.revisionNumber))")
                            .font(.caption.bold().monospacedDigit())
                        Text(latestArtifact.markdownBody)
                            .font(.caption2)
                            .lineLimit(3)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
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

    private func tierLabel(_ tier: MemoryPrivacyTier) -> String {
        switch tier {
        case .sensitivePersonal: return "Yalnız bu iPhone"
        case .standardLocal: return "Standart Yerel"
        case .ephemeralSession: return "Geçici Oturum"
        }
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
