import SwiftUI
import AgentCore
import ModelProviders

/// Yetenek durumu, model seçimi, JARVIS persona, sürüş güvenliği, hafıza kasası, harici veri izni ve kestirme yönetimi.
struct CapabilitiesSettingsView: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable var speechController: SpeechSessionController

    @State private var apiKeyInput: String = ""
    @State private var customEndpointInput: String = "https://api.deepseek.com/v1/chat/completions"
    @State private var customModelIDInput: String = "deepseek-chat"
    @State private var shortcutLabelInput: String = "Çalışma Modu"
    @State private var shortcutNameInput: String = "CalismaModumuBaslat"
    @State private var probeResultMessage: String?

    @State private var memoryKeyInput: String = ""
    @State private var memoryValueInput: String = ""
    @State private var memoryTierSelection: MemoryPrivacyTier = .standardLocal
    @State private var memoryFeedbackMessage: String?

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

            Section("Model Yolu, Persona ve Dil") {
                Picker("Model Tercihi", selection: $coordinator.modelPreference) {
                    Text("Otomatik").tag(ModelUserPreference.automatic)
                    Text("Yalnız bu iPhone").tag(ModelUserPreference.onDeviceOnly)
                    Text("Kendi sağlayıcım").tag(ModelUserPreference.customProvider)
                }
                Picker("İstek Dili", selection: $speechController.selectedLanguage) {
                    Text("Türkçe").tag(AgentLanguage.turkish)
                    Text("Azerbaycanca (Metin)").tag(AgentLanguage.azerbaijani)
                }
                Picker("JARVIS Persona", selection: $speechController.personaPreset) {
                    Text("Kahya (.butler)").tag(JarvisPersonaPreset.butler)
                    Text("Yönetici (.executive)").tag(JarvisPersonaPreset.executive)
                }
                Toggle("Sürüş Güvenliği (CarPlay) Modu", isOn: $coordinator.isDrivingSafetyActive)
                Button("Cihaz Modelini Yeniden Kontrol Et") {
                    Task { await coordinator.refreshModelAvailability() }
                }
            }

            Section("JARVIS Hafıza Kasası (Hızlı Tercih)") {
                TextField("Tercih Başlığı (ör. Kahve Tercihi)", text: $memoryKeyInput)
                TextField("Değer (ör. Şekersiz Türk kahvesi)", text: $memoryValueInput)
                Picker("Gizlilik Katmanı", selection: $memoryTierSelection) {
                    Text("Standart Yerel").tag(MemoryPrivacyTier.standardLocal)
                    Text("Yalnız bu iPhone").tag(MemoryPrivacyTier.sensitivePersonal)
                    Text("Geçici Oturum").tag(MemoryPrivacyTier.ephemeralSession)
                }
                Button("Hafıza Kasasına Kaydet") {
                    let result = coordinator.rememberUserPreference(
                        key: memoryKeyInput,
                        value: memoryValueInput,
                        tier: memoryTierSelection
                    )
                    switch result {
                    case .success(let entry):
                        memoryFeedbackMessage = "Kaydedildi: \(entry.key)"
                        memoryKeyInput = ""
                        memoryValueInput = ""
                    case .failure(.sensitiveSecretRejected):
                        memoryFeedbackMessage = "Reddedildi: Parola, IBAN, TCKN, kart numarası veya API anahtarı düz metin hafızaya yazılamaz."
                    case .failure(.emptyKeyOrValue):
                        memoryFeedbackMessage = "Lütfen başlık ve değer alanlarını doldurun."
                    case .failure(.entryNotFound(_)):
                        memoryFeedbackMessage = "Kayıt bulunamadı."
                    }
                }
                if let memoryFeedbackMessage {
                    Text(memoryFeedbackMessage)
                        .font(.caption)
                        .foregroundStyle(memoryFeedbackMessage.hasPrefix("Reddedildi") ? .red : .secondary)
                }
                if !coordinator.memoryEntries.isEmpty {
                    ForEach(coordinator.memoryEntries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.key)
                                    .font(.subheadline.bold())
                                Text(entry.value)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Sil", role: .destructive) {
                                coordinator.forgetMemory(id: entry.id)
                            }
                            .font(.caption)
                        }
                    }
                }
            }

            Section("Harici Sağlayıcı (DeepSeek / Özel HTTPS · SSRF Korumalı)") {
                TextField("HTTPS Uç Nokta", text: $customEndpointInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Model Kimliği", text: $customModelIDInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Anahtarı (Keychain'de saklanır)", text: $apiKeyInput)

                Text("StrictEndpointValidator: http://, localhost, .local ve özel ağ IP adresleri otomatik engellenir.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

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
