import SwiftUI
import AgentCore
import PhoneActions

/// Çok adımlı plan, eksik bilgi sorusu, kişi seçimi, plan düzenleme ve onay ekranı.
struct ConversationPlanView: View {
    @Bindable var coordinator: AppCoordinator
    let planState: ActivePlanPresentation
    @State private var clarificationReply: String = ""

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Plan (Revizyon \(planState.revision.revisionNumber))")
                        .font(.headline)
                    Spacer()
                    Text(planState.modelPathLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let question = planState.clarificationQuestion {
                    Text(question)
                        .font(.body)
                        .foregroundStyle(.orange)
                    HStack {
                        TextField("Yanıtını yaz...", text: $clarificationReply)
                            .textFieldStyle(.roundedBorder)
                        Button("Tamamla") {
                            let reply = clarificationReply
                            clarificationReply = ""
                            Task { await coordinator.submitUserUtterance(reply, source: .inAppText) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if !planState.disambiguationCandidates.isEmpty {
                    Text("Kişi Seçimi Gerekli:")
                        .font(.subheadline.bold())
                    ForEach(planState.disambiguationCandidates) { candidate in
                        Button {
                            coordinator.selectContactCandidate(candidate)
                        } label: {
                            HStack {
                                Text(candidate.displayName)
                                Spacer()
                                Text(candidate.phoneNumbers.first ?? candidate.emailAddresses.first ?? "")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                ForEach(planState.revision.steps) { step in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(step.action.rawValue)
                                .font(.caption.monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                            Spacer()
                            Text(statusLabel(step.status))
                                .font(.caption.bold())
                        }
                        if let title = step.parameters.title ?? step.parameters.noteContent ?? step.parameters.shortcutLabel {
                            Text(title)
                                .font(.subheadline.weight(.medium))
                        }
                        if let when = step.parameters.startISO8601 ?? step.parameters.dueISO8601 {
                            Text("Zaman: \(when)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let recipient = step.parameters.resolvedRecipientHandle ?? step.parameters.recipientQuery {
                            Text("Hedef: \(recipient)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }

                if !planState.isFinished {
                    HStack(spacing: 8) {
                        Button("Onayla ve Uygula") {
                            Task { await coordinator.confirmAndExecuteActivePlan() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(coordinator.isExecutingPlan)

                        if planState.revision.steps.count > 1 {
                            Button("2. Adımı Çıkar") {
                                coordinator.editActivePlanRemoveSecondStep()
                            }
                            .buttonStyle(.bordered)
                        }

                        Button("Vazgeç", role: .destructive) {
                            coordinator.cancelActivePlan()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusLabel(_ status: StepExecutionStatus) -> String {
        switch status {
        case .pending: return "Bekliyor"
        case .ready: return "Hazır"
        case .inUserInterface: return "Kullanıcı Arayüzünde"
        case .completed: return "Tamamlandı"
        case .cancelled: return "İptal"
        case .failed: return "Hata"
        case .uncertain: return "Sonuç Doğrulanamadı"
        case .skippedDueToDependency: return "Atlandı"
        }
    }
}
