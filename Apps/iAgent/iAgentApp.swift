import SwiftUI
import Observation
import AgentCore
import ModelProviders
import PhoneActions

public struct ActivePlanPresentation: Identifiable, Sendable {
    public var id: String { "\(task.id.uuidString)-\(revision.revisionNumber)" }
    public var task: AgentTask
    public var revision: PlanRevision
    public var modelPathLabel: String
    public var clarificationQuestion: String?
    public var disambiguationCandidates: [ContactCandidate] = []
    public var reflectionReport: ReflectionReport? = nil
    public var swarmReport: SwarmSynthesisReport? = nil
    public var isFinished: Bool = false
}

public struct TaskHistoryEntry: Identifiable, Sendable {
    public var id: UUID { task.id }
    public let task: AgentTask
    public let receipts: [ActionReceipt]
}

public struct CapabilityStatusItem: Sendable {
    public let title: String
    public let badge: String
    public let detail: String
}

/// Ana uygulama yaşam döngüsünü, üç paketi, Siri devirlerini ve ses/ekran durumunu koordine eder.
@MainActor
@Observable
public final class AppCoordinator {
    public static let shared = AppCoordinator()

    public let noteStore: FileBackedNoteStore
    public let quickNoteFlow: QuickNoteFlow
    public let executionCoordinator: ExecutionCoordinator
    public let consentManager = ExternalDataConsentManager()
    public let keyStore: KeychainSecretStore
    public let speechController = SpeechSessionController()
    public let sharedInbox: SharedInboxManager
    public let shortcutsBridge: ShortcutsBridgeExecutor

    public let memoryVault: FileBackedMemoryVault
    public let auditTrail: CryptographicAuditTrail
    public let artifactVault: JarvisArtifactVault
    public let reflectionEngine = JarvisReflectionEngine()
    public let specialistSwarm = JarvisSpecialistSwarm()
    public let briefingSynthesizer = BriefingSynthesizer()
    public let alarmExecutor: AlarmActionExecutor
    public var biometricExecutor: BiometricAuthExecutor
    public let circuitBreaker = CircuitBreakerRegistry()
    public let tokenLedger = SessionTokenLedger()

    private let appleModelProvider = AppleFoundationModelProvider()
    private var customExternalProvider: ExternalChatCompletionsProvider?
    private var customExternalProfile: ExternalProviderProfile?
    private let calendarExecutor: CalendarActionExecutor
    private let remindersExecutor: RemindersActionExecutor
    private let contactResolver: ContactResolver
    private let communicationExecutor: CommunicationActionExecutor
    private let mapsExecutor: MapsActionExecutor

    public var notes: [PersistentNote] = []
    public var pendingShareItems: [SharedInboxItem] = []
    public var memoryEntries: [MemoryEntry] = []
    public var latestArtifacts: [JarvisArtifact] = []
    public var activePlanState: ActivePlanPresentation?
    public var taskHistory: [TaskHistoryEntry] = []
    public var historyRetention: HistoryRetentionPolicy = .thirtyDays
    public var modelPreference: ModelUserPreference = .automatic
    public var activeModelLabel: String = "Kontrol ediliyor..."
    public var activeModelStatusDescription: String = "Apple Intelligence durumu kontrol ediliyor."
    public var lastAssistantResponse: String?
    public var isExecutingPlan: Bool = false
    public var hasCompletedOnboarding: Bool = false
    public var isAuditTrailVerified: Bool = true
    public var isDrivingSafetyActive: Bool = false
    public var isDeviceLocked: Bool = false

    public var capabilityStatuses: [CapabilityStatusItem] {
        [
            CapabilityStatusItem(title: "Yerel Notlar", badge: "Hazır", detail: "SwiftData/JSON kalıcı notlar, geri alma destekli"),
            CapabilityStatusItem(title: "Hafıza Kasası", badge: "\(memoryEntries.count) kayıt", detail: "CloudKit-kapalı yerel tercih ve köken belleği"),
            CapabilityStatusItem(title: "Takvim", badge: "İzin gerekli", detail: "Okuma ve yalnız yazma izinleri ayrı istenir"),
            CapabilityStatusItem(title: "Anımsatıcılar", badge: "İzin gerekli", detail: "Zaman bazlı EKAlarm oluşturma"),
            CapabilityStatusItem(title: "AlarmKit", badge: "Hazır", detail: "Saatli sistem alarmı ve iptal desteği"),
            CapabilityStatusItem(title: "Mesaj / E-posta", badge: "Hazır", detail: "Sistem düzenleyicisinde kullanıcı tamamlar"),
            CapabilityStatusItem(title: "Haritalar", badge: "Hazır", detail: "Doğrulanmış hedefi konum izni olmadan açar"),
            CapabilityStatusItem(title: "Kestirmeler", badge: shortcutsBridge.allBindings().isEmpty ? "Kestirme kurulmalı" : "Hazır", detail: "Adlı x-callback-url köprüsü")
        ]
    }

    public init(storageDirectory: URL? = nil) {
        let baseDir = storageDirectory ?? Self.defaultContainerDirectory()
        let notesURL = baseDir.appendingPathComponent("notes.json")
        let walURL = baseDir.appendingPathComponent("wal.json")
        let memoryURL = baseDir.appendingPathComponent("memory_vault.json")
        let auditURL = baseDir.appendingPathComponent("audit_trail.json")
        let artifactsURL = baseDir.appendingPathComponent("artifacts.json")

        let store = (try? FileBackedNoteStore(fileURL: notesURL))
            ?? (try! FileBackedNoteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("iagent-notes.json")))
        self.noteStore = store
        self.quickNoteFlow = QuickNoteFlow(noteStore: store)

        let keyStore = KeychainSecretStore()
        self.keyStore = keyStore

        let auditHost = "audit.trail.internal.iagent"
        let resolvedAuditSecret: String
        if let existingSecret = (try? keyStore.readKey(forHost: auditHost)), !existingSecret.isEmpty {
            resolvedAuditSecret = existingSecret
        } else {
            let generated = "\(UUID().uuidString)-\(UUID().uuidString)"
            try? keyStore.saveKey(generated, forHost: auditHost)
            resolvedAuditSecret = generated
        }
        let auditHMACData = Data(resolvedAuditSecret.utf8)

        self.memoryVault = (try? FileBackedMemoryVault(fileURL: memoryURL))
            ?? (try! FileBackedMemoryVault(fileURL: nil))
        self.auditTrail = (try? CryptographicAuditTrail(fileURL: auditURL, hmacKeyData: auditHMACData))
            ?? (try! CryptographicAuditTrail(fileURL: nil, hmacKeyData: auditHMACData))
        self.artifactVault = (try? JarvisArtifactVault(fileURL: artifactsURL))
            ?? (try! JarvisArtifactVault(fileURL: nil))

        let journal = try? WriteAheadJournal(fileURL: walURL)
        self.executionCoordinator = ExecutionCoordinator(clock: SystemClock(), journal: journal)
        self.sharedInbox = SharedInboxManager(inboxDirectory: SharedInboxManager.defaultInboxDirectory())
        self.shortcutsBridge = ShortcutsBridgeExecutor(opener: MockShortcutURLOpener())
        self.alarmExecutor = AlarmActionExecutor(backend: InMemoryAlarmBackend())
        self.biometricExecutor = BiometricAuthExecutor(gate: MockBiometricAuthGate(shouldSucceed: true))

        #if canImport(EventKit)
        self.calendarExecutor = CalendarActionExecutor(backend: LiveEventKitCalendarBackend())
        self.remindersExecutor = RemindersActionExecutor(backend: LiveEventKitRemindersBackend())
        #else
        self.calendarExecutor = CalendarActionExecutor(backend: InMemoryCalendarBackend())
        self.remindersExecutor = RemindersActionExecutor(backend: InMemoryRemindersBackend())
        #endif

        #if canImport(Contacts)
        self.contactResolver = ContactResolver(directory: LiveContactsDirectory())
        #else
        self.contactResolver = ContactResolver(directory: InMemoryContactDirectory())
        #endif

        self.communicationExecutor = CommunicationActionExecutor(presenter: MockSystemCommunicationPresenter())

        #if canImport(MapKit)
        self.mapsExecutor = MapsActionExecutor(backend: LiveMapKitBackend())
        #else
        self.mapsExecutor = MapsActionExecutor(backend: InMemoryMapsBackend())
        #endif

        self.memoryEntries = self.memoryVault.activeEntries()
        self.isAuditTrailVerified = self.auditTrail.verifyIntegrity()
        refreshNotesAndInbox()
        Task {
            await refreshModelAvailability()
            await refreshArtifacts()
        }
    }

    private static func defaultContainerDirectory() -> URL {
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.iagent.shared"
        ) {
            return groupURL.appendingPathComponent("iAgentData", isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("iAgent", isDirectory: true)
    }

    public func refreshNotesAndInbox() {
        try? noteStore.reloadFromDisk()
        notes = (try? noteStore.allActiveNotes()) ?? []
        pendingShareItems = (try? sharedInbox.pendingItems()) ?? []
        memoryEntries = memoryVault.activeEntries()
        isAuditTrailVerified = auditTrail.verifyIntegrity()
    }

    public func refreshArtifacts() async {
        latestArtifacts = await artifactVault.list(kind: nil)
    }

    public func refreshModelAvailability() async {
        let locale = speechController.selectedLanguage == .azerbaijani ? "az_AZ" : "tr_TR"
        let status = await appleModelProvider.recheckAvailability(for: locale)
        switch status {
        case .available(let label):
            activeModelLabel = label
            activeModelStatusDescription = "Cihaz içi Apple modeli hazır; ek anahtar gerekmez."
        default:
            if let ext = customExternalProvider {
                let extStatus = await ext.checkAvailability(for: locale)
                if case .available(let extLabel) = extStatus {
                    activeModelLabel = extLabel
                    activeModelStatusDescription = "Harici sağlayıcı yapılandırıldı."
                    return
                }
            }
            activeModelLabel = "Sabit Yerel Komutlar"
            activeModelStatusDescription = status.userFacingReasonTR
        }
    }

    public func createOnboardingSampleNote() -> PersistentNote? {
        let note = try? noteStore.createNote(
            content: "iAgent ile ilk deneme notum",
            sourceTaskId: UUID(),
            now: Date()
        )
        refreshNotesAndInbox()
        return note
    }

    /// Siri veya uygulama içi kullanıcı isteğini işler.
    @discardableResult
    public func submitUserUtterance(_ utterance: String, source: TaskSource) async -> String {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Lütfen bir istek girin." }

        speechController.wakeSession.markInteraction()
        let taskId = UUID()
        let now = Date()

        // 1. Önce sabit yerel not akışı denenir (model yokken veya uçak modunda garantili çalışır).
        if isDeviceLocked, case .search = quickNoteFlow.parseIntent(from: trimmed) {
            let lockedMsg = speechController.selectedLanguage == .azerbaijani
                ? "Cihaz kilidli ikən yaddaşdakı qeydlər axtarıla bilməz; əvvəlcə kilidi açın."
                : "Cihaz kilitliyken kayıtlı notlar aranamaz; önce kilidi açın."
            lastAssistantResponse = lockedMsg
            speechController.speakInApp(lockedMsg, source: source)
            return lockedMsg
        }
        if let outcome = try? quickNoteFlow.executeDirectIfMatched(
            utterance: trimmed,
            taskId: taskId,
            now: now,
            language: speechController.selectedLanguage
        ), outcome != .notMatched {
            refreshNotesAndInbox()
            switch outcome {
            case .noteCreated(let note, let spoken):
                let task = AgentTask(
                    id: taskId,
                    source: source,
                    locale: speechController.selectedLanguage.rawValue,
                    selectedModelPath: activeModelLabel,
                    state: .finished(.completed),
                    createdAt: now,
                    rawUtterance: trimmed
                )
                let receipt = ActionReceipt(
                    taskId: taskId,
                    revisionNumber: 1,
                    stepId: "note-1",
                    executorName: "FileBackedNoteStore",
                    outcome: .succeeded,
                    externalObjectId: note.id.uuidString,
                    timestamp: now,
                    canUndo: true,
                    spokenVerbTR: "Not kaydedildi",
                    spokenVerbAZ: "Qeyd saxlandı",
                    detail: RedactingLogger.redact(note.content)
                )
                _ = try? auditTrail.record(receipt: receipt)
                isAuditTrailVerified = auditTrail.verifyIntegrity()
                recordTaskHistory(task: task, receipts: [receipt])
                lastAssistantResponse = spoken
                speechController.speakInApp(spoken, source: source)
                return spoken
            case .notesFound(_, _, let spoken), .draftCancelled(let spoken), .needsContentClarification(let spoken):
                lastAssistantResponse = spoken
                speechController.speakInApp(spoken, source: source)
                return spoken
            case .notMatched:
                break
            }
        }

        // 2. Uzun ömürlü hibrit yönlendirici ile katmanlı plan üretimi.
        var endpoints: [ExternalModelEndpoint] = []
        if let ext = customExternalProvider, let extProfile = customExternalProfile {
            endpoints.append(ExternalModelEndpoint(provider: ext, endpointURL: extProfile.endpointURL))
        }
        let router = HybridModelRouter(
            onDeviceProvider: appleModelProvider,
            externalEndpoints: endpoints,
            consentManager: consentManager,
            circuitRegistry: circuitBreaker,
            tokenLedger: tokenLedger
        )
        let request = ModelTurnRequest(
            taskId: taskId,
            utterance: trimmed,
            locale: speechController.selectedLanguage == .azerbaijani ? "az_AZ" : "tr_TR",
            referenceDateISO8601: DateAndTimeResolver.formatISO8601(now, timeZone: .current),
            timeZoneIdentifier: TimeZone.current.identifier
        )

        do {
            let result = try await router.routeAndGenerate(
                request: request,
                preference: modelPreference,
                now: now
            )
            return await presentTurnOutcome(
                result.outcome,
                modelLabel: result.providerLabel,
                taskId: taskId,
                source: source,
                rawUtterance: trimmed,
                now: now
            )
        } catch let err as ModelProviderError {
            let msg = friendlyModelErrorMessage(err)
            lastAssistantResponse = msg
            speechController.speakInApp(msg, source: source)
            return msg
        } catch let endpointErr as EndpointValidationError {
            let msg = "Güvenlik engeli (SSRF/HTTPS): \(endpointErr)"
            lastAssistantResponse = msg
            speechController.speakInApp(msg, source: source)
            return msg
        } catch {
            let msg = "İstek işlenemedi: \(error.localizedDescription)"
            lastAssistantResponse = msg
            return msg
        }
    }

    private func presentTurnOutcome(
        _ outcome: ModelTurnOutcome,
        modelLabel: String,
        taskId: UUID,
        source: TaskSource,
        rawUtterance: String,
        now: Date
    ) async -> String {
        switch outcome {
        case .answer(let text):
            let audited = JarvisConstitutionalGuard.auditResponseClaims(
                candidateText: text,
                receipts: [],
                language: speechController.selectedLanguage
            )
            lastAssistantResponse = audited.sanitizedText
            speechController.speakInApp(audited.sanitizedText, source: source)
            return audited.sanitizedText
        case .unsupported(let reason):
            lastAssistantResponse = reason
            speechController.speakInApp(reason, source: source)
            return reason
        case .clarification(let question, _):
            let task = AgentTask(
                id: taskId,
                source: source,
                locale: speechController.selectedLanguage.rawValue,
                selectedModelPath: modelLabel,
                state: .awaitingClarification(question),
                createdAt: now,
                rawUtterance: rawUtterance
            )
            let emptyPlan = PlanRevision(revisionNumber: 1, taskId: taskId, steps: [], approvalDigest: "", createdAt: now)
            activePlanState = ActivePlanPresentation(
                task: task,
                revision: emptyPlan,
                modelPathLabel: modelLabel,
                clarificationQuestion: question
            )
            lastAssistantResponse = question
            speechController.speakInApp(question, source: source)
            return question
        case .proposedPlan(let rawSteps):
            do {
                let revision = try PlanValidator.validateAndBuildRevision(
                    taskId: taskId,
                    revisionNumber: 1,
                    rawSteps: rawSteps,
                    now: now
                )
                let task = AgentTask(
                    id: taskId,
                    source: source,
                    locale: speechController.selectedLanguage.rawValue,
                    selectedModelPath: modelLabel,
                    state: .awaitingConfirmation,
                    createdAt: now,
                    rawUtterance: rawUtterance
                )
                var presentation = ActivePlanPresentation(task: task, revision: revision, modelPathLabel: modelLabel)
                await evaluatePlanIntelligence(for: &presentation)
                activePlanState = presentation

                if presentation.swarmReport?.hasSecurityVeto == true {
                    let vetoMsg = "Güvenlik vetosu: \(presentation.swarmReport?.securityVetoReason ?? "Plan güvenlik ilkesi nedeniyle kilitlendi.")"
                    lastAssistantResponse = vetoMsg
                    speechController.speakInApp(vetoMsg, source: source)
                    return vetoMsg
                }

                let summary = "\(revision.steps.count) adımlı plan hazır; onayını bekliyor."
                lastAssistantResponse = summary
                speechController.speakInApp(summary, source: source)
                return summary
            } catch {
                let msg = "Plan doğrulanamadı: \(error)"
                lastAssistantResponse = msg
                return msg
            }
        }
    }

    private func evaluatePlanIntelligence(for presentation: inout ActivePlanPresentation) async {
        let targetDate = presentation.revision.steps
            .compactMap { $0.parameters.startISO8601 ?? $0.parameters.dueISO8601 }
            .compactMap(PlanValidator.parseISO8601)
            .first ?? presentation.task.createdAt

        let calOutcome = await calendarExecutor.querySchedule(
            for: targetDate,
            timeZone: .current,
            isDeviceLocked: isDeviceLocked
        )
        var existingEvents: [CalendarSlotSnapshot] = []
        var isWriteOnlyCalendar = false
        switch calOutcome {
        case .events(let records):
            existingEvents = records.map {
                CalendarSlotSnapshot(id: $0.id, title: $0.title, startDate: $0.startDate, endDate: $0.endDate, location: $0.location)
            }
        case .writeOnlyCannotReadSchedule:
            isWriteOnlyCalendar = true
        default:
            break
        }

        var estimatedTravelMinutes: Int?
        if let dest = presentation.revision.steps.compactMap(\.parameters.destinationQuery).first, !dest.isEmpty {
            estimatedTravelMinutes = await mapsExecutor.estimateTravelMinutes(destinationQuery: dest, mode: .driving)
        }

        let reflection = await reflectionEngine.analyze(
            revision: presentation.revision,
            task: presentation.task,
            existingEvents: existingEvents,
            estimatedTravelMinutes: estimatedTravelMinutes,
            isDeviceLocked: isDeviceLocked,
            isWriteOnlyCalendar: isWriteOnlyCalendar
        )
        let memoryHits = memoryVault.recall(
            query: presentation.task.rawUtterance,
            limit: 5,
            includeSensitivePersonal: true
        )
        let swarm = await specialistSwarm.evaluate(
            task: presentation.task,
            revision: presentation.revision,
            reflection: reflection,
            memoryHits: memoryHits,
            isDeviceLocked: isDeviceLocked
        )
        presentation.reflectionReport = reflection
        presentation.swarmReport = swarm
        if swarm.hasSecurityVeto {
            presentation.task.state = .finished(.refused(swarm.securityVetoReason ?? "Güvenlik vetosu"))
        } else {
            presentation.task.state = .awaitingConfirmation
        }
    }

    private func refreshActivePlanIntelligence() async {
        guard var current = activePlanState else { return }
        await evaluatePlanIntelligence(for: &current)
        activePlanState = current
    }

    public func editActivePlanRemoveSecondStep() {
        guard var current = activePlanState, current.revision.steps.count >= 2 else { return }
        let secondId = current.revision.steps[1].id
        if let updated = try? executionCoordinator.removeStep(stepId: secondId, from: &current.revision) {
            current.revision = updated
            current.task.currentRevisionNumber = updated.revisionNumber
            activePlanState = current
            Task { await refreshActivePlanIntelligence() }
        }
    }

    public func shiftActivePlanStepTime(stepId: String, minutes: Int) {
        guard var current = activePlanState else { return }
        if let updated = try? executionCoordinator.shiftStepTime(stepId: stepId, minutes: minutes, from: &current.revision) {
            current.revision = updated
            current.task.currentRevisionNumber = updated.revisionNumber
            activePlanState = current
            Task { await refreshActivePlanIntelligence() }
        }
    }

    public func cancelActivePlan() {
        guard var current = activePlanState else { return }
        current.task.state = .finished(.cancelled)
        recordTaskHistory(task: current.task, receipts: [])
        activePlanState = nil
        lastAssistantResponse = "Plan iptal edildi."
    }

    public func selectContactCandidate(_ candidate: ContactCandidate) {
        guard var current = activePlanState else { return }
        let updatedRevision = CanonicalApprovalDigest.rebuildRevisionWithUpdatedSteps(
            from: &current.revision,
            transform: { steps in
                steps.map { step in
                    var copy = step
                    if copy.action == .mailCompose {
                        copy.parameters.resolvedRecipientHandle = candidate.emailAddresses.first ?? candidate.phoneNumbers.first
                    } else if [.messagesCompose, .phoneCall].contains(copy.action) {
                        copy.parameters.resolvedRecipientHandle = candidate.phoneNumbers.first ?? candidate.emailAddresses.first
                    }
                    return copy
                }
            },
            now: Date()
        )
        current.revision = updatedRevision
        current.task.currentRevisionNumber = updatedRevision.revisionNumber
        current.disambiguationCandidates = []
        activePlanState = current
        Task { await refreshActivePlanIntelligence() }
    }

    public func confirmAndExecuteActivePlan() async {
        guard var current = activePlanState else { return }
        if current.swarmReport?.hasSecurityVeto == true {
            let vetoReason = current.swarmReport?.securityVetoReason ?? "Güvenlik vetosu nedeniyle plan yürütülemez."
            lastAssistantResponse = vetoReason
            return
        }

        isExecutingPlan = true
        defer { isExecutingPlan = false }

        for step in current.revision.steps {
            let bioResult = await biometricExecutor.authorizeStepIfNeeded(
                step: step,
                revision: current.revision,
                reason: "Yüksek riskli işlem onayı"
            )
            if bioResult.required && !bioResult.granted {
                let bioReason = bioResult.failureReason ?? "Biyometrik doğrulama gerekli."
                lastAssistantResponse = bioReason
                speechController.speakInApp(bioReason, source: current.task.source)
                return
            }
        }

        let bridgeExecutor = CoordinatorStepBridge(
            noteStore: noteStore,
            calendarExecutor: calendarExecutor,
            remindersExecutor: remindersExecutor,
            communicationExecutor: communicationExecutor,
            mapsExecutor: mapsExecutor,
            memoryVault: memoryVault,
            auditTrail: auditTrail,
            artifactVault: artifactVault,
            briefingSynthesizer: briefingSynthesizer,
            alarmExecutor: alarmExecutor,
            shortcutsBridge: shortcutsBridge,
            language: speechController.selectedLanguage,
            isDrivingSafetyActive: isDrivingSafetyActive,
            isDeviceLocked: isDeviceLocked
        )

        do {
            let grant = try executionCoordinator.issueGrant(
                for: current.revision,
                targetSummary: current.task.rawUtterance
            )
            let receipts = try await executionCoordinator.execute(
                task: &current.task,
                revision: &current.revision,
                grant: grant,
                executor: bridgeExecutor
            )
            current.isFinished = true
            activePlanState = current
            recordTaskHistory(task: current.task, receipts: receipts)
            refreshNotesAndInbox()
            await refreshArtifacts()

            let rawSummary = receipts.map(\.spokenVerbTR).joined(separator: ". ")
            let audited = JarvisConstitutionalGuard.auditResponseClaims(
                candidateText: rawSummary,
                receipts: receipts,
                language: speechController.selectedLanguage
            )
            let finalText = audited.sanitizedText.isEmpty ? "Plan tamamlandı." : audited.sanitizedText
            lastAssistantResponse = finalText
            speechController.speakInApp(finalText, source: current.task.source)
        } catch {
            lastAssistantResponse = "Yürütme hatası: \(error.localizedDescription)"
        }
    }

    @discardableResult
    public func runMorningBriefing(source: TaskSource = .inAppText) async -> String {
        let now = Date()
        let report = await briefingSynthesizer.composeBriefing(
            for: now,
            timeZone: .current,
            isDeviceLocked: isDeviceLocked,
            language: speechController.selectedLanguage,
            calendarExecutor: calendarExecutor,
            remindersExecutor: remindersExecutor,
            mapsExecutor: mapsExecutor
        )
        let title = speechController.selectedLanguage == .azerbaijani ? "Gündəlik Brifinq" : "Sabah Brifingi"
        let artifact = try? await artifactVault.createOrUpdate(
            kind: .dailyBriefing,
            title: title,
            markdownBody: report.markdownSummary,
            now: now
        )
        await refreshArtifacts()

        let spokenOutput = isDrivingSafetyActive
            ? CarPlayBriefingComposer().composeDrivingBriefing(from: report, language: speechController.selectedLanguage)
            : report.spokenSummary

        let outcome: ReceiptOutcome = report.calendarPermissionBlockedReason == nil ? .succeeded : .failed
        let receipt = ActionReceipt(
            taskId: UUID(),
            revisionNumber: 1,
            stepId: "briefing-1",
            executorName: "BriefingSynthesizer",
            outcome: outcome,
            externalObjectId: artifact?.id.uuidString,
            timestamp: now,
            canUndo: false,
            spokenVerbTR: spokenOutput,
            spokenVerbAZ: spokenOutput,
            detail: report.markdownSummary
        )
        _ = try? auditTrail.record(receipt: receipt)
        isAuditTrailVerified = auditTrail.verifyIntegrity()
        lastAssistantResponse = spokenOutput
        speechController.speakInApp(spokenOutput, source: source)
        return spokenOutput
    }

    @discardableResult
    public func rememberUserPreference(
        key: String,
        value: String,
        tier: MemoryPrivacyTier = .standardLocal
    ) -> Result<MemoryEntry, MemoryVaultError> {
        do {
            let entry = try memoryVault.remember(
                key: key,
                value: value,
                tags: ["tercih"],
                privacyTier: tier,
                rawUtterance: "\(key): \(value)",
                sourceTaskId: UUID(),
                sourceChannel: "settings",
                now: Date()
            )
            memoryEntries = memoryVault.activeEntries()
            return .success(entry)
        } catch let error as MemoryVaultError {
            return .failure(error)
        } catch {
            return .failure(.emptyKeyOrValue)
        }
    }

    public func forgetMemory(id: UUID) {
        _ = try? memoryVault.forget(id: id, now: Date())
        memoryEntries = memoryVault.activeEntries()
    }

    @discardableResult
    public func verifyAuditTrailIntegrity() -> Bool {
        let verified = auditTrail.verifyIntegrity()
        isAuditTrailVerified = verified
        return verified
    }

    public func summarizePendingShareItem(_ item: SharedInboxItem) async {
        let envelope = UntrustedInputEnvelope(sourceLabel: item.sourceAppHint, rawText: item.text)
        let sanitizedSource = PromptInjectionSanitizer.sanitize(item.text)
        let proposed = [
            RawModelStepInput(
                id: "sum1",
                action: ActionKind.textSummarizeAndNote.rawValue,
                parameters: ActionParameters(
                    noteContent: "Özet (\(item.sourceAppHint)): \(String(sanitizedSource.prefix(160)))",
                    untrustedSourceText: item.text
                )
            )
        ]
        if let verifiedSteps = try? UntrustedContentPolicy.enforceSummarizeOnlyPlan(untrusted: envelope, proposedSteps: proposed),
           let firstContent = verifiedSteps.first?.parameters.noteContent,
           let note = try? noteStore.createNote(content: firstContent, sourceTaskId: UUID(), now: Date()) {
            try? sharedInbox.markConsumed(id: item.id)
            let receipt = ActionReceipt(
                taskId: UUID(),
                revisionNumber: 1,
                stepId: "share-sum",
                executorName: "FileBackedNoteStore",
                outcome: .succeeded,
                externalObjectId: note.id.uuidString,
                timestamp: Date(),
                canUndo: true,
                spokenVerbTR: "Paylaşılan içerik özetlenip not alındı",
                spokenVerbAZ: "Paylaşılan məzmun xülasə edilərək qeyd olundu",
                detail: note.content
            )
            _ = try? auditTrail.record(receipt: receipt)
            refreshNotesAndInbox()
            lastAssistantResponse = "Paylaşılan içerik özetlenip not olarak kaydedildi."
        }
    }

    public func configureAndTestExternalProvider(endpointString: String, modelID: String, apiKey: String) async -> String {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            return "API anahtarı boş bırakılamaz."
        }
        guard let url = URL(string: endpointString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host else {
            return "Geçerli bir HTTPS adresi girin."
        }
        do {
            try StrictEndpointValidator.validateHTTPS(url: url)
            try keyStore.saveKey(cleanKey, forHost: host)
            let profile = ExternalProviderProfile.customHTTPS(displayName: "Özel Sağlayıcı (\(host))", endpointURL: url, modelID: modelID)
            let provider = ExternalChatCompletionsProvider(
                profile: profile,
                keyStore: keyStore,
                transport: PinnedURLSessionHTTPTransport()
            )
            let consentKey = ProviderConsentKey(providerID: profile.providerID, endpointHost: host)
            consentManager.switchProvider(to: consentKey)
            consentManager.grantConsent(for: consentKey, scopes: [.commandTextOnly])

            let ok = try await provider.verifyConnectionWithoutPersonalData()
            if ok {
                customExternalProvider = provider
                customExternalProfile = profile
                await refreshModelAvailability()
                return "Bağlantı doğrulandı (kişisel veri gönderilmedi)."
            } else {
                consentManager.revokeConsent()
                try? keyStore.deleteKey(forHost: host)
                return "Bağlantı doğrulanamadı."
            }
        } catch let endpointError as EndpointValidationError {
            consentManager.revokeConsent()
            try? keyStore.deleteKey(forHost: host)
            return "Güvenlik engeli (SSRF/HTTPS): \(endpointError)"
        } catch {
            consentManager.revokeConsent()
            try? keyStore.deleteKey(forHost: host)
            return "Sağlayıcı sınaması başarısız: \(error)"
        }
    }

    public func revokeExternalConsentAndDeleteKey(endpointString: String) {
        consentManager.revokeConsent()
        if let host = URL(string: endpointString)?.host {
            try? keyStore.deleteKey(forHost: host)
        }
        customExternalProvider = nil
        customExternalProfile = nil
        Task { await refreshModelAvailability() }
    }

    public func bindShortcut(label: String, shortcutName: String) {
        let binding = ShortcutBinding(userLabel: label, shortcutName: shortcutName)
        shortcutsBridge.registerBinding(binding)
    }

    public func clearTaskHistoryPreservingNotes() {
        taskHistory.removeAll()
        Task {
            await artifactVault.clearPreservingArtifacts()
            await refreshArtifacts()
        }
    }

    public func undoNote(id: UUID) {
        _ = try? noteStore.undoCreate(noteId: id, now: Date())
        refreshNotesAndInbox()
    }

    public func handleIncomingURL(_ url: URL) {
        guard url.scheme == "iagent" else { return }
        if url.host == "share-inbox" {
            refreshNotesAndInbox()
        } else if url.host == "shortcut-callback" {
            if let receipt = try? shortcutsBridge.handleCallbackURL(url, now: Date()) {
                _ = try? auditTrail.record(receipt: receipt)
                isAuditTrailVerified = auditTrail.verifyIntegrity()
                lastAssistantResponse = receipt.spokenVerbTR
            }
        }
    }

    private func recordTaskHistory(task: AgentTask, receipts: [ActionReceipt]) {
        guard historyRetention != .doNotKeep else { return }
        taskHistory.insert(TaskHistoryEntry(task: task, receipts: receipts), at: 0)
    }

    private func friendlyModelErrorMessage(_ err: ModelProviderError) -> String {
        switch err {
        case .consentRequired:
            return "Dış sağlayıcıya veri göndermek için Ayarlar'dan onay vermelisiniz."
        case .safetyRefusal(let msg):
            return "Model güvenlik nedeniyle yanıt vermedi: \(msg)"
        case .invalidAPIKey:
            return "Harici sağlayıcı API anahtarı geçersiz veya yetkisiz."
        case .insufficientBalance:
            return "Harici sağlayıcı bakiyesi yetersiz."
        case .rateLimited:
            return "Harici sağlayıcı hız sınırına ulaşıldı; kısa süre sonra yeniden deneyin."
        case .truncatedOrMalformedJSON:
            return "Model yanıtı yarım kaldığı veya bozuk olduğu için hiçbir işlem uygulanmadı."
        case .providerUnavailable(let reason):
            return reason.userFacingReasonTR
        default:
            return "Model yanıtı üretilemedi (\(err))."
        }
    }
}

private struct CoordinatorStepBridge: StepExecutorProtocol {
    let noteStore: FileBackedNoteStore
    let calendarExecutor: CalendarActionExecutor
    let remindersExecutor: RemindersActionExecutor
    let communicationExecutor: CommunicationActionExecutor
    let mapsExecutor: MapsActionExecutor
    let memoryVault: FileBackedMemoryVault
    let auditTrail: CryptographicAuditTrail
    let artifactVault: JarvisArtifactVault
    let briefingSynthesizer: BriefingSynthesizer
    let alarmExecutor: AlarmActionExecutor
    let shortcutsBridge: ShortcutsBridgeExecutor
    let language: AgentLanguage
    let isDrivingSafetyActive: Bool
    let isDeviceLocked: Bool

    func execute(step: ActionStep, task: AgentTask, revisionNumber: Int, now: Date) async throws -> ActionReceipt {
        let receipt = try await executeRaw(step: step, task: task, revisionNumber: revisionNumber, now: now)
        _ = try? auditTrail.record(receipt: receipt)
        return receipt
    }

    private func executeRaw(step: ActionStep, task: AgentTask, revisionNumber: Int, now: Date) async throws -> ActionReceipt {
        if case .deferredForDrivingSafety(let reasonTR) = DrivingSafetyPolicy.evaluate(
            action: step.action,
            isDrivingOrCarPlay: isDrivingSafetyActive
        ) {
            return ActionReceipt(
                taskId: task.id,
                revisionNumber: revisionNumber,
                stepId: step.id,
                executorName: "DrivingSafetyPolicy",
                outcome: .cancelled,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Sürüş güvenliği nedeniyle ertelendi",
                spokenVerbAZ: "Sürücülük təhlükəsizliyi səbəbilə təxirə salındı",
                detail: reasonTR
            )
        }

        switch step.action {
        case .notesCreate, .textSummarizeAndNote:
            let note = try noteStore.createNote(content: step.parameters.noteContent ?? "", sourceTaskId: task.id, now: now)
            return ActionReceipt(
                taskId: task.id,
                revisionNumber: revisionNumber,
                stepId: step.id,
                executorName: "FileBackedNoteStore",
                outcome: .succeeded,
                externalObjectId: note.id.uuidString,
                timestamp: now,
                canUndo: true,
                spokenVerbTR: "Not kaydedildi",
                spokenVerbAZ: "Qeyd saxlandı",
                detail: note.content
            )

        case .notesSearch:
            let matches = try noteStore.searchNotes(query: step.parameters.query ?? "")
            let preview = matches.first?.content ?? "Eşleşme yok"
            return ActionReceipt(
                taskId: task.id,
                revisionNumber: revisionNumber,
                stepId: step.id,
                executorName: "FileBackedNoteStore",
                outcome: .succeeded,
                externalObjectId: matches.first?.id.uuidString,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: matches.isEmpty ? "Eşleşen not bulunamadı" : "\(matches.count) not bulundu",
                spokenVerbAZ: matches.isEmpty ? "Uyğun qeyd tapılmadı" : "\(matches.count) qeyd tapıldı",
                detail: preview
            )

        case .calendarRead:
            let targetDate = PlanValidator.parseISO8601(step.parameters.startISO8601 ?? "") ?? now
            let res = await calendarExecutor.querySchedule(for: targetDate, timeZone: .current, isDeviceLocked: isDeviceLocked)
            switch res {
            case .events(let events):
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "EventKit.Calendar",
                    outcome: .succeeded,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "\(events.count) takvim etkinliği bulundu",
                    spokenVerbAZ: "\(events.count) təqvim tədbiri tapıldı",
                    detail: events.map(\.title).joined(separator: ", ")
                )
            case .emptySchedule:
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "EventKit.Calendar",
                    outcome: .succeeded,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "Bugün takvimde etkinlik yok",
                    spokenVerbAZ: "Bu gün təqvimdə tədbir yoxdur",
                    detail: "Boş ajanda"
                )
            case .writeOnlyCannotReadSchedule:
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "EventKit.Calendar",
                    outcome: .failed,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "Takvim izni yalnızca yazma düzeyinde",
                    spokenVerbAZ: "Təqvim icazəsi yalnız yazma səviyyəsindədir",
                    detail: ".writeOnly izni ile ajanda okunamaz."
                )
            case .permissionDenied:
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "EventKit.Calendar",
                    outcome: .failed,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "Takvim okuma izni gerekli",
                    spokenVerbAZ: "Təqvim oxuma icazəsi lazımdır",
                    detail: "Takvim okuma izni verilmedi."
                )
            case .deviceLockedRequiresAuthentication:
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "EventKit.Calendar",
                    outcome: .failed,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "Cihaz kilidi açılmalı",
                    spokenVerbAZ: "Cihaz kilidi açılmalıdır",
                    detail: "Cihaz kilitliyken takvim okunamaz."
                )
            case .readError(let message):
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "EventKit.Calendar",
                    outcome: .failed,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "Takvim okunamadı",
                    spokenVerbAZ: "Təqvim oxuna bilmədi",
                    detail: message
                )
            }

        case .calendarCreate:
            let start = PlanValidator.parseISO8601(step.parameters.startISO8601 ?? "") ?? now
            let res = await calendarExecutor.createEvent(
                title: step.parameters.title ?? "Etkinlik",
                startDate: start,
                durationMinutes: step.parameters.durationMinutes ?? 30
            )
            switch res {
            case .saved(let id, let title, _, _, _):
                return ActionReceipt(taskId: task.id, revisionNumber: revisionNumber, stepId: step.id, executorName: "EventKit.Calendar", outcome: .succeeded, externalObjectId: id, timestamp: now, canUndo: true, spokenVerbTR: "Takvim kaydı eklendi", spokenVerbAZ: "Təqvim qeydi əlavə edildi", detail: title)
            default:
                return ActionReceipt(taskId: task.id, revisionNumber: revisionNumber, stepId: step.id, executorName: "EventKit.Calendar", outcome: .failed, timestamp: now, canUndo: false, spokenVerbTR: "Takvim izni gerekli", spokenVerbAZ: "Təqvim icazəsi lazımdır", detail: "Kayıt eklenemedi")
            }

        case .remindersCreate:
            let due = PlanValidator.parseISO8601(step.parameters.dueISO8601 ?? "") ?? now
            let res = await remindersExecutor.createReminder(title: step.parameters.title ?? "Hatırlatma", dueDate: due, timeZone: .current)
            switch res {
            case .saved(let rec):
                return ActionReceipt(taskId: task.id, revisionNumber: revisionNumber, stepId: step.id, executorName: "EventKit.Reminders", outcome: .succeeded, externalObjectId: rec.id, timestamp: now, canUndo: true, spokenVerbTR: "Anımsatıcı kuruldu", spokenVerbAZ: "Xatırlatma quruldu", detail: rec.title)
            default:
                return ActionReceipt(taskId: task.id, revisionNumber: revisionNumber, stepId: step.id, executorName: "EventKit.Reminders", outcome: .failed, timestamp: now, canUndo: false, spokenVerbTR: "Anımsatıcı izni gerekli", spokenVerbAZ: "Xatırlatma icazəsi lazımdır", detail: "Anımsatıcı kaydedilemedi")
            }

        case .remindersRead:
            let auth = await remindersExecutor.authorizationState()
            guard auth == .fullAccess else {
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "EventKit.Reminders",
                    outcome: .failed,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "Anımsatıcı okuma izni gerekli",
                    spokenVerbAZ: "Xatırlatma oxuma icazəsi lazımdır",
                    detail: "Anımsatıcı erişimi verilmedi."
                )
            }
            let items = await remindersExecutor.fetchOpenReminders(isDeviceLocked: isDeviceLocked)
            return ActionReceipt(
                taskId: task.id,
                revisionNumber: revisionNumber,
                stepId: step.id,
                executorName: "EventKit.Reminders",
                outcome: .succeeded,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: items.isEmpty ? "Açık anımsatıcı yok" : "\(items.count) açık anımsatıcı bulundu",
                spokenVerbAZ: items.isEmpty ? "Açıq xatırlatma yoxdur" : "\(items.count) açıq xatırlatma tapıldı",
                detail: items.map(\.title).joined(separator: ", ")
            )

        case .messagesCompose:
            return await communicationExecutor.composeSMS(
                taskId: task.id,
                revisionNumber: revisionNumber,
                stepId: step.id,
                recipientHandle: step.parameters.resolvedRecipientHandle ?? step.parameters.recipientQuery ?? "",
                body: step.parameters.body ?? "",
                now: now
            )

        case .mailCompose:
            return await communicationExecutor.composeMail(
                taskId: task.id,
                revisionNumber: revisionNumber,
                stepId: step.id,
                recipientEmail: step.parameters.resolvedRecipientHandle ?? step.parameters.recipientQuery ?? "",
                subject: step.parameters.subject ?? "iAgent",
                body: step.parameters.body ?? "",
                now: now
            )

        case .shareSheet:
            let shareBody = step.parameters.body ?? step.parameters.noteContent ?? ""
            let res = await communicationExecutor.shareToApp(text: shareBody, preferredAppScheme: step.parameters.urlString)
            switch res {
            case .shareSheetPresented(let text, _):
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "UIActivityViewController",
                    outcome: .handedOffToUserInterface,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "Paylaşım sayfası açıldı",
                    spokenVerbAZ: "Paylaşım pəncərəsi açıldı",
                    detail: text
                )
            case .targetAppNotInstalledOfferStandardShare(let appName, _):
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "UIActivityViewController",
                    outcome: .failed,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "\(appName) yüklü değil",
                    spokenVerbAZ: "\(appName) quraşdırılmayıb",
                    detail: "Hedef uygulama yüklü olmadığı için standart paylaşım önerildi."
                )
            default:
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "UIActivityViewController",
                    outcome: .failed,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "Paylaşım başlatılamadı",
                    spokenVerbAZ: "Paylaşım başladılmadı",
                    detail: "Paylaşım hedefi geçersiz."
                )
            }

        case .phoneCall:
            let target = step.parameters.resolvedRecipientHandle ?? step.parameters.recipientQuery ?? ""
            let res = await communicationExecutor.handoffPhoneCall(phoneNumber: target)
            switch res {
            case .callConfirmationPresented(let phoneNumber):
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "SystemDialer",
                    outcome: .handedOffToUserInterface,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "Arama onayı açıldı",
                    spokenVerbAZ: "Zəng təsdiqi açıldı",
                    detail: phoneNumber
                )
            default:
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "SystemDialer",
                    outcome: .failed,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "Geçerli telefon numarası seçilmedi",
                    spokenVerbAZ: "Düzgün telefon nömrəsi seçilmədi",
                    detail: target
                )
            }

        case .mapsDirections:
            let query = step.parameters.destinationQuery ?? ""
            let mode = MapsTransportMode(rawValue: step.parameters.transportMode ?? "transit") ?? .transit
            let res = await mapsExecutor.openDirections(query: query, transportMode: mode)
            switch res {
            case .handedOffToMaps(let dest, let usedMode):
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "MapKit",
                    outcome: .handedOffToUserInterface,
                    externalObjectId: dest.id,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "Haritalar’a aktarıldı",
                    spokenVerbAZ: "Xəritəyə ötürüldü",
                    detail: "\(dest.name) (\(usedMode.rawValue))"
                )
            case .disambiguationRequired(let q, let candidates):
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "MapKit",
                    outcome: .failed,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "Konum seçimi gerekli",
                    spokenVerbAZ: "Məkan seçimi tələb olunur",
                    detail: "\(q) için \(candidates.count) aday bulundu."
                )
            case .notFound(let q):
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "MapKit",
                    outcome: .failed,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "Konum bulunamadı",
                    spokenVerbAZ: "Məkan tapılmadı",
                    detail: q
                )
            }

        case .mapsEstimateETA:
            let query = step.parameters.destinationQuery ?? ""
            let mode = MapsTransportMode(rawValue: step.parameters.transportMode ?? "driving") ?? .driving
            if let eta = await mapsExecutor.estimateTravelMinutes(destinationQuery: query, mode: mode) {
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "MapKit.ETA",
                    outcome: .succeeded,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "Tahmini ulaşım \(eta) dakika",
                    spokenVerbAZ: "Təxmini yol \(eta) dəqiqə",
                    detail: "\(query): \(eta) dk (\(mode.rawValue))"
                )
            }
            return ActionReceipt(
                taskId: task.id,
                revisionNumber: revisionNumber,
                stepId: step.id,
                executorName: "MapKit.ETA",
                outcome: .failed,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Ulaşım süresi hesaplanamadı",
                spokenVerbAZ: "Yol vaxtı hesablana bilmədi",
                detail: query
            )

        case .shortcutsRun:
            let label = step.parameters.shortcutLabel ?? ""
            do {
                let launchPlan = try shortcutsBridge.prepareLaunch(
                    label: label,
                    input: step.parameters.shortcutInput,
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id
                )
                if let failureReceipt = await shortcutsBridge.launch(launchPlan, now: now) {
                    return failureReceipt
                }
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "ShortcutsBridge",
                    outcome: .handedOffToUserInterface,
                    externalObjectId: launchPlan.callbackToken,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "Kestirme başlatıldı; dönüş bekleniyor",
                    spokenVerbAZ: "Qısayol başladıldı; cavab gözlənilir",
                    detail: launchPlan.binding.shortcutName
                )
            } catch {
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "ShortcutsBridge",
                    outcome: .failed,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "Kestirme başlatılamadı",
                    spokenVerbAZ: "Qısayol işə salına bilmədi",
                    detail: "\(error)"
                )
            }

        case .assistantReply:
            let reply = step.parameters.body ?? step.parameters.noteContent ?? ""
            return ActionReceipt(
                taskId: task.id,
                revisionNumber: revisionNumber,
                stepId: step.id,
                executorName: "AssistantReply",
                outcome: .succeeded,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: reply.isEmpty ? "Yanıt hazır" : reply,
                spokenVerbAZ: reply.isEmpty ? "Cavab hazırdır" : reply,
                detail: reply
            )

        case .briefingCompose:
            let report = await briefingSynthesizer.composeBriefing(
                for: now,
                timeZone: .current,
                isDeviceLocked: isDeviceLocked,
                language: language,
                calendarExecutor: calendarExecutor,
                remindersExecutor: remindersExecutor,
                mapsExecutor: mapsExecutor
            )
            let artifact = try? await artifactVault.createOrUpdate(
                kind: .dailyBriefing,
                title: step.parameters.title ?? "Günlük Brifing",
                markdownBody: report.markdownSummary,
                now: now
            )
            let outcome: ReceiptOutcome = report.calendarPermissionBlockedReason == nil ? .succeeded : .failed
            return ActionReceipt(
                taskId: task.id,
                revisionNumber: revisionNumber,
                stepId: step.id,
                executorName: "BriefingSynthesizer",
                outcome: outcome,
                externalObjectId: artifact?.id.uuidString,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: report.spokenSummary,
                spokenVerbAZ: report.spokenSummary,
                detail: report.markdownSummary
            )

        case .memoryRemember:
            let key = (step.parameters.title ?? "Tercih").trimmingCharacters(in: .whitespacesAndNewlines)
            let value = (step.parameters.noteContent ?? step.parameters.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let entry = try memoryVault.remember(
                    key: key.isEmpty ? "Tercih" : key,
                    value: value,
                    tags: ["tercih"],
                    privacyTier: .standardLocal,
                    rawUtterance: task.rawUtterance,
                    sourceTaskId: task.id,
                    sourceChannel: task.source.rawValue,
                    now: now
                )
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "FileBackedMemoryVault",
                    outcome: .succeeded,
                    externalObjectId: entry.id.uuidString,
                    timestamp: now,
                    canUndo: true,
                    spokenVerbTR: "Tercih hafızaya kaydedildi",
                    spokenVerbAZ: "Seçim yaddaşa saxlandı",
                    detail: "\(entry.key): \(entry.value)"
                )
            } catch {
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "FileBackedMemoryVault",
                    outcome: .failed,
                    timestamp: now,
                    canUndo: false,
                    spokenVerbTR: "Hafıza kaydı güvenlik politikası nedeniyle reddedildi",
                    spokenVerbAZ: "Yaddaş qeydi təhlükəsizlik qaydasına görə rədd edildi",
                    detail: "\(error)"
                )
            }

        case .memoryRecall:
            let query = step.parameters.query ?? step.parameters.noteContent ?? ""
            let hits = memoryVault.recall(query: query, limit: 5, includeSensitivePersonal: true)
            let details = hits.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            return ActionReceipt(
                taskId: task.id,
                revisionNumber: revisionNumber,
                stepId: step.id,
                executorName: "FileBackedMemoryVault",
                outcome: .succeeded,
                externalObjectId: hits.first?.id.uuidString,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: hits.isEmpty ? "Hafızada eşleşen kayıt yok" : "\(hits.count) hafıza kaydı bulundu: \(hits[0].value)",
                spokenVerbAZ: hits.isEmpty ? "Yaddaşda uyğun qeyd yoxdur" : "\(hits.count) yaddaş qeydi tapıldı: \(hits[0].value)",
                detail: details.isEmpty ? "Eşleşme yok" : details
            )

        case .memoryForget:
            let rawQuery = (step.parameters.query ?? step.parameters.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let uuid = UUID(uuidString: rawQuery),
               let forgotten = try? memoryVault.forget(id: uuid, now: now) {
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "FileBackedMemoryVault",
                    outcome: .succeeded,
                    externalObjectId: forgotten.id.uuidString,
                    timestamp: now,
                    canUndo: true,
                    spokenVerbTR: "Hafıza kaydı unutuldu",
                    spokenVerbAZ: "Yaddaş qeydi silindi",
                    detail: forgotten.key
                )
            }
            if let match = memoryVault.recall(query: rawQuery, limit: 1, includeSensitivePersonal: true).first,
               let forgotten = try? memoryVault.forget(id: match.id, now: now) {
                return ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    executorName: "FileBackedMemoryVault",
                    outcome: .succeeded,
                    externalObjectId: forgotten.id.uuidString,
                    timestamp: now,
                    canUndo: true,
                    spokenVerbTR: "Hafıza kaydı unutuldu",
                    spokenVerbAZ: "Yaddaş qeydi silindi",
                    detail: forgotten.key
                )
            }
            return ActionReceipt(
                taskId: task.id,
                revisionNumber: revisionNumber,
                stepId: step.id,
                executorName: "FileBackedMemoryVault",
                outcome: .failed,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Silinecek hafıza kaydı bulunamadı",
                spokenVerbAZ: "Silinəcək yaddaş qeydi tapılmadı",
                detail: rawQuery
            )

        case .alarmCreate:
            let fireDate = PlanValidator.parseISO8601(step.parameters.dueISO8601 ?? step.parameters.startISO8601 ?? "") ?? now.addingTimeInterval(60)
            let title = step.parameters.title ?? "iAgent Alarm"
            return await alarmExecutor.scheduleAlarm(
                taskId: task.id,
                revisionNumber: revisionNumber,
                stepId: step.id,
                title: title,
                fireDate: fireDate,
                now: now
            )
        }
    }
}

@main
struct iAgentApp: App {
    @State private var coordinator = AppCoordinator.shared
    @State private var selectedTab: Int = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if !coordinator.hasCompletedOnboarding {
                    NavigationStack {
                        OnboardingView(
                            coordinator: coordinator,
                            onOpenProviderSettings: {
                                coordinator.hasCompletedOnboarding = true
                                selectedTab = 2
                            },
                            onCompleteOnboarding: {
                                coordinator.hasCompletedOnboarding = true
                            }
                        )
                    }
                } else {
                    TabView(selection: $selectedTab) {
                        NavigationStack {
                            HomeView(coordinator: coordinator, speechController: coordinator.speechController)
                        }
                        .tabItem { Label("Asistan", systemImage: "waveform") }
                        .tag(0)

                        NavigationStack {
                            HistoryView(coordinator: coordinator)
                        }
                        .tabItem { Label("Geçmiş", systemImage: "clock.arrow.circlepath") }
                        .tag(1)

                        NavigationStack {
                            CapabilitiesSettingsView(coordinator: coordinator, speechController: coordinator.speechController)
                        }
                        .tabItem { Label("Ayarlar", systemImage: "slider.horizontal.3") }
                        .tag(2)
                    }
                }
            }
            .onOpenURL { url in
                coordinator.handleIncomingURL(url)
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    coordinator.refreshNotesAndInbox()
                }
            }
        }
    }
}
