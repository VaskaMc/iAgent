# iAgent — Siri ile Çalışan iPhone Kişisel Asistanı

**iAgent**, kullanıcının Siri’ye veya uygulama içine Türkçe (ve metin girişiyle Azerbaycanca) söylediği günlük istekleri anlayan, iPhone’un yerel yetenekleriyle yerine getiren ve her adımın gerçek sonucunu şeffaf biçimde bildiren kişisel asistandır.

- **Sunucu / Hesap Gerektirmez:** Uygun iPhone’da **Apple Intelligence (`SystemLanguageModel`)** ile API anahtarı girmeden başlar; istenirse kendi DeepSeek veya OpenAI-uyumlu HTTPS uç noktası Keychain korumalı olarak bağlanabilir.
- **Üç Katmanlı Mimari:**
  1. `Apps/iAgent/` & `Extensions/Share/`: Siri / `AppIntents`, `SwiftUI` ekranları, bas-konuş (`SpeechTranscriber`), sesli sentez ve Paylaşım Eklentisi.
  2. `Packages/AgentCore/`: Apple UI ve sağlayıcı SDK’larından bağımsız ajan çekirdeği (eylem şemaları, plan revizyonları, onay geçidi, adım makbuzları, tek yürütme kilidi, çökme kurtarma).
  3. `Packages/ModelProviders/` & `Packages/PhoneActions/`: Cihaz içi / harici model adaptörleri, veri izni kapısı ve EventKit, MessageUI, ContactsUI, MapKit, Kestirmeler köprüsü.
- **Master Plan:** [plans/IAGENT_ANTIGRAVITY_MASTER_PLAN_TR.md](plans/IAGENT_ANTIGRAVITY_MASTER_PLAN_TR.md)
- **Doğrulama ve Kurulum:** [docs/verification/BUILD_AND_DEVICE_SETUP_TR.md](docs/verification/BUILD_AND_DEVICE_SETUP_TR.md)

## Hızlı Doğrulama

macOS / Xcode üzerinde:
```bash
swift test --package-path Packages/AgentCore
swift test --package-path Packages/ModelProviders
swift test --package-path Packages/PhoneActions
xcodebuild -list -project Apps/iAgent/iAgent.xcodeproj
xcodebuild -showdestinations -project Apps/iAgent/iAgent.xcodeproj -scheme iAgent
```

Windows / çapraz platform doğrulama koşucusu:
```bash
python scripts/verify_all.py
```
