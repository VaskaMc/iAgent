import SwiftUI
import AgentCore

/// İlk açılış ekranı: "Bu iPhone'da dene" ile gerçek örnek not, model durumu,
/// "Sağlayıcı bağla" ve Sesli Kestirme / Eylem Düğmesi kurulum rehberi.
/// Takvim, kişiler ve mikrofon izinleri ilk özelliğe dokunuşa kadar ertelenir.
struct OnboardingView: View {
    @Bindable var coordinator: AppCoordinator
    let onOpenProviderSettings: () -> Void
    let onCompleteOnboarding: () -> Void

    @State private var trialCompletedNote: PersistentNote?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("iAgent’e Hoş Geldiniz")
                        .font(.largeTitle.bold())
                    Text("Siri ve iPhone’un yerel yetenekleriyle çalışan kişisel asistan. Hesap veya sunucu gerektirmez.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                GroupBox("Model Durumu") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(coordinator.activeModelLabel, systemImage: "cpu")
                            .font(.headline)
                        Text(coordinator.activeModelStatusDescription)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Sağlayıcı bağla / Ayarlar") {
                            onOpenProviderSettings()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("1. İlk Deneme (İzin Gerektirmez)") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Anahtar girmeden gerçek bir yerel not oluşturup kalıcılığını sınayın.")
                            .font(.subheadline)
                        Button("Bu iPhone’da dene") {
                            trialCompletedNote = coordinator.createOnboardingSampleNote()
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Bu iPhone'da dene, örnek yerel not oluştur")

                        if let note = trialCompletedNote {
                            Text("Oluşturuldu: \"\(note.content)\" (ID: \(note.id.uuidString.prefix(8)))")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("2. Siri, Sesli Kestirmeler ve Eylem Düğmesi") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("• Siri İfadesi: \"Hey Siri, iAgent ile konuş\" diyerek deneyin.")
                        Text("• Özel Çağrı (örn. \"Jarvis\"): iOS Ayarlar → Erişilebilirlik → Sesli Kestirmeler üzerinden \"iAgent ile Konuş\" kestirmesini seçtiğiniz ifadeye bağlayın.")
                        Text("• Eylem Düğmesi: Desteklenen iPhone modellerinde Ayarlar → Eylem Düğmesi → Kestirme altından aynı kestirmeyi atayın.")
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("Takvim, Anımsatıcılar, Kişiler ve Mikrofon izinleri yalnız ilgili özelliği ilk kez kullandığınızda istenir.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Başla") {
                    onCompleteOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            .padding()
        }
        .navigationTitle("Kurulum")
    }
}
