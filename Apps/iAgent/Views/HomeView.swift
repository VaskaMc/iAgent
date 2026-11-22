import SwiftUI
import AgentCore

/// iOS 26 Liquid Glass ve eski sürümler için `.ultraThinMaterial` yedeği sunan ortak cam yüzey değiştiricisi.
struct JarvisGlassSurfaceModifier<S: Shape>: ViewModifier {
    let shape: S
    let tintColor: Color?

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if let tintColor {
                content.glassEffect(.regular.tint(tintColor.opacity(0.18)), in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 1))
        }
        #else
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 1))
        #endif
    }
}

extension View {
    func jarvisGlassSurface<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(JarvisGlassSurfaceModifier(shape: shape, tintColor: tint))
    }
}

/// JARVIS durum küresi: ses seviyesi, dinleme/konuşma fazı ve `accessibilityReduceMotion` statik mod desteği.
struct JarvisStatusOrbView: View {
    let isListening: Bool
    let isSpeaking: Bool
    let isExecuting: Bool
    let isWakeActive: Bool
    let audioLevelRMS: Double
    let persona: JarvisPersonaPreset
    let onTap: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phaseColor: Color {
        if isListening { return .cyan }
        if isSpeaking { return .mint }
        if isExecuting { return .orange }
        if isWakeActive { return .teal }
        return .blue
    }

    private var phaseTitle: String {
        if isListening { return "Dinleniyor" }
        if isSpeaking { return "Yanıtlıyor" }
        if isExecuting { return "Yürütülüyor" }
        if isWakeActive { return "Takip Penceresi Açık" }
        return "JARVIS Hazır"
    }

    private var orbSymbol: String {
        if isListening { return "waveform" }
        if isSpeaking { return "speaker.wave.2.fill" }
        if isExecuting { return "gearshape.2.fill" }
        return "circle.hexagongrid.fill"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [phaseColor.opacity(0.35), phaseColor.opacity(0.06)],
                                center: .center,
                                startRadius: 4,
                                endRadius: 36
                            )
                        )
                        .frame(width: 64, height: 64)

                    Circle()
                        .strokeBorder(phaseColor.opacity(0.7), lineWidth: 2)
                        .frame(width: 54, height: 54)
                        .scaleEffect(reduceMotion ? 1.0 : (1.0 + CGFloat(min(0.16, audioLevelRMS * 0.25))))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: audioLevelRMS)

                    Image(systemName: orbSymbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(phaseColor)
                }
                .frame(minWidth: 64, minHeight: 64)

                VStack(alignment: .leading, spacing: 4) {
                    Text(phaseTitle)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(
                        isSpeaking
                            ? "Kesmek için dokunun (barge-in)"
                            : (persona == .butler ? "Kahya üslubu etkin" : "Yönetici özeti etkin")
                    )
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.75))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(persona == .butler ? "KAHYA" : "YÖNETİCİ")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(phaseColor.opacity(0.24), in: Capsule())
                        .foregroundStyle(.white)

                    Text(String(format: "RMS %.2f", audioLevelRMS))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.68))
                }
            }
            .padding(12)
            .frame(minHeight: 72)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.024, green: 0.035, blue: 0.059),
                        Color(red: 0.051, green: 0.082, blue: 0.149)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .jarvisGlassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: phaseColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("JARVIS durum küresi: \(phaseTitle)")
        .accessibilityHint("Bas-konuş başlatır veya sesli okuma sırasında dokunursanız konuşmayı keser.")
    }
}

/// Ana ekran: Spatial JARVIS HUD küresi, hızlı eylem çipleri, aktif plan/brifing kartları ve alt komut rıhtımı.
struct HomeView: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable var speechController: SpeechSessionController
    @State private var textInput: String = ""
    @State private var showMemoryVaultPreview: Bool = false
    @State private var isBriefingExpanded: Bool = false

    var body: some View {
        VStack(spacing: 14) {
            // Üst durum şeridi: Aktif model, persona ve dil rozeti
            HStack(spacing: 8) {
                Label(coordinator.activeModelLabel, systemImage: "sparkles")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .jarvisGlassSurface(in: Capsule())
                    .accessibilityLabel("Aktif model: \(coordinator.activeModelLabel)")

                Spacer()

                if speechController.wakeSession.isActive() {
                    Label("Takip 45s", systemImage: "ear.badge.waveform")
                        .font(.caption2.bold().monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.teal.opacity(0.2), in: Capsule())
                }

                Button {
                    speechController.selectedLanguage = speechController.selectedLanguage == .turkish ? .azerbaijani : .turkish
                    Task { await coordinator.refreshModelAvailability() }
                } label: {
                    Text(speechController.selectedLanguage == .turkish ? "TR" : "AZ")
                        .font(.caption.bold())
                        .frame(minWidth: 36, minHeight: 28)
                        .padding(.horizontal, 6)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
                .accessibilityLabel("İstek dili: \(speechController.selectedLanguage == .turkish ? "Türkçe" : "Azerbaycanca")")
            }

            // Canlı JARVIS Spatial HUD Küresi
            JarvisStatusOrbView(
                isListening: speechController.isListening,
                isSpeaking: speechController.isSpeaking,
                isExecuting: coordinator.isExecutingPlan,
                isWakeActive: speechController.wakeSession.isActive(),
                audioLevelRMS: speechController.audioLevelRMS,
                persona: speechController.personaPreset,
                onTap: {
                    Task { await toggleVoiceInteraction() }
                }
            )

            // JARVIS Hızlı Eylem Çipleri
            quickActionChipsBar

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

            // Aktif konuşma / plan kartı, son brifing artifact ve hafıza/not özeti
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

                    if showMemoryVaultPreview {
                        GroupBox("Hafıza Kasası (\(coordinator.memoryEntries.count))") {
                            VStack(alignment: .leading, spacing: 6) {
                                if coordinator.memoryEntries.isEmpty {
                                    Text("Henüz onaylı tercih kaydı yok. Ayarlar’dan ekleyebilir veya \"Bunu hatırla: ...\" diyebilirsiniz.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(coordinator.memoryEntries.prefix(4)) { entry in
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(entry.key)
                                                    .font(.caption.bold())
                                                Text(entry.value)
                                                    .font(.subheadline)
                                            }
                                            Spacer()
                                            Text(entry.privacyTier == .sensitivePersonal ? "Yalnız iPhone" : "Yerel")
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if let latestArtifact = coordinator.latestArtifacts.first {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(latestArtifact.title, systemImage: "doc.richtext")
                                        .font(.subheadline.bold())
                                    Spacer()
                                    Text("Rev \(latestArtifact.revisionNumber)")
                                        .font(.caption2.monospacedDigit())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.cyan.opacity(0.15), in: Capsule())
                                }
                                Text(latestArtifact.markdownBody)
                                    .font(.caption)
                                    .lineLimit(isBriefingExpanded ? nil : 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                HStack {
                                    Text(latestArtifact.updatedAt, style: .time)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button(isBriefingExpanded ? "Daralt" : "Tamamını Gör") {
                                        isBriefingExpanded.toggle()
                                    }
                                    .font(.caption)
                                }
                            }
                        } label: {
                            Text("Son Brifing / Yapay Ürün")
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

            // Tek elle erişim + AX5 Dynamic Type uyumlu başparmak bölgesi komut rıhtımı
            VStack(spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        commandTextField
                        sendCommandButton
                    }
                    VStack(spacing: 8) {
                        commandTextField
                        sendCommandButton
                            .frame(maxWidth: .infinity)
                    }
                }

                Button {
                    Task { await toggleVoiceInteraction() }
                } label: {
                    Label(
                        speechController.isListening ? "Dinlemeyi Bitir" : "Konuş",
                        systemImage: speechController.isListening ? "stop.circle.fill" : "mic.circle.fill"
                    )
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.vertical, 6)
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

    private var quickActionChipsRow: some View {
        HStack(spacing: 8) {
            quickChipButton(title: "Sabah Brifingi", systemImage: "sun.horizon.fill") {
                Task { await coordinator.runMorningBriefing(source: .inAppText) }
            }
            quickChipButton(title: "Son Notlar", systemImage: "note.text") {
                Task { await coordinator.submitUserUtterance("Son notlarımı bul", source: .inAppText) }
            }
            quickChipButton(title: "Hafıza Kasası", systemImage: "brain.head.profile") {
                showMemoryVaultPreview.toggle()
            }
        }
    }

    private var quickActionChipsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 8) {
                    quickActionChipsRow
                }
            } else {
                quickActionChipsRow
            }
            #else
            quickActionChipsRow
            #endif
        }
    }

    private func quickChipButton(title: String, systemImage: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .jarvisGlassSurface(in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var commandTextField: some View {
        TextField("İsteğini yaz (TR / AZ)...", text: $textInput)
            .textFieldStyle(.roundedBorder)
            .frame(minHeight: 44)
            .accessibilityLabel("Yazılı istek alanı")
    }

    private var sendCommandButton: some View {
        Button("Gönder") {
            let submitted = textInput
            textInput = ""
            Task { await coordinator.submitUserUtterance(submitted, source: .inAppText) }
        }
        .buttonStyle(.borderedProminent)
        .frame(minHeight: 44)
        .disabled(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func toggleVoiceInteraction() async {
        if speechController.isListening {
            let spoken = speechController.stopPushToTalkAndReturnTranscript()
            if !spoken.isEmpty {
                await coordinator.submitUserUtterance(spoken, source: .inAppVoice)
            }
        } else {
            await speechController.beginPushToTalk(source: .inAppVoice)
        }
    }
}
