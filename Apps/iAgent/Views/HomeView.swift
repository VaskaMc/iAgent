import SwiftUI
import AgentCore

/// Ana ekran: Büyük "Konuş" düğmesi, yazı alanı, aktif model, bekleyen paylaşım girdisi ve son görev.
struct HomeView: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable var speechController: SpeechSessionController
    @State private var textInput: String = ""

    var body: some View {
        VStack(spacing: 16) {
            // Aktif model rozeti
            HStack {
                Label(coordinator.activeModelLabel, systemImage: "sparkles")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .accessibilityLabel("Aktif model: \(coordinator.activeModelLabel)")
                Spacer()
                Text(speechController.selectedLanguage == .turkish ? "TR" : "AZ")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }

            if !coordinator.pendingShareItems.isEmpty {
                GroupBox("Paylaşım Gelen Kutusu (\(coordinator.pendingShareItems.count))") {
                    VStack(alignment: .leading, spacing: 8) {
                        let first = coordinator.pendingShareItems[0]
                        Text(first.text)
                            .lineLimit(3)
                            .font(.subheadline)
                        Button("Özetle ve Not Al") {
                            Task {
                                await coordinator.summarizePendingShareItem(first)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Aktif konuşma / plan kartı veya son görev özeti
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let activePlan = coordinator.activePlanState {
                        ConversationPlanView(coordinator: coordinator, planState: activePlan)
                    } else if let latestResponse = coordinator.lastAssistantResponse {
                        GroupBox("Son Yanıt") {
                            Text(latestResponse)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel("Asistan yanıtı: \(latestResponse)")
                        }
                    }

                    if !coordinator.notes.isEmpty {
                        GroupBox("Son Yerel Notlar") {
                            ForEach(coordinator.notes.prefix(3)) { note in
                                HStack {
                                    Text(note.content)
                                        .font(.subheadline)
                                    Spacer()
                                    Button("Geri Al") {
                                        coordinator.undoNote(id: note.id)
                                    }
                                    .font(.caption)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }

            if speechController.isListening {
                GroupBox("Canlı Dikte") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Konuşulan metni düzenle...", text: $speechController.liveTranscript, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Durdur ve Gönder") {
                                let spoken = speechController.stopPushToTalkAndReturnTranscript()
                                if !spoken.isEmpty {
                                    Task { await coordinator.submitUserUtterance(spoken, source: .inAppVoice) }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Vazgeç", role: .cancel) {
                                speechController.stopListeningWithoutSending()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            // Tek elle erişim için alt bölgede yazı alanı ve büyük Konuş düğmesi
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("İsteğini yaz (TR / AZ)...", text: $textInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Yazılı istek alanı")
                    Button("Gönder") {
                        let submitted = textInput
                        textInput = ""
                        Task { await coordinator.submitUserUtterance(submitted, source: .inAppText) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Button {
                    Task {
                        if speechController.isListening {
                            let spoken = speechController.stopPushToTalkAndReturnTranscript()
                            if !spoken.isEmpty {
                                await coordinator.submitUserUtterance(spoken, source: .inAppVoice)
                            }
                        } else {
                            await speechController.beginPushToTalk(source: .inAppVoice)
                        }
                    }
                } label: {
                    Label(
                        speechController.isListening ? "Dinlemeyi Bitir" : "Konuş",
                        systemImage: speechController.isListening ? "stop.circle.fill" : "mic.circle.fill"
                    )
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(speechController.isListening ? .red : .accentColor)
                .accessibilityLabel(speechController.isListening ? "Dinlemeyi bitir" : "Bas konuş düğmesi")
                .accessibilityHint("Yanıt okunurken dokunursanız konuşmayı keser ve yeni istek alır.")
            }
        }
        .padding()
        .navigationTitle("iAgent")
    }
}
