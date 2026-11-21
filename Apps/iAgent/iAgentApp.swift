import SwiftUI
import Observation
import AgentCore

/// Ana uygulama yaşam döngüsünü, kalıcı not deposunu, Siri devirlerini ve kestirme geri çağrılarını koordine eder.
@MainActor
@Observable
public final class AppCoordinator {
    public static let shared = AppCoordinator()

    public let noteStore: FileBackedNoteStore
    public let quickNoteFlow: QuickNoteFlow

    public var notes: [PersistentNote] = []
    public var lastReceivedUtterance: String?
    public var lastNoteSummary: String?
    public var pendingHandoffTaskID: UUID?
    public var pendingShareInboxCount: Int = 0
    public var statusBanner: String?

    public init(storageDirectory: URL? = nil) {
        let baseDir = storageDirectory ?? Self.defaultContainerDirectory()
        let notesURL = baseDir.appendingPathComponent("notes.json")
        do {
            let store = try FileBackedNoteStore(fileURL: notesURL)
            self.noteStore = store
            self.quickNoteFlow = QuickNoteFlow(noteStore: store)
            self.notes = (try? store.allActiveNotes()) ?? []
        } catch {
            let fallbackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("iagent-fallback-notes.json")
            let store = try! FileBackedNoteStore(fileURL: fallbackURL)
            self.noteStore = store
            self.quickNoteFlow = QuickNoteFlow(noteStore: store)
            self.notes = []
            self.statusBanner = "Kalıcı depo geçici alana düştü."
        }
    }

    private static func defaultContainerDirectory() -> URL {
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.iagent.shared"
        ) {
            return groupURL.appendingPathComponent("iAgentData", isDirectory: true)
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("iAgent", isDirectory: true)
    }

    /// Siri veya uygulama içi yazılı istekten gelen komutu sabit not akışıyla işler.
    public func handleSiriUtterance(_ utterance: String) -> String {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        lastReceivedUtterance = trimmed
        let taskID = UUID()

        do {
            let outcome = try quickNoteFlow.executeDirectIfMatched(
                utterance: trimmed,
                taskId: taskID,
                now: Date(),
                language: .turkish
            )
            refreshNotes()
            switch outcome {
            case .noteCreated(_, let spoken):
                lastNoteSummary = spoken
                return spoken
            case .notesFound(_, _, let spoken):
                lastNoteSummary = spoken
                return spoken
            case .draftCancelled(let spoken):
                lastNoteSummary = spoken
                return spoken
            case .needsContentClarification(let prompt):
                return prompt
            case .notMatched:
                let fallbackNote = try noteStore.createNote(
                    content: trimmed,
                    sourceTaskId: taskID,
                    now: Date()
                )
                refreshNotes()
                let spoken = "Not kaydedildi: \"\(fallbackNote.content)\"."
                lastNoteSummary = spoken
                return spoken
            }
        } catch {
            let message = "Not kaydedilemedi: \(error.localizedDescription)"
            statusBanner = message
            return message
        }
    }

    public func undoNote(id: UUID) {
        _ = try? noteStore.undoCreate(noteId: id, now: Date())
        refreshNotes()
    }

    public func refreshNotes() {
        try? noteStore.reloadFromDisk()
        notes = (try? noteStore.allActiveNotes()) ?? []
    }

    /// Uygulama URL şeması (örn. kestirme x-callback veya Share Extension) üzerinden açıldığında işler.
    public func handleIncomingURL(_ url: URL) {
        guard url.scheme == "iagent" else { return }
        if url.host == "task",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let idValue = components.queryItems?.first(where: { $0.name == "id" })?.value,
           let taskID = UUID(uuidString: idValue) {
            pendingHandoffTaskID = taskID
        } else if url.host == "share-inbox" {
            pendingShareInboxCount += 1
            statusBanner = "Paylaşılan içerik gelen kutusunda bekliyor."
        }
    }
}

@main
struct iAgentApp: App {
    @State private var coordinator = AppCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            StageOneRootView(coordinator: coordinator)
                .onOpenURL { url in
                    coordinator.handleIncomingURL(url)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        coordinator.refreshNotes()
                    }
                }
        }
    }
}

private struct StageOneRootView: View {
    @Bindable var coordinator: AppCoordinator
    @State private var draftInput: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let summary = coordinator.lastNoteSummary {
                    GroupBox("Son İşlem") {
                        Text(summary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack {
                    TextField("Şunu not al...", text: $draftInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Kaydet") {
                        _ = coordinator.handleSiriUtterance(draftInput)
                        draftInput = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draftInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                List(coordinator.notes) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.content)
                            .font(.body)
                        Text(note.createdAt, format: .dateTime.day().month().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Geri Al", role: .destructive) {
                            coordinator.undoNote(id: note.id)
                        }
                    }
                }
                .listStyle(.plain)
            }
            .padding()
            .navigationTitle("iAgent Notlar")
        }
    }
}
