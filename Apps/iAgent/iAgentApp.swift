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

    private let appleModelProvider = AppleFoundationModelProvider()
    private var customExternalProvider: ExternalChatCompletionsProvider?
    private let calendarExecutor: CalendarActionExecutor
    private let remindersExecutor: RemindersActionExecutor
    private let contactResolver: ContactResolver
    private let communicationExecutor: CommunicationActionExecutor
    private let mapsExecutor: MapsActionExecutor

    public var notes: [PersistentNote] = []
    public var pendingShareItems: [SharedInboxItem] = []
    public var activePlanState: ActivePlanPresentation?
    public var taskHistory: [TaskHistoryEntry] = []
    public var historyRetention: HistoryRetentionPolicy = .thirtyDays
    public var modelPreference: ModelUserPreference = .automatic
    public var activeModelLabel: String = "Kontrol ediliyor..."
    public var activeModelStatusDescription: String = "Apple Intelligence durumu kontrol ediliyor."
    public var lastAssistantResponse: String?
    public var isExecutingPlan: Bool = false
    public var hasCompletedOnboarding: Bool = false

    public var capabilityStatuses: [CapabilityStatusItem] {
        [
            CapabilityStatusItem(title: "Yerel Notlar", badge: "Hazır", detail: "SwiftData/JSON kalıcı notlar, geri alma destekli"),
            CapabilityStatusItem(title: "Takvim", badge: "İzin gerekli", detail: "Okuma ve yalnız yazma izinleri ayrı istenir"),
            CapabilityStatusItem(title: "Anımsatıcılar", badge: "İzin gerekli", detail: "Zaman bazlı EKAlarm oluşturma"),
            CapabilityStatusItem(title: "Mesaj / E-posta", badge: "Hazır", detail: "Sistem düzenleyicisinde kullanıcı tamamlar"),
            CapabilityStatusItem(title: "Haritalar", badge: "Hazır", detail: "Doğrulanmış hedefi konum izni olmadan açar"),
            CapabilityStatusItem(title: "Kestirmeler", badge: shortcutsBridge.allBindings().isEmpty ? "Kestirme kurulmalı" : "Hazır", detail: "Adlı x-callback-url köprüsü")
        ]
    }

    public init(storageDirectory: URL? = nil) {
        let baseDir = storageDirectory ?? Self.defaultContainerDirectory()
        let notesURL = baseDir.appendingPathComponent("notes.json")
        let walURL = baseDir.appendingPathComponent("wal.json")

        let store = (try? FileBackedNoteStore(fileURL: notesURL))
            ?? (try! FileBackedNoteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("iagent-notes.json")))
        self.noteStore = store
        self.quickNoteFlow = QuickNoteFlow(noteStore: store)

        let journal = try? WriteAheadJournal(fileURL: walURL)
        self.executionCoordinator = ExecutionCoordinator(clock: SystemClock(), journal: journal)
        self.keyStore = KeychainSecretStore()
        self.sharedInbox = SharedInboxManager(inboxDirectory: SharedInboxManager.defaultInboxDirectory())
        self.shortcutsBridge = ShortcutsBridgeExecutor(opener: MockShortcutURLOpener())

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

        refreshNotesAndInbox()
        Task { await refreshModelAvailability() }
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

        let taskId = UUID()
        let now = Date()

        // 1. Önce sabit yerel not akışı denenir (model yokken veya uçak modunda garantili çalışır).
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
                    detail: note.content
                )
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

        // 2. Model yönlendiricisi üzerinden yapılandırılmış plan üretimi.
        let router = ModelRouter(
            onDeviceProvider: appleModelProvider,
            externalProvider: customExternalProvider,
            consentManager: consentManager
        )
        let request = ModelTurnRequest(
            taskId: taskId,
            utterance: trimmed,
            locale: speechController.selectedLanguage == .azerbaijani ? "az_AZ" : "tr_TR",
            referenceDateISO8601: DateAndTimeResolver.formatISO8601(now, timeZone: .current),
            timeZoneIdentifier: TimeZone.current.identifier
        )

        do {
            let (label, turnOutcome) = try await router.routeAndGenerate(request: request, preference: modelPreference)
            return presentTurnOutcome(turnOutcome, modelLabel: label, taskId: taskId, source: source, rawUtterance: trimmed, now: now)
        } catch let err as ModelProviderError {
            let msg = friendlyModelErrorMessage(err)
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
    ) -> String {
        switch outcome {
        case .answer(let text):
            lastAssistantResponse = text
            speechController.speakInApp(text, source: source)
            return text
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
                activePlanState = ActivePlanPresentation(task: task, revision: revision, modelPathLabel: modelLabel)
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

    public func editActivePlanRemoveSecondStep() {
        guard var current = activePlanState, current.revision.steps.count >= 2 else { return }
        let secondId = current.revision.steps[1].id
        if let updated = try? executionCoordinator.removeStep(stepId: secondId, from: &current.revision) {
            current.revision = updated
            current.task.currentRevisionNumber = updated.revisionNumber
            activePlanState = current
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
        let handle = candidate.phoneNumbers.first ?? candidate.emailAddresses.first
        for idx in current.revision.steps.indices {
            if [.messagesCompose, .mailCompose, .phoneCall].contains(current.revision.steps[idx].action) {
                current.revision.steps[idx].parameters.resolvedRecipientHandle = handle
            }
        }
        current.disambiguationCandidates = []
        activePlanState = current
    }

    public func confirmAndExecuteActivePlan() async {
        guard var current = activePlanState else { return }
        isExecutingPlan = true
        defer { isExecutingPlan = false }

        let bridgeExecutor = CoordinatorStepBridge(
            noteStore: noteStore,
            calendarExecutor: calendarExecutor,
            remindersExecutor: remindersExecutor,
            communicationExecutor: communicationExecutor,
            mapsExecutor: mapsExecutor
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
            let summary = receipts.map(\.spokenVerbTR).joined(separator: ". ")
            lastAssistantResponse = summary
            speechController.speakInApp(summary, source: current.task.source)
        } catch {
            lastAssistantResponse = "Yürütme hatası: \(error.localizedDescription)"
        }
    }

    public func summarizePendingShareItem(_ item: SharedInboxItem) async {
        let envelope = UntrustedInputEnvelope(sourceLabel: item.sourceAppHint, rawText: item.text)
        let proposed = [
            RawModelStepInput(
                id: "sum1",
                action: ActionKind.textSummarizeAndNote.rawValue,
                parameters: ActionParameters(
                    noteContent: "Özet (\(item.sourceAppHint)): \(String(item.text.prefix(160)))",
                    untrustedSourceText: item.text
                )
            )
        ]
        if let verifiedSteps = try? UntrustedContentPolicy.enforceSummarizeOnlyPlan(untrusted: envelope, proposedSteps: proposed),
           let firstContent = verifiedSteps.first?.parameters.noteContent {
            _ = try? noteStore.createNote(content: firstContent, sourceTaskId: UUID(), now: Date())
            try? sharedInbox.markConsumed(id: item.id)
            refreshNotesAndInbox()
            lastAssistantResponse = "Paylaşılan içerik özetlenip not olarak kaydedildi."
        }
    }

    public func configureAndTestExternalProvider(endpointString: String, modelID: String, apiKey: String) async -> String {
        guard let url = URL(string: endpointString), url.scheme?.lowercased() == "https", let host = url.host else {
            return "Geçerli bir HTTPS adresi girin."
        }
        do {
            try keyStore.saveKey(apiKey, forHost: host)
            let profile = ExternalProviderProfile.customHTTPS(displayName: "Özel Sağlayıcı (\(host))", endpointURL: url, modelID: modelID)
            let provider = ExternalChatCompletionsProvider(profile: profile, keyStore: keyStore)
            customExternalProvider = provider
            consentManager.switchProvider(to: profile.providerID)
            consentManager.grantConsent(forProviderID: profile.providerID, scopes: [.commandTextOnly])
            let ok = try await provider.verifyConnectionWithoutPersonalData()
            await refreshModelAvailability()
            return ok ? "Bağlantı doğrulandı (kişisel veri gönderilmedi)." : "Bağlantı doğrulanamadı."
        } catch {
            return "Sağlayıcı sınaması başarısız: \(error)"
        }
    }

    public func revokeExternalConsentAndDeleteKey(endpointString: String) {
        consentManager.revokeConsent()
        if let host = URL(string: endpointString)?.host {
            try? keyStore.deleteKey(forHost: host)
        }
        customExternalProvider = nil
        Task { await refreshModelAvailability() }
    }

    public func bindShortcut(label: String, shortcutName: String) {
        let binding = ShortcutBinding(userLabel: label, shortcutName: shortcutName)
        shortcutsBridge.registerBinding(binding)
    }

    public func clearTaskHistoryPreservingNotes() {
        taskHistory.removeAll()
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

    func execute(step: ActionStep, task: AgentTask, revisionNumber: Int, now: Date) async throws -> ActionReceipt {
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
        case .messagesCompose:
            return await communicationExecutor.composeSMS(
                taskId: task.id,
                revisionNumber: revisionNumber,
                stepId: step.id,
                recipientHandle: step.parameters.resolvedRecipientHandle ?? step.parameters.recipientQuery ?? "",
                body: step.parameters.body ?? "",
                now: now
            )
        case .mapsDirections:
            let res = await mapsExecutor.openDirections(query: step.parameters.destinationQuery ?? "")
            return ActionReceipt(taskId: task.id, revisionNumber: revisionNumber, stepId: step.id, executorName: "MapKit", outcome: .handedOffToUserInterface, timestamp: now, canUndo: false, spokenVerbTR: "Haritalar’a aktarıldı", spokenVerbAZ: "Xəritəyə ötürüldü", detail: "\(res)")
        default:
            return ActionReceipt(taskId: task.id, revisionNumber: revisionNumber, stepId: step.id, executorName: "iAgent", outcome: .succeeded, timestamp: now, canUndo: false, spokenVerbTR: "Tamamlandı", spokenVerbAZ: "Tamamlandı", detail: step.action.rawValue)
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
