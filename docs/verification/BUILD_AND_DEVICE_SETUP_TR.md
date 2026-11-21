# iAgent · Derleme, Cihaz Kurulumu ve Teslim Kılavuzu

Bu kılavuz, sıfırdan kurulum yapacak bir geliştiricinin veya test kullanıcısının **iAgent**’i Xcode 26 üzerinde derlemesi, fiziksel iPhone’a yüklemesi ve ilk Siri görevini tamamlaması için gereken tüm adımları içerir.

## 1. Ön Koşullar ve Sağlanması Gereken Yetkiler

- **Donanım ve İşletim Sistemi:** Xcode 26 (veya üzeri) çalıştıran bir Mac + iOS 26.0 (veya üzeri) yüklü fiziksel iPhone.
  - Apple Intelligence (`SystemLanguageModel`) cihaz içi çıkarımı için Apple Intelligence destekli iPhone gerekir. Donanım uygun değilse uygulama sabit yerel notlar ve isteğe bağlı kullanıcı API anahtarıyla çalışır.
- **Kullanıcı / Geliştirici Tarafından Sağlanacaklar:**
  1. **Apple Developer Hesabı / Takım Kimliği (Team ID):** Fiziksel cihaza imza (`Siri`, `App Groups`, `Keychain Sharing`) basmak için ücretsiz kişisel Apple hesabı veya ücretli Apple Developer Program hesabı. (TestFlight/App Store dağıtımı için ücretli Apple Developer Program üyeliği gerekir.)
  2. **Benzersiz Bundle Identifier ve App Group:** Kurumsal/kişisel derlemede `com.iagent.app`, `com.iagent.app.share-extension` ve `group.com.iagent.shared` kimliklerini kendi geliştirici takımınızın önekine göre güncelleyin (`Apps/iAgent/iAgent.entitlements`, `Extensions/Share/iAgentShareExtension.entitlements`, `Apps/iAgent/iAgent.xcodeproj/project.pbxproj`).
  3. **İsteğe Bağlı Harici Model Anahtarı:** Yalnız cihaz dışı model kullanılmak istenirse kullanıcının kendi DeepSeek veya OpenAI-uyumlu HTTPS anahtarı (uygulama içinden Keychain’e kaydedilir; kaynak koda asla gömülmez).

## 2. Adım Adım Xcode ve Paket Testleri

1. Depoyu Mac üzerine klonlayın ve kök dizine geçin.
2. Saf Swift çekirdeğini ve yardımcı paketleri çalıştırın:
   ```bash
   swift test --package-path Packages/AgentCore
   swift test --package-path Packages/ModelProviders
   swift test --package-path Packages/PhoneActions
   ```
3. Xcode projesini açın ve ortak şemayı doğrulayın:
   ```bash
   xcodebuild -list -project Apps/iAgent/iAgent.xcodeproj
   xcodebuild -showdestinations -project Apps/iAgent/iAgent.xcodeproj -scheme iAgent
   ```
4. Simülatörde uygulama ve senaryo testlerini çalıştırın:
   ```bash
   SIM_ID=$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ {print $2; exit}')
   xcodebuild test -project Apps/iAgent/iAgent.xcodeproj -scheme iAgent -destination "platform=iOS Simulator,id=$SIM_ID"
   ```

## 3. Fiziksel iPhone’a Kurulum ve İlk Görevin Tamamlanması

1. `Apps/iAgent/iAgent.xcodeproj` içinde **iAgent** ve **iAgentShareExtension** hedeflerinin **Signing & Capabilities** sekmesinden kendi **Team** bilginizi seçin.
2. **Siri** ve **App Groups** (`group.com.iagent.shared`) yetkilerinin her iki hedefte de yeşil olduğunu doğrulayın.
3. Fiziksel iPhone’u kabloyla bağlayın, şemadan `iAgent` ve hedef olarak iPhone’unuzu seçip **Run (⌘R)** yapın.
4. Uygulama ilk kez açıldığında:
   - **“Bu iPhone’da dene”** düğmesine dokunarak anahtar girmeden örnek not oluşturun; uygulamayı tamamen kapatıp tekrar açtığınızda aynı notun listede korunduğunu doğrulayın.
   - **Siri ile Test:** `"Hey Siri, iAgent ile konuş"` deyin → `"Ne yapmamı istersin?"` yanıtı gelince `"Şunu not al: İlk fiziksel cihaz notum"` söyleyin.
   - **İsteğe Bağlı Sesli Kestirme (“Jarvis”):** iOS **Ayarlar → Erişilebilirlik → Sesli Kestirmeler** üzerinden `"iAgent ile Konuş"` kestirmesini seçtiğiniz özel ifadeye bağlayın.
   - **İsteğe Bağlı Eylem Düğmesi:** iOS **Ayarlar → Eylem Düğmesi → Kestirme** bölümünden aynı kestirmeyi atayın.

## 4. TestFlight Dağıtımı (İsteğe Bağlı)

1. Xcode **Product → Archive** ile sürümü arşivleyin ve App Store Connect’e yükleyin.
2. App Store Connect’te TestFlight inceleme notlarına şu demo yolunu ekleyin:
   - *“Uygulama ilk açılışta Apple Intelligence (cihaz içi) veya sabit yerel not akışıyla hesap/anahtar istemeden çalışır. Takvim, Anımsatıcılar ve Mesajlar akışları yalnız ilgili aksiyon tetiklendiğinde sistem izin penceresini açar.”*
3. Güncel Apple SDK şartları ve App Store gizlilik beyanları için `PRIVACY_AND_APP_STORE_DECLARATIONS_TR.md` belgesini kontrol edin.
