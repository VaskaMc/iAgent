import SwiftUI
import AgentCore
import ModelProviders

/// Yetenek durumu, model seçimi, dil, harici veri izni, anahtar silme ve kestirme yönetimi.
struct CapabilitiesSettingsView: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable var speechController: SpeechSessionController

    @State private var apiKeyInput: String = ""
    @State private var customEndpointInput: String = "https://api.deepseek.com/v1/chat/completions"
    @State private var customModelIDInput: String = "deepseek-chat"
    @State private var shortcutLabelInput: String = "Çalışma Modu"
    @State private var shortcutNameInput: String = "CalismaModumuBaslat"
    @State private var probeResultMessage: String?

    var body: some View {
        Form {
            Section("Yetenek Matrisi") {
                ForEach(coordinator.capabilityStatuses, id: \.title) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.title)
                                .font(.body)
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.badge)
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
            }

            Section("Model Yolu ve Dil") {
                Picker("Model Tercihi", selection: $coordinator.modelPreference) {
                    Text("Otomatik").tag(ModelUserPreference.automatic)
                    Text("Yalnız bu iPhone").tag(ModelUserPreference.onDeviceOnly)
                    Text("Kendi sağlayıcım").tag(ModelUserPreference.customProvider)
                }
                Picker("İstek Dili", selection: $speechController.selectedLanguage) {
                    Text("Türkçe").tag(AgentLanguage.turkish)
                    Text("Azerbaycanca (Metin)").tag(AgentLanguage.azerbaijani)
                }
                Button("Cihaz Modelini Yeniden Kontrol Et") {
                    Task { await coordinator.refreshModelAvailability() }
                }
            }

            Section("Harici Sağlayıcı (DeepSeek / Özel HTTPS)") {
                TextField("HTTPS Uç Nokta", text: $customEndpointInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Model Kimliği", text: $customModelIDInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Anahtarı (Keychain'de saklanır)", text: $apiKeyInput)

                Button("Anahtarı Kaydet ve Kişisel Verisiz Sına") {
                    Task {
                        probeResultMessage = await coordinator.configureAndTestExternalProvider(
                            endpointString: customEndpointInput,
                            modelID: customModelIDInput,
                            apiKey: apiKeyInput
                        )
                        apiKeyInput = ""
                    }
                }
                if let probeResultMessage {
                    Text(probeResultMessage)
                        .font(.caption)
                }
                Button("Harici Veri İznini Geri Çek ve Anahtarı Sil", role: .destructive) {
                    coordinator.revokeExternalConsentAndDeleteKey(endpointString: customEndpointInput)
                    probeResultMessage = "Harici veri izni geri çekildi ve anahtar Keychain'den silindi."
                }
            }

            Section("Kestirme Bağlama") {
                TextField("Kullanıcı Etiketi", text: $shortcutLabelInput)
                TextField("Tam Kestirme Adı", text: $shortcutNameInput)
                Button("Kestirmeyi Bağla") {
                    coordinator.bindShortcut(label: shortcutLabelInput, shortcutName: shortcutNameInput)
                }
            }
        }
        .navigationTitle("Yetenekler ve Ayarlar")
    }
}
