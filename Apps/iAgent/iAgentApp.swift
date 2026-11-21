import SwiftUI
import Observation

/// Ana uygulama yaşam döngüsünü, Siri devirlerini ve kestirme geri çağrılarını koordine eder.
@MainActor
@Observable
public final class AppCoordinator {
    public static let shared = AppCoordinator()

    public var lastReceivedUtterance: String?
    public var lastNoteSummary: String?
    public var pendingHandoffTaskID: UUID?
    public var pendingShareInboxCount: Int = 0
    public var statusBanner: String?

    public init() {}

    /// Siri üzerinden gelen başlangıç isteğini kaydeder ve ilk yanıtı hazırlar.
    public func handleSiriUtterance(_ utterance: String) -> String {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        lastReceivedUtterance = trimmed
        let summary = "İstek alındı: \"\(trimmed)\""
        lastNoteSummary = summary
        return summary
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

    var body: some Scene {
        WindowGroup {
            StageZeroRootView(coordinator: coordinator)
                .onOpenURL { url in
                    coordinator.handleIncomingURL(url)
                }
        }
    }
}

private struct StageZeroRootView: View {
    @Bindable var coordinator: AppCoordinator
    @State private var draftInput: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("iAgent")
                    .font(.largeTitle.bold())
                Text("Siri ile çalışan iPhone kişisel asistanı (Aşama 0 iskeleti).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let utterance = coordinator.lastReceivedUtterance {
                    GroupBox("Son Siri İsteği") {
                        Text(utterance)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack {
                    TextField("İsteğini yaz...", text: $draftInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Gönder") {
                        _ = coordinator.handleSiriUtterance(draftInput)
                        draftInput = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draftInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("iAgent")
        }
    }
}
