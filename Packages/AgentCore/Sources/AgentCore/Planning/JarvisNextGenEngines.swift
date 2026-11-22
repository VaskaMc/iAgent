import Foundation
import CryptoKit

// MARK: - Yansıma ve Ön-Yüzleşme Motoru (Claude Bilge)

public struct CalendarSlotSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let location: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        startDate: Date,
        endDate: Date,
        location: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
    }
}

public enum ReflectionSeverity: String, Codable, Comparable, Sendable, Equatable {
    case info
    case warning
    case blocking

    private var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .blocking: return 2
        }
    }

    public static func < (lhs: ReflectionSeverity, rhs: ReflectionSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum ReflectionCategory: String, Codable, Equatable, Sendable {
    case calendarConflict
    case etaTravelRisk
    case ambiguousRecipient
    case missingParameter
    case lockedDeviceRestriction
    case calendarWriteOnlyBlindSpot
    case riskEscalation
}

public enum ReflectionSuggestedPatch: Codable, Equatable, Sendable {
    case shiftStepTime(stepId: String, deltaMinutes: Int)
    case removeStep(stepId: String)
    case selectRecipient(stepId: String, handle: String)
}

public struct ReflectionAdvisory: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let stepId: String?
    public let severity: ReflectionSeverity
    public let category: ReflectionCategory
    public let messageTR: String
    public let messageAZ: String
    public let suggestedPatches: [ReflectionSuggestedPatch]

    public init(
        id: UUID = UUID(),
        stepId: String? = nil,
        severity: ReflectionSeverity,
        category: ReflectionCategory,
        messageTR: String,
        messageAZ: String,
        suggestedPatches: [ReflectionSuggestedPatch] = []
    ) {
        self.id = id
        self.stepId = stepId
        self.severity = severity
        self.category = category
        self.messageTR = messageTR
        self.messageAZ = messageAZ
        self.suggestedPatches = suggestedPatches
    }
}

public struct ReflectionReport: Codable, Equatable, Sendable {
    public let taskId: UUID
    public let revisionNumber: Int
    public let approvalDigestSnapshot: String
    public let advisories: [ReflectionAdvisory]
    public let hasBlockingIssues: Bool
    public let summaryTR: String
    public let summaryAZ: String

    public init(
        taskId: UUID,
        revisionNumber: Int,
        approvalDigestSnapshot: String,
        advisories: [ReflectionAdvisory],
        hasBlockingIssues: Bool,
        summaryTR: String,
        summaryAZ: String = ""
    ) {
        self.taskId = taskId
        self.revisionNumber = revisionNumber
        self.approvalDigestSnapshot = approvalDigestSnapshot
        self.advisories = advisories
        self.hasBlockingIssues = hasBlockingIssues
        self.summaryTR = summaryTR
        self.summaryAZ = summaryAZ
    }
}

/// Kullanıcı onayından önce planı yan etkisiz simüle eden yansıma motoru.
public actor JarvisReflectionEngine {
    public init() {}

    public func analyze(
        revision: PlanRevision,
        task: AgentTask,
        existingEvents: [CalendarSlotSnapshot] = [],
        estimatedTravelMinutes: Int? = nil,
        isDeviceLocked: Bool = false,
        isWriteOnlyCalendar: Bool = false
    ) async -> ReflectionReport {
        var advisories: [ReflectionAdvisory] = []

        if revision.isInvalidated {
            advisories.append(
                ReflectionAdvisory(
                    stepId: nil,
                    severity: .blocking,
                    category: .missingParameter,
                    messageTR: "Bu plan revizyonu geçersiz kılınmış; yürütme öncesi yeni onay mührü üretilmelidir.",
                    messageAZ: "Bu plan versiyası ləğv edilib; icradan əvvəl yeni təsdiq möhürü yaradılmalıdır."
                )
            )
        }

        if isWriteOnlyCalendar {
            let hasCalendarReadOrBriefing = revision.steps.contains {
                $0.action == .calendarRead || $0.action == .briefingCompose
            }
            let hasCalendarWrite = revision.steps.contains { $0.action == .calendarCreate }
            if hasCalendarReadOrBriefing {
                advisories.append(
                    ReflectionAdvisory(
                        stepId: revision.steps.first(where: { $0.action == .calendarRead || $0.action == .briefingCompose })?.id,
                        severity: .blocking,
                        category: .calendarWriteOnlyBlindSpot,
                        messageTR: "Takvim izni yalnızca yazma (.writeOnly) düzeyinde; ajanda okunamıyor.",
                        messageAZ: "Təqvim icazəsi yalnız yazma (.writeOnly) səviyyəsindədir; cədvəl oxunmur."
                    )
                )
            } else if hasCalendarWrite {
                advisories.append(
                    ReflectionAdvisory(
                        stepId: revision.steps.first(where: { $0.action == .calendarCreate })?.id,
                        severity: .info,
                        category: .calendarWriteOnlyBlindSpot,
                        messageTR: "Takvim izni .writeOnly olduğu için mevcut etkinliklerle çakışma denetlenemedi.",
                        messageAZ: "Təqvim icazəsi .writeOnly olduğu üçün mövcud görüşlərlə toqquşma yoxlanılmadı."
                    )
                )
            }
        }

        for step in revision.steps {
            let spec = ActionCatalog.spec(for: step.action)
            if isDeviceLocked && spec.requiresUnlockedDevice {
                advisories.append(
                    ReflectionAdvisory(
                        stepId: step.id,
                        severity: .blocking,
                        category: .lockedDeviceRestriction,
                        messageTR: "Cihaz kilitliyken '\(step.action.rawValue)' adımı çalıştırılamaz; önce kilit açılmalıdır.",
                        messageAZ: "Cihaz kilidli ikən '\(step.action.rawValue)' addımı icra edilə bilməz; əvvəlcə kilidi açın.",
                        suggestedPatches: [.removeStep(stepId: step.id)]
                    )
                )
            }

            let tier = ActionRiskTier.classify(
                action: step.action,
                shortcutLabel: step.parameters.shortcutLabel,
                shortcutInput: step.parameters.shortcutInput
            )
            if tier == .tier3BiometricRequired {
                advisories.append(
                    ReflectionAdvisory(
                        stepId: step.id,
                        severity: .info,
                        category: .riskEscalation,
                        messageTR: "'\(step.action.rawValue)' adımı yüksek riskli (Tier-3) kabul edildiği için biyometrik onay gerektirir.",
                        messageAZ: "'\(step.action.rawValue)' addımı yüksək riskli (Tier-3) sayıldığı üçün biometrik təsdiq tələb edir."
                    )
                )
            }

            if [.messagesCompose, .mailCompose, .phoneCall].contains(step.action) {
                let resolved = (step.parameters.resolvedRecipientHandle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let query = (step.parameters.recipientQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if resolved.isEmpty {
                    let severity: ReflectionSeverity = query.isEmpty ? .blocking : .warning
                    let category: ReflectionCategory = query.isEmpty ? .missingParameter : .ambiguousRecipient
                    advisories.append(
                        ReflectionAdvisory(
                            stepId: step.id,
                            severity: severity,
                            category: category,
                            messageTR: query.isEmpty
                                ? "Alıcı bilgisi eksik; iletişim adımı öncesi kişi seçilmelidir."
                                : "'\(query)' için kesin telefon/e-posta adresi henüz seçilmedi.",
                            messageAZ: query.isEmpty
                                ? "Alıcı məlumatı çatışmır; əlaqə addımından əvvəl şəxs seçilməlidir."
                                : "'\(query)' üçün dəqiq nömrə/e-poçt hələ seçilməyib."
                        )
                    )
                }
            }

            if step.action == .calendarCreate,
               let startStr = step.parameters.startISO8601,
               let stepStart = PlanValidator.parseISO8601(startStr) {
                let durationMinutes = step.parameters.durationMinutes ?? 30
                let stepEnd = stepStart.addingTimeInterval(TimeInterval(durationMinutes * 60))

                // Takvim çakışma kontrolü
                for event in existingEvents where stepStart < event.endDate && stepEnd > event.startDate {
                    let shiftDelta = max(15, Int(ceil(event.endDate.timeIntervalSince(stepStart) / 60.0)))
                    advisories.append(
                        ReflectionAdvisory(
                            stepId: step.id,
                            severity: .warning,
                            category: .calendarConflict,
                            messageTR: "'\(step.parameters.title ?? "Etkinlik")' kaydı mevcut '\(event.title)' etkinliğiyle çakışıyor.",
                            messageAZ: "'\(step.parameters.title ?? "Tədbir")' mövcud '\(event.title)' görüşü ilə toqquşur.",
                            suggestedPatches: [
                                .shiftStepTime(stepId: step.id, deltaMinutes: shiftDelta),
                                .removeStep(stepId: step.id)
                            ]
                        )
                    )
                }

                // ETA yetişme riski kontrolü (görev zamanı ve önceki etkinlik boşluğu)
                if let travelMinutes = estimatedTravelMinutes, travelMinutes > 0 {
                    let leadMinutesFromNow = stepStart.timeIntervalSince(task.createdAt) / 60.0
                    if leadMinutesFromNow >= 0 && leadMinutesFromNow < Double(travelMinutes) {
                        let deficit = max(15, Int(ceil(Double(travelMinutes) - leadMinutesFromNow)))
                        advisories.append(
                            ReflectionAdvisory(
                                stepId: step.id,
                                severity: .warning,
                                category: .etaTravelRisk,
                                messageTR: "Tahmini yol süresi (\(travelMinutes) dk), etkinlik başlangıcına kalan süreden uzun; yetişme riski var.",
                                messageAZ: "Təxmini yol vaxtı (\(travelMinutes) dəq) tədbirin başlanmasına qalan vaxtdan uzundur.",
                                suggestedPatches: [.shiftStepTime(stepId: step.id, deltaMinutes: deficit)]
                            )
                        )
                    } else {
                        for event in existingEvents where event.endDate <= stepStart {
                            let gapMinutes = stepStart.timeIntervalSince(event.endDate) / 60.0
                            if gapMinutes < Double(travelMinutes) {
                                let deficit = max(15, Int(ceil(Double(travelMinutes) - gapMinutes)))
                                advisories.append(
                                    ReflectionAdvisory(
                                        stepId: step.id,
                                        severity: .warning,
                                        category: .etaTravelRisk,
                                        messageTR: "'\(event.title)' sonrası \(Int(gapMinutes)) dk boşluk \(travelMinutes) dk yol süresi için yetersiz.",
                                        messageAZ: "'\(event.title)' sonrası \(Int(gapMinutes)) dəq ara \(travelMinutes) dəq yol üçün kifayət deyil.",
                                        suggestedPatches: [.shiftStepTime(stepId: step.id, deltaMinutes: deficit)]
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }

        // Harita/ETA içeren planlarda yaklaşan takvim etkinliği için yetişme uyarısı
        if let travelMinutes = estimatedTravelMinutes,
           travelMinutes > 0,
           revision.steps.contains(where: { $0.action == .mapsDirections || $0.action == .mapsEstimateETA }) {
            for event in existingEvents {
                let remaining = event.startDate.timeIntervalSince(task.createdAt) / 60.0
                if remaining >= 0 && remaining < Double(travelMinutes) {
                    advisories.append(
                        ReflectionAdvisory(
                            stepId: revision.steps.first(where: { $0.action == .mapsDirections || $0.action == .mapsEstimateETA })?.id,
                            severity: .warning,
                            category: .etaTravelRisk,
                            messageTR: "'\(event.title)' etkinliğine \(Int(remaining)) dk kaldı ancak tahmini ulaşım \(travelMinutes) dk.",
                            messageAZ: "'\(event.title)' görüşünə \(Int(remaining)) dəq qalıb, lakin təxmini yol \(travelMinutes) dəq-dir."
                        )
                    )
                }
            }
        }

        let hasBlocking = advisories.contains { $0.severity == .blocking }
        let warningCount = advisories.filter { $0.severity == .warning }.count
        let blockingCount = advisories.filter { $0.severity == .blocking }.count

        let summaryTR: String
        let summaryAZ: String
        if advisories.isEmpty {
            summaryTR = "Ön denetim temiz; çakışma veya engel tespit edilmedi."
            summaryAZ = "İlkin yoxlama təmizdir; toqquşma və ya maneə aşkarlanmadı."
        } else {
            summaryTR = "Ön denetim tamamlandı: \(blockingCount) engelleyici, \(warningCount) uyarı bulgusu."
            summaryAZ = "İlkin yoxlama tamamlandı: \(blockingCount) bloklayıcı, \(warningCount) xəbərdarlıq."
        }

        return ReflectionReport(
            taskId: task.id,
            revisionNumber: revision.revisionNumber,
            approvalDigestSnapshot: revision.approvalDigest,
            advisories: advisories,
            hasBlockingIssues: hasBlocking,
            summaryTR: summaryTR,
            summaryAZ: summaryAZ
        )
    }

    nonisolated public func applyPatch(
        _ patch: ReflectionSuggestedPatch,
        to revision: inout PlanRevision,
        via coordinator: ExecutionCoordinator
    ) throws -> PlanRevision {
        switch patch {
        case .shiftStepTime(let stepId, let deltaMinutes):
            return try coordinator.shiftStepTime(stepId: stepId, minutes: deltaMinutes, from: &revision)
        case .removeStep(let stepId):
            return try coordinator.removeStep(stepId: stepId, from: &revision)
        case .selectRecipient(let stepId, let handle):
            return CanonicalApprovalDigest.rebuildRevisionWithUpdatedSteps(
                from: &revision,
                transform: { steps in
                    steps.map { step in
                        var copy = step
                        if copy.id == stepId {
                            copy.parameters.resolvedRecipientHandle = handle
                        }
                        return copy
                    }
                },
                now: Date()
            )
        }
    }
}

// MARK: - Uzman Sürüsü / Specialist Swarm (Antigravity Bilge)

public enum SwarmSpecialistRole: String, Codable, CaseIterable, Sendable {
    case plannerAgent
    case scheduleStrategist
    case memoryLibrarian
    case securityGuardian
}

public struct SwarmAgentOpinion: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let role: SwarmSpecialistRole
    public let confidence: Double
    public let notesTR: String
    public let notesAZ: String
    public let vetoed: Bool
    public let vetoReason: String?
    public let suggestedStepAdjustments: [String]

    public init(
        id: UUID = UUID(),
        role: SwarmSpecialistRole,
        confidence: Double,
        notesTR: String,
        notesAZ: String,
        vetoed: Bool = false,
        vetoReason: String? = nil,
        suggestedStepAdjustments: [String] = []
    ) {
        self.id = id
        self.role = role
        self.confidence = confidence
        self.notesTR = notesTR
        self.notesAZ = notesAZ
        self.vetoed = vetoed
        self.vetoReason = vetoReason
        self.suggestedStepAdjustments = suggestedStepAdjustments
    }
}

public struct SwarmSynthesisReport: Codable, Equatable, Sendable {
    public let taskId: UUID
    public let opinions: [SwarmAgentOpinion]
    public let recommendedSteps: [ActionStep]
    public let hasSecurityVeto: Bool
    public let securityVetoReason: String?
    public let summaryTR: String
    public let summaryAZ: String

    public init(
        taskId: UUID,
        opinions: [SwarmAgentOpinion],
        recommendedSteps: [ActionStep],
        hasSecurityVeto: Bool,
        securityVetoReason: String? = nil,
        summaryTR: String,
        summaryAZ: String
    ) {
        self.taskId = taskId
        self.opinions = opinions
        self.recommendedSteps = recommendedSteps
        self.hasSecurityVeto = hasSecurityVeto
        self.securityVetoReason = securityVetoReason
        self.summaryTR = summaryTR
        self.summaryAZ = summaryAZ
    }
}

/// 4 alan uzmanını yapılandırılmış eşzamanlılıkla (`withTaskGroup`) çalıştırıp sentezleyen orkestratör.
/// `SecurityGuardian` vetosu hiçbir uzman tarafından geçersiz kılınamaz.
public actor JarvisSpecialistSwarm {
    public init() {}

    public func evaluate(
        task: AgentTask,
        revision: PlanRevision,
        reflection: ReflectionReport? = nil,
        memoryHits: [MemoryEntry] = [],
        isDeviceLocked: Bool = false
    ) async -> SwarmSynthesisReport {
        let collected = await withTaskGroup(of: SwarmAgentOpinion.self) { group in
            for role in SwarmSpecialistRole.allCases {
                group.addTask {
                    Self.evaluateSpecialist(
                        role: role,
                        task: task,
                        revision: revision,
                        reflection: reflection,
                        memoryHits: memoryHits,
                        isDeviceLocked: isDeviceLocked
                    )
                }
            }
            var results: [SwarmAgentOpinion] = []
            for await opinion in group {
                results.append(opinion)
            }
            return results
        }

        let order = SwarmSpecialistRole.allCases
        let sortedOpinions = collected.sorted { lhs, rhs in
            let lIdx = order.firstIndex(of: lhs.role) ?? 0
            let rIdx = order.firstIndex(of: rhs.role) ?? 0
            return lIdx < rIdx
        }

        let securityOpinion = sortedOpinions.first { $0.role == .securityGuardian }
        let hasSecurityVeto = securityOpinion?.vetoed ?? false
        let vetoReason = hasSecurityVeto ? securityOpinion?.vetoReason : nil
        let recommendedSteps = hasSecurityVeto ? [] : revision.steps

        let summaryTR: String
        let summaryAZ: String
        if hasSecurityVeto {
            summaryTR = "Güvenlik Muhafızı planı veto etti: \(vetoReason ?? "Güvenlik ilkesi ihlali")."
            summaryAZ = "Təhlükəsizlik Müşahidəçisi planı veto etdi: \(vetoReason ?? "Təhlükəsizlik qaydası pozuntusu")."
        } else {
            summaryTR = "4 uzman görüşü sentezlendi; \(recommendedSteps.count) adım onay için hazır."
            summaryAZ = "4 mütəxəssis rəyi birləşdirildi; \(recommendedSteps.count) addım təsdiqə hazırdır."
        }

        return SwarmSynthesisReport(
            taskId: task.id,
            opinions: sortedOpinions,
            recommendedSteps: recommendedSteps,
            hasSecurityVeto: hasSecurityVeto,
            securityVetoReason: vetoReason,
            summaryTR: summaryTR,
            summaryAZ: summaryAZ
        )
    }

    private static func evaluateSpecialist(
        role: SwarmSpecialistRole,
        task: AgentTask,
        revision: PlanRevision,
        reflection: ReflectionReport?,
        memoryHits: [MemoryEntry],
        isDeviceLocked: Bool
    ) -> SwarmAgentOpinion {
        switch role {
        case .plannerAgent:
            let stepSummary = revision.steps.map(\.action.rawValue).joined(separator: " -> ")
            let validCount = revision.steps.count <= PlanBudgetLimits.v2Default.maxTotalSteps
            return SwarmAgentOpinion(
                role: .plannerAgent,
                confidence: validCount ? 0.92 : 0.45,
                notesTR: "Plan akışı (\(revision.steps.count) adım): \(stepSummary).",
                notesAZ: "Plan axını (\(revision.steps.count) addım): \(stepSummary).",
                vetoed: false,
                suggestedStepAdjustments: validCount ? [] : ["Adım sayısı \(PlanBudgetLimits.v2Default.maxTotalSteps) sınırına indirilmeli."]
            )

        case .scheduleStrategist:
            let scheduleIssues = reflection?.advisories.filter {
                $0.category == .calendarConflict || $0.category == .etaTravelRisk || $0.category == .calendarWriteOnlyBlindSpot
            } ?? []
            if scheduleIssues.isEmpty {
                return SwarmAgentOpinion(
                    role: .scheduleStrategist,
                    confidence: 0.9,
                    notesTR: "Zamanlama ve ulaşım marjlarında çakışma görülmedi.",
                    notesAZ: "Zamanlama və yol vaxtında toqquşma aşkarlanmadı."
                )
            } else {
                return SwarmAgentOpinion(
                    role: .scheduleStrategist,
                    confidence: 0.72,
                    notesTR: "\(scheduleIssues.count) zamanlama/ETA uyarısı saptandı.",
                    notesAZ: "\(scheduleIssues.count) zamanlama/ETA xəbərdarlığı tapıldı.",
                    suggestedStepAdjustments: scheduleIssues.map(\.messageTR)
                )
            }

        case .memoryLibrarian:
            if memoryHits.isEmpty {
                return SwarmAgentOpinion(
                    role: .memoryLibrarian,
                    confidence: 0.85,
                    notesTR: "Bu görevle eşleşen ek kişisel tercih kaydı bulunmadı.",
                    notesAZ: "Bu tapşırığa uyğun əlavə şəxsi yaddaş qeydi tapılmadı."
                )
            }
            let sensitiveCount = memoryHits.filter { $0.privacyTier == .sensitivePersonal }.count
            return SwarmAgentOpinion(
                role: .memoryLibrarian,
                confidence: 0.91,
                notesTR: "\(memoryHits.count) hafıza eşleşmesi bağlama eklendi (\(sensitiveCount) yalnız cihaz içi).",
                notesAZ: "\(memoryHits.count) yaddaş uyğunluğu kontekstə əlavə edildi (\(sensitiveCount) yalnız cihaz daxili)."
            )

        case .securityGuardian:
            var violations: [String] = []
            if revision.isInvalidated {
                violations.append("Geçersiz kılınmış revizyon çalıştırılamaz.")
            }

            for step in revision.steps {
                let spec = ActionCatalog.spec(for: step.action)
                let tier = ActionRiskTier.classify(
                    action: step.action,
                    shortcutLabel: step.parameters.shortcutLabel,
                    shortcutInput: step.parameters.shortcutInput
                )

                if isDeviceLocked && (tier == .tier3BiometricRequired || spec.requiresUnlockedDevice) {
                    violations.append("Kilitli cihazda '\(step.action.rawValue)' eylemi engellendi.")
                }

                let textFields = [
                    step.parameters.title,
                    step.parameters.noteContent,
                    step.parameters.query,
                    step.parameters.body,
                    step.parameters.subject,
                    step.parameters.shortcutInput
                ].compactMap { $0 }
                if textFields.contains(where: { MemorySecretGuard.containsSensitiveSecret($0) }) {
                    violations.append("Adım '\(step.id)' içinde hassas sır/kimlik verisi tespit edildi.")
                }

                if step.parameters.untrustedSourceText != nil &&
                    ![ActionKind.textSummarizeAndNote, .notesCreate, .assistantReply].contains(step.action) {
                    violations.append("Güvenilmeyen kaynak metni üzerinden '\(step.action.rawValue)' yürütmesi veto edildi.")
                }
            }

            if violations.isEmpty {
                return SwarmAgentOpinion(
                    role: .securityGuardian,
                    confidence: 0.97,
                    notesTR: "Sıfır-güven ve gizlilik kontrolleri geçti.",
                    notesAZ: "Sıfır-güvən və məxfilik yoxlamaları uğurla keçdi.",
                    vetoed: false
                )
            } else {
                let reason = violations.joined(separator: " ")
                return SwarmAgentOpinion(
                    role: .securityGuardian,
                    confidence: 1.0,
                    notesTR: "Güvenlik vetosu uygulandı: \(reason)",
                    notesAZ: "Təhlükəsizlik vetosu tətbiq edildi: \(reason)",
                    vetoed: true,
                    vetoReason: reason
                )
            }
        }
    }
}

// MARK: - Yapay Ürün (Artifact) Kasası (Antigravity Bilge)

public enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    case dailyBriefing = "daily_briefing"
    case meetingDossier = "meeting_dossier"
    case executionReport = "execution_report"
}

public struct JarvisArtifact: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: ArtifactKind
    public var title: String
    public var markdownBody: String
    public var revisionNumber: Int
    public var contentSHA256: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: ArtifactKind,
        title: String,
        markdownBody: String,
        revisionNumber: Int = 1,
        contentSHA256: String? = nil,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.markdownBody = markdownBody
        self.revisionNumber = revisionNumber
        self.contentSHA256 = contentSHA256 ?? Self.computeSHA256(title: title, markdownBody: markdownBody)
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public static func computeSHA256(title: String, markdownBody: String) -> String {
        let digest = SHA256.hash(data: Data("\(title)\n\(markdownBody)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum ArtifactVaultError: Error, Equatable, Sendable {
    case emptyTitleOrBody
    case sensitiveSecretRejected
    case artifactNotFound(UUID)
}

public enum ArtifactSecretGuard {
    public static func validateNoSecrets(title: String, markdownBody: String) throws {
        if MemorySecretGuard.containsSensitiveSecret(title)
            || MemorySecretGuard.containsSensitiveSecret(markdownBody) {
            throw ArtifactVaultError.sensitiveSecretRejected
        }
    }
}

/// Günlük brifing, toplantı dosyası ve yürütme raporlarını SHA-256 revizyon takibiyle saklar.
public actor JarvisArtifactVault {
    private struct DiskPayload: Codable, Sendable {
        let schemaVersion: Int
        let artifacts: [JarvisArtifact]
    }

    private let fileURL: URL?
    private var artifacts: [JarvisArtifact] = []
    private var transientQueryCache: [String: [UUID]] = [:]

    public init(fileURL: URL? = nil) throws {
        self.fileURL = fileURL
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            if !data.isEmpty {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let payload = try? decoder.decode(DiskPayload.self, from: data) {
                    self.artifacts = payload.artifacts
                } else {
                    self.artifacts = try decoder.decode([JarvisArtifact].self, from: data)
                }
            }
        }
    }

    @discardableResult
    public func createOrUpdate(
        id: UUID? = nil,
        kind: ArtifactKind,
        title: String,
        markdownBody: String,
        now: Date = Date()
    ) throws -> JarvisArtifact {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = markdownBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanBody.isEmpty else {
            throw ArtifactVaultError.emptyTitleOrBody
        }
        try ArtifactSecretGuard.validateNoSecrets(title: cleanTitle, markdownBody: cleanBody)

        let result: JarvisArtifact
        if let id, let idx = artifacts.firstIndex(where: { $0.id == id }) {
            var existing = artifacts[idx]
            existing.title = cleanTitle
            existing.markdownBody = cleanBody
            existing.revisionNumber += 1
            existing.contentSHA256 = JarvisArtifact.computeSHA256(title: cleanTitle, markdownBody: cleanBody)
            existing.updatedAt = now
            artifacts[idx] = existing
            result = existing
        } else {
            let created = JarvisArtifact(
                id: id ?? UUID(),
                kind: kind,
                title: cleanTitle,
                markdownBody: cleanBody,
                revisionNumber: 1,
                createdAt: now,
                updatedAt: now
            )
            artifacts.append(created)
            result = created
        }

        transientQueryCache.removeAll()
        try persist()
        return result
    }

    public func list(kind: ArtifactKind? = nil) -> [JarvisArtifact] {
        let filtered = kind == nil ? artifacts : artifacts.filter { $0.kind == kind }
        return filtered.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func search(query: String) -> [JarvisArtifact] {
        let normalized = TurkicTextNormalizer.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !normalized.isEmpty else {
            return list()
        }
        let tokens = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let matches = artifacts.filter { artifact in
            let normTitle = TurkicTextNormalizer.normalize(artifact.title)
            let normBody = TurkicTextNormalizer.normalize(artifact.markdownBody)
            return tokens.allSatisfy { normTitle.contains($0) || normBody.contains($0) }
        }.sorted { $0.updatedAt > $1.updatedAt }
        transientQueryCache[normalized] = matches.map(\.id)
        return matches
    }

    /// Geçici oturum önbelleğini temizler; kalıcı tüm yapay ürünleri (artifact) korur.
    public func clearPreservingArtifacts() {
        transientQueryCache.removeAll()
    }

    private func persist() throws {
        guard let fileURL else { return }
        let parentDir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(DiskPayload(schemaVersion: 1, artifacts: artifacts))
        try data.write(to: fileURL, options: Self.secureWriteOptions)
    }

    private static var secureWriteOptions: Data.WritingOptions {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        return [.atomic, .completeFileProtection]
        #else
        return [.atomic]
        #endif
    }
}

// MARK: - Otonom Zamanlayıcı Çekirdeği (Antigravity Bilge)

public enum AutonomousTriggerKind: String, Codable, CaseIterable, Sendable {
    case morningBriefing
    case eveningBriefing
    case meetingPrep
    case calendarDelta
    case manualTick
}

public struct AutonomousTrigger: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: AutonomousTriggerKind
    public let eventIdentifier: String?
    public let eventRevisionHash: String?
    public let scheduledFireDate: Date
    public let quietHoursRespect: Bool
    public let requiresUnlockedDevice: Bool

    public init(
        id: UUID = UUID(),
        kind: AutonomousTriggerKind,
        eventIdentifier: String? = nil,
        eventRevisionHash: String? = nil,
        scheduledFireDate: Date,
        quietHoursRespect: Bool = true,
        requiresUnlockedDevice: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.eventIdentifier = eventIdentifier
        self.eventRevisionHash = eventRevisionHash
        self.scheduledFireDate = scheduledFireDate
        self.quietHoursRespect = quietHoursRespect
        self.requiresUnlockedDevice = requiresUnlockedDevice
    }
}

/// Arka plan görevleri ve bildirimler için disk kalıcılıklı idempotent kira (lease) kilidi.
public final class FileBackedAutonomousLeaseStore: @unchecked Sendable {
    private let fileURL: URL?
    private let lock = NSLock()
    private var leases: [String: Date] = [:]

    public init(fileURL: URL? = nil) throws {
        self.fileURL = fileURL
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            if !data.isEmpty {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .millisecondsSince1970
                self.leases = try decoder.decode([String: Date].self, from: data)
            }
        }
    }

    public func tryAcquire(leaseKey: String, now: Date, ttlSeconds: TimeInterval) -> Bool {
        guard ttlSeconds > 0, !leaseKey.isEmpty else { return false }
        return lock.withLock {
            leases = leases.filter { $0.value > now }
            if let existingExpiry = leases[leaseKey], existingExpiry > now {
                return false
            }
            leases[leaseKey] = now.addingTimeInterval(ttlSeconds)
            persistLocked()
            return true
        }
    }

    public func containsValidLease(_ leaseKey: String, now: Date) -> Bool {
        lock.withLock {
            guard let expiry = leases[leaseKey] else { return false }
            return expiry > now
        }
    }

    public func releaseLease(_ leaseKey: String) {
        lock.withLock {
            leases.removeValue(forKey: leaseKey)
            persistLocked()
        }
    }

    private func persistLocked() {
        guard let fileURL else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        if let data = try? encoder.encode(leases) {
            try? data.write(to: fileURL, options: Self.secureWriteOptions)
        }
    }

    private static var secureWriteOptions: Data.WritingOptions {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        return [.atomic, .completeFileProtection]
        #else
        return [.atomic]
        #endif
    }
}

// MARK: - Saga LIFO Telafi Motoru (Codex Bilge)

public enum CompensationOutcome: String, Codable, Equatable, Sendable {
    case reverted
    case notUndoableExternally
    case compensationFailed
}

public struct CompensatedStepReceipt: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let stepId: String
    public let executorName: String
    public let outcome: CompensationOutcome
    public let detail: String
    public let compensatedAt: Date

    public init(
        id: UUID = UUID(),
        stepId: String,
        executorName: String,
        outcome: CompensationOutcome,
        detail: String,
        compensatedAt: Date = Date()
    ) {
        self.id = id
        self.stepId = stepId
        self.executorName = executorName
        self.outcome = outcome
        self.detail = detail
        self.compensatedAt = compensatedAt
    }
}

public protocol CompensableStepExecutorProtocol: StepExecutorProtocol {
    func compensate(
        step: ActionStep,
        receipt: ActionReceipt,
        now: Date
    ) async throws -> CompensatedStepReceipt
}

/// Kritik adım hatasında tamamlanmış adımları LIFO (son giren ilk çıkar) sırayla geri alan Saga motoru.
/// Dış sistem arayüzüne aktarılan eylemleri dürüstçe `.notUndoableExternally` olarak raporlar.
public actor SagaCompensationEngine {
    public init() {}

    public func compensateLIFO(
        completedSteps: [ActionStep],
        receipts: [ActionReceipt],
        executor: CompensableStepExecutorProtocol,
        now: Date = Date()
    ) async -> [CompensatedStepReceipt] {
        var receiptsByStepId: [String: ActionReceipt] = [:]
        for receipt in receipts {
            receiptsByStepId[receipt.stepId] = receipt
        }

        var compensationReceipts: [CompensatedStepReceipt] = []

        for step in completedSteps.reversed() {
            guard let receipt = receiptsByStepId[step.id] else {
                continue
            }

            switch receipt.outcome {
            case .failed, .cancelled:
                continue

            case .handedOffToUserInterface, .uncertain:
                compensationReceipts.append(
                    CompensatedStepReceipt(
                        stepId: step.id,
                        executorName: receipt.executorName,
                        outcome: .notUndoableExternally,
                        detail: "'\(step.action.rawValue)' adımı sistem arayüzüne aktarıldığı veya belirsiz olduğu için otomatik geri alınamaz.",
                        compensatedAt: now
                    )
                )

            case .succeeded:
                guard step.isUndoable && receipt.canUndo else {
                    compensationReceipts.append(
                        CompensatedStepReceipt(
                            stepId: step.id,
                            executorName: receipt.executorName,
                            outcome: .notUndoableExternally,
                            detail: "'\(step.action.rawValue)' adımı geri alınabilir olarak işaretlenmedi.",
                            compensatedAt: now
                        )
                    )
                    continue
                }

                do {
                    let result = try await executor.compensate(step: step, receipt: receipt, now: now)
                    compensationReceipts.append(result)
                } catch {
                    compensationReceipts.append(
                        CompensatedStepReceipt(
                            stepId: step.id,
                            executorName: receipt.executorName,
                            outcome: .compensationFailed,
                            detail: error.localizedDescription,
                            compensatedAt: now
                        )
                    )
                }
            }
        }

        return compensationReceipts
    }
}

// MARK: - Ses, Persona ve Azerbaycanca Fonetik Köprüsü (Bölüm 10)

public enum JarvisPersonaPreset: String, Codable, CaseIterable, Equatable, Sendable {
    case butler
    case executive
}

/// Yazılı ekran metnini bozmadan persona uyumlu `displayText` ve TTS-uyumlu `spokenText` üretir.
public enum JarvisResponseComposer {
    public static func compose(
        spokenCore: String,
        language: AgentLanguage = .turkish,
        persona: JarvisPersonaPreset = .butler
    ) -> (displayText: String, spokenText: String) {
        let trimmed = spokenCore.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("", "")
        }

        let displayText: String
        switch persona {
        case .butler:
            let normalized = TurkicTextNormalizer.normalize(trimmed)
            let alreadyPolite = normalized.hasPrefix("elbette") || normalized.hasPrefix("memnuniyetle") || normalized.hasPrefix("bas ustune")
            if alreadyPolite {
                displayText = trimmed
            } else if language == .azerbaijani {
                displayText = "Əlbəttə. \(trimmed)"
            } else {
                displayText = "Elbette. \(trimmed)"
            }
        case .executive:
            displayText = trimmed
        }

        let spokenText = AzerbaijaniPhoneticBridge.adaptForTTS(displayText, language: language)
        return (displayText: displayText, spokenText: spokenText)
    }
}

/// 45 saniyelik kayan takip penceresiyle "Hey Siri" tekrarı olmadan devam komutlarını ilişkilendirir.
public final class WakeContextSession: @unchecked Sendable {
    public let windowSeconds: TimeInterval
    private let lock = NSLock()
    private var lastInteractionAt: Date?

    public init(windowSeconds: TimeInterval = 45) {
        self.windowSeconds = windowSeconds
    }

    public func markInteraction(now: Date = Date()) {
        lock.withLock {
            lastInteractionAt = now
        }
    }

    public func isActive(now: Date = Date()) -> Bool {
        lock.withLock {
            guard let lastInteractionAt else { return false }
            let elapsed = now.timeIntervalSince(lastInteractionAt)
            return elapsed >= 0 && elapsed < windowSeconds
        }
    }

    public func reset() {
        lock.withLock {
            lastInteractionAt = nil
        }
    }
}

/// Yalnız TTS seslendirme metni için Azerbaycanca karakterleri (`ə→e`, `q→k`, `x→h`) Türkçe sese uyarlar;
/// yazılı notlara ve ekrandaki metinlere asla dokunulmaz.
public enum AzerbaijaniPhoneticBridge {
    public static func adaptForTTS(_ text: String, language: AgentLanguage) -> String {
        guard language == .azerbaijani else { return text }
        var adapted = text
        let mapping: [(String, String)] = [
            ("Ə", "E"),
            ("ə", "e"),
            ("Q", "K"),
            ("q", "k"),
            ("X", "H"),
            ("x", "h")
        ]
        for (source, target) in mapping {
            adapted = adapted.replacingOccurrences(of: source, with: target)
        }
        return adapted
    }
}
