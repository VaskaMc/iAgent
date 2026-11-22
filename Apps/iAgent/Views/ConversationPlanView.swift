import SwiftUI
import AgentCore
import PhoneActions

/// Çok adımlı plan, ön-simülasyon yansıması, 4 uzman sentezi, satır içi zaman kaydırma, kişi seçimi ve onay ekranı.
struct ConversationPlanView: View {
    @Bindable var coordinator: AppCoordinator
    let planState: ActivePlanPresentation
    @State private var clarificationReply: String = ""

    private var hasSecurityVeto: Bool {
        planState.swarmReport?.hasSecurityVeto ?? false
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Plan (Revizyon \(planState.revision.revisionNumber))")
                        .font(.headline.monospacedDigit())
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
                            .frame(minHeight: 44)
                        Button("Tamamla") {
                            let reply = clarificationReply
                            clarificationReply = ""
                            Task { await coordinator.submitUserUtterance(reply, source: .inAppText) }
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
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
                            .frame(minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let reflection = planState.reflectionReport {
                    reflectionCard(reflection)
                }

                if let swarm = planState.swarmReport {
                    swarmSynthesisCard(swarm)
                }

                ForEach(planState.revision.steps) { step in
                    stepRow(step)
                }

                if !planState.isFinished {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Button {
                                Task { await coordinator.confirmAndExecuteActivePlan() }
                            } label: {
                                Label(
                                    "Onayla ve Uygula",
                                    systemImage: hasSecurityVeto ? "lock.shield.fill" : "checkmark.shield.fill"
                                )
                                .frame(minHeight: 36)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(hasSecurityVeto ? .red : .accentColor)
                            .disabled(coordinator.isExecutingPlan || hasSecurityVeto)

                            if planState.revision.steps.count > 1 {
                                Button("2. Adımı Çıkar") {
                                    coordinator.editActivePlanRemoveSecondStep()
                                }
                                .buttonStyle(.bordered)
                                .frame(minHeight: 44)
                            }

                            Button("Vazgeç", role: .destructive) {
                                coordinator.cancelActivePlan()
                            }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                        }

                        if hasSecurityVeto {
                            Text("Güvenlik vetosu nedeniyle yürütme kilitlendi.")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func reflectionCard(_ report: ReflectionReport) -> some View {
        let accentColor: Color = report.hasBlockingIssues ? .red : (report.advisories.isEmpty ? .green : .orange)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: report.hasBlockingIssues ? "exclamationmark.octagon.fill" : (report.advisories.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"))
                    .foregroundStyle(accentColor)
                Text("Ön-Simülasyon (Reflection)")
                    .font(.caption.bold())
                Spacer()
                Text("\(report.advisories.count) bulgu")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(report.summaryTR)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(report.advisories) { advisory in
                VStack(alignment: .leading, spacing: 4) {
                    Text(advisory.messageTR)
                        .font(.caption)
                        .foregroundStyle(advisory.severity == .blocking ? Color.red : Color.primary)

                    if !planState.isFinished, !advisory.suggestedPatches.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(advisory.suggestedPatches.enumerated()), id: \.offset) { _, patch in
                                switch patch {
                                case .shiftStepTime(let stepId, let delta):
                                    Button("+\(delta) dk Kaydır") {
                                        coordinator.shiftActivePlanStepTime(stepId: stepId, minutes: delta)
                                    }
                                    .font(.caption2.monospacedDigit())
                                    .buttonStyle(.bordered)
                                case .removeStep:
                                    EmptyView()
                                case .selectRecipient:
                                    EmptyView()
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jarvisGlassSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous), tint: accentColor)
    }

    @ViewBuilder
    private func swarmSynthesisCard(_ report: SwarmSynthesisReport) -> some View {
        let tint: Color = report.hasSecurityVeto ? .red : .cyan
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: report.hasSecurityVeto ? "hand.raised.fill" : "cpu.fill")
                    .foregroundStyle(tint)
                Text("4 Uzman Sentezi (Swarm)")
                    .font(.caption.bold())
                Spacer()
                if report.hasSecurityVeto {
                    Text("VETO")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.2), in: Capsule())
                        .foregroundStyle(.red)
                }
            }
            Text(report.summaryTR)
                .font(.caption)
                .foregroundStyle(report.hasSecurityVeto ? Color.red : Color.secondary)

            ForEach(report.opinions) { opinion in
                HStack(alignment: .top, spacing: 6) {
                    Text(roleLabel(opinion.role))
                        .font(.caption2.bold())
                        .frame(width: 76, alignment: .leading)
                    Text(opinion.notesTR)
                        .font(.caption2)
                        .foregroundStyle(opinion.vetoed ? Color.red : Color.secondary)
                    Spacer()
                    Text("\(Int((opinion.confidence * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jarvisGlassSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous), tint: tint)
    }

    @ViewBuilder
    private func stepRow(_ step: ActionStep) -> some View {
        let riskTier = ActionRiskTier.classify(
            action: step.action,
            shortcutLabel: step.parameters.shortcutLabel,
            shortcutInput: step.parameters.shortcutInput
        )
        let isTimeShiftable = !planState.isFinished && (step.action == .calendarCreate || step.action == .remindersCreate)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(step.action.rawValue)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))

                if riskTier == .tier3BiometricRequired {
                    Label("Tier-3", systemImage: "faceid")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }

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
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let recipient = step.parameters.resolvedRecipientHandle ?? step.parameters.recipientQuery {
                Text("Hedef: \(recipient)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isTimeShiftable {
                HStack(spacing: 8) {
                    Button("-15 dk") {
                        coordinator.shiftActivePlanStepTime(stepId: step.id, minutes: -15)
                    }
                    .font(.caption.monospacedDigit())
                    .buttonStyle(.bordered)
                    .frame(minWidth: 64, minHeight: 44)
                    .accessibilityLabel("\(step.parameters.title ?? "Adım") saatini 15 dakika geri al")

                    Button("+30 dk") {
                        coordinator.shiftActivePlanStepTime(stepId: step.id, minutes: 30)
                    }
                    .font(.caption.monospacedDigit())
                    .buttonStyle(.bordered)
                    .frame(minWidth: 64, minHeight: 44)
                    .accessibilityLabel("\(step.parameters.title ?? "Adım") saatini 30 dakika ileri al")
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityAction(named: "15 dakika geri al") {
            if isTimeShiftable {
                coordinator.shiftActivePlanStepTime(stepId: step.id, minutes: -15)
            }
        }
        .accessibilityAction(named: "30 dakika ileri al") {
            if isTimeShiftable {
                coordinator.shiftActivePlanStepTime(stepId: step.id, minutes: 30)
            }
        }
    }

    private func roleLabel(_ role: SwarmSpecialistRole) -> String {
        switch role {
        case .plannerAgent: return "Planlayıcı"
        case .scheduleStrategist: return "Zamanlama"
        case .memoryLibrarian: return "Hafıza"
        case .securityGuardian: return "Güvenlik"
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
