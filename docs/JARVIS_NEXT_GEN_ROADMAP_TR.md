# iAgent → Tony Stark JARVIS · Yeni Nesil Yetenek ve Mimari Yol Haritası

Bu belge, **Codemagic Build #7 (`84de471`)** kararlı iOS `.ipa` sürümünün (`iAgent-Full.ipa` + `iAgent-Sideload.ipa`) doğrulanmasının ardından görevlendirilen **10 uzman JARVIS subagent’ının** mevcut kod tabanını inceleyerek ürettiği somut Swift/iOS 26 teknik önerilerinin derlemesidir.

---

## 1. Proaktif Rutinler Mimarisi (`JARVIS Proactive Routines Architect`)

- **Boşluk Özeti:** `ExecutionLeaseStore` şu an bellek içi ve `CalendarEventRecord` konum taşımıyor; `RemindersActionExecutor` okuma içermiyor ve `MapsActionExecutor` ETA hesaplamıyor.
- **Yeni Eylemler (`Packages/AgentCore`):** `briefing.compose` (sabah/akşam brifingi), `reminders.read`, `maps.estimateETA`, `routine.meetingPrepSchedule`, `memory.remember`, `memory.manage`.
- **Sabah/Akşam Brifing & ETA Sentezi (`BriefingSynthesizer`):**
  - Bugünün etkinlikleri + açık/gecikmiş `EKReminder` öğeleri + ilk konumlu toplantı için `MKDirections.calculateETA()` ile önerilen çıkış saati + çakışma uyarısı.
  - Siri akışında yalnız `IntentDialog`; uygulama içi bas-konuşta *barge-in* destekli kısa sesli okuma.
  - `.writeOnly` takvim izninde sahte "boş ajanda" üretilmez; kilitli cihazda `.requiresLocalDeviceAuthentication` istenir.
- **Toplantı Öncesi Hazırlık (`BGTaskScheduler` + `UNUserNotificationCenter`):**
  - `T - (ETA + prepBuffer)` zamanında kilit ekranı gizli yerel bildirim kurar; asla otonom mesaj/arama yapmaz.
- **İdempotent Çift Çağrı Koruması:** Disk tabanlı `FileBackedExecutionLeaseStore` + 15 sn/5 sn pencereli `IdempotencyGate` + `eventRevisionHash` ile toplantı saati değiştiğinde bildirim yenileme.

---
## 2. Kişisel Hafıza Kasası (`JARVIS Memory Vault Engineer`)

- **Boşluk Özeti:** Görev geçmişi (`HistoryView`) dışında onaylı uzun süreli tercih/ilişki/alışkanlık belleği ve CloudKit-kapalı yerel semantik arama katmanı henüz yok.
- **Yeni Eylemler (`Packages/AgentCore`):** `memory.remember`, `memory.recall`, `memory.update`, `memory.forget` (`ConfirmationKind.explicitSummary`, `isUndoable: true`, `requiresUnlockedDevice: true`).
- **Katı Köken & Gizlilik Katmanları:**
  - `MemoryProvenance`: Her kayıt değiştirilemez ham `rawUtterance`, `sourceTaskId`, `sourceChannel` ve `editHistory` ile gelir; kullanıcı tercihin hangi sözünden geldiğini görür.
  - `MemoryPrivacyTier`: `.sensitivePersonal` (*Yalnız bu iPhone* — asla buluta çıkmaz), `.standardLocal` (varsayılan cihaz içi; yalnız kayıt bazlı izin + `.approvedMemoryContext` ile özetlenebilir), `.ephemeralSession` (TTL sonrası imha).
  - `HabitObservationCandidate`: Arka arkaya >= 3 benzer komut gözlemlendiğinde sessizce yazmaz; onay ister.
  - `MemorySecretGuard`: Parola, PIN, API anahtarı, IBAN ve kart numarasını düz metin hafızadan reddeder.
- **TR/AZ Hibrit Geri Getirme & Depolama:**
  - `TurkicSemanticNormalizer` + `OnDeviceTurkicEmbedder` (`NLEmbedding.sentenceEmbedding(for: .turkish)` + 256-boyutlu trigram fallback).
  - SwiftData (`cloudKitDatabase: .none`) + `.completeFileProtection` disk yazımı; `clearTaskHistoryPreservingNotesAndVault()` ile geçmiş silmeden bağımsız.

---

## 3. Hibrit Çoklu-Model Beyni (`JARVIS Multi-Model Router Architect`)

- **Boşluk Özeti:** `ExternalChatCompletionsProvider` yalnız `/v1/chat/completions` ve tek sabit aracı (`notes_create`) gönderiyor; `ExternalDataConsentManager` tek sağlayıcı tuttuğu için çapraz sağlayıcı izolasyonu yapamıyor; `AppCoordinator` her turda yeni `ModelRouter` yaratıyor.
- **Bağımsız Protokol Adaptörleri (`Packages/ModelProviders`):**
  - `AppleFoundationModelProvider` (`Tier 1`, TR cihaz içi, 0 ağ, termal kontrol),
  - `OpenAIResponsesProvider` (`POST /v1/responses`, düz tool şeması, `store: false`, `reasoning.effort`),
  - `AnthropicMessagesProvider` (`POST /v1/messages`, `x-api-key`, `input_schema`, `thinking.budget_tokens`, `529` overloaded yönetimi),
  - `DeepSeekProvider` (`/v1/chat/completions`, `reasoning_content` akışı),
  - `OfflineDeterministicFallbackProvider` (`Tier 0`: `QuickNoteFlow` + `DateAndTimeResolver`).
- **Streaming Tool-Call & DAG Koruması:** `ToolCallDeltaAccumulator` akış bitene kadar yan etkili adım yürütmez; `length` / `max_tokens` / `incomplete` durumunda kesik planı çöpe atar. 13 kataloğun tamamı `step_id` ve `depends_on` ile modele açılır.
- **Yönlendirme, Devre Kesici & Bütçe:**
  - `TaskComplexityClassifier` + uzun ömürlü `HybridModelRouter` actor + `(providerID, host)` bazlı `CircuitBreakerRegistry` (`401/402` kalıcı mandal; `429/5xx` üstel soğuma) + `SessionTokenLedger` (yalnız doğrulanmış token sayaçları, uydurma maliyet yok).
  - `ProviderConsentKey(providerID, endpointHost)` ile sağlayıcı başına katı izin izolasyonu; TR/AZ BPE token çarpanına göre %50 çıktı güvenlik payı.

---

## 4. Sıfır-Güven (Zero-Trust) Güvenlik ve Mahremiyet Mimarisi (`JARVIS Zero-Trust Security Auditor`)

- **Tespit Edilen Açıklar:** `computeApprovalDigest` tüm parametre alanlarını (`noteContent`, `shortcutInput`, `urlString`) kapsamıyor; `KeychainSecretStore.saveKey` sil-sonra-ekle sırasında atomik değil; `RedactingLogger` TCKN/IBAN/JWT/PAN/URL maskelemiyor; `PinnedHTTPSDelegate` sertifika SPKI pinning yapmıyor.
- **Kademeli Biyometrik Onay (`LocalAuthentication`):**
  - `ActionRiskTier` (`tier0ReadSafe`..`tier3BiometricRequired`): Dış iletişim, finansal anahtar kelimeli kestirmeler ve silme adımları için `LAContext` (`touchIDAuthenticationAllowableReuseDuration = 0`) + HMAC-SHA256 `BiometricAttestation` zorunlu.
  - Kanonik JSON SHA-256 `computeCanonicalApprovalDigest` + `selectContactCandidate` değişiminde otomatik revizyon yenileme.
- **Kilit Ekranı & Disk Koruması:** `LockScreenPrivacyShieldModifier` (uygulama arka planda/kilitliyken `.redacted` + blur) + `LockScreenPrivacyMasker` + `FileProtectionType.complete`.
- **Kriptografik Denetim İzi (`CryptographicAuditTrail`):** Her `ActionReceipt` için önceki kayıt özetiyle bağlı SHA-256 + HMAC-SHA256 zinciri (`verifyIntegrity()` tek baytlık disk değişimini yakalar).
- **Ağ & Prompt Enjeksiyon Sertleştirmesi:**
  - `StrictEndpointValidator` + `PinnedHTTPSDelegate` (SPKI SHA-256 pinning + SSRF özel IP/`localhost`/`.local`/`http://` downgrade engeli).
  - `PromptInjectionSanitizer` (Unicode BiDi/Tag temizliği, gizli HTML `display:none` soyma, aktif URL etkisizleştirme) + `TaintPolicyEnforcer` + `HardenedRedactingLogger` (Zero-PII telemetri).

---

## 5. JARVIS Spatial HUD & SwiftUI UX Mimarisi (`JARVIS Spatial HUD & UX Designer`)

- **Boşluk Özeti:** `ActivePlanPresentation` yalnızca `ContactCandidate` tutuyor (harita ve zaman netleştirme UI kartları yok); `CoordinatorStepBridge` birçok eylemi `default:` bloğuna düşürüyor; canlı adım ilerlemesi ve satır içi `Geri Al` / `Saat Kaydır` yok.
- **JARVIS Mekansal Tasarım Sistemi (`JarvisHUDTheme`):**
  - Adaptif dark-first cam yüzeyler (`#06090F` derin zemin + `.ultraThinMaterial`), durum odaklı renk tokenları (`hudCyan`, `hudAmber`, `hudEmerald`, `hudCrimson`, `hudIndigo`), `.monospacedDigit()` zaman çizelgesi ve `.sensoryFeedback` haptik dil.
- **Ana Bileşenler:**
  - `JarvisStatusOrbView`: `SpeechSessionController` (`audioRMS`, `frequencyBands[24]`, `HudOrbPhase`) ile senkron 4 katmanlı Arc Reactor / dalga formu küresi; tek dokunuşla bas-konuş ve *barge-in* (konuşma kesme).
  - `StepReceiptTimelineView` + `TimelineStepNodeView`: İnsan dostu eylem başlıkları, DAG bağları, yürütme öncesi `-15 dk` / `+30 dk` / `Çıkar`, yürütme sonrası satır içi `Geri Al` / `Yeniden Dene` (`.uncertain` için otomatik retry yasaklı!).
  - `ThumbZoneCommandDock` + `QuickActionChipsBar`: Alt %35 başparmak bölgesinde canlı dikte düzenleme, TR/AZ hızlı geçiş kapsülü ve bağlama duyarlı eylem çipleri.
  - `DisambiguationDeckView`: `ContactDisambiguationCard` (avatar + çoklu numara seçimi + `CNContactPicker`), `MapDisambiguationCard` (konum izni istemeyen statik mini `Map` + ulaşım türü çipleri), `TimeDisambiguationCard` (akıllı öneri çipleri + `DatePicker` + süre).
- **Tam Erişilebilirlik:** `accessibilityAction(named:)` VoiceOver rotor kısayolları, `AX5` Dynamic Type uyumlu `ViewThatFits` rıhtım, `accessibilityReduceMotion` altında animasyonsuz statik halka ve 44×44 pt dokunma alanları.

---
## 6. Ekosistem ve Akıllı Ev Otomasyonu (`JARVIS Ecosystem & Smart Home Automator`)

- **Boşluk Özeti:** `ShortcutsBridgeExecutor` bellek içi `pendingCallbacks` tuttuğu için iOS süreci kapandığında dönüş token'ı siliniyor; `CoordinatorStepBridge` henüz `shortcutsRun` çalıştırmıyor; `AskIAgentIntent` sürüş sırasında ön plana geçiş yapıyor.
- **Yeni Eylemler & İzin Ayrımı (`Packages/AgentCore` & `Packages/PhoneActions`):**
  - `focus.statusRead` / `focus.appFilterApply` (`INFocusStatusCenter` + `SetFocusFilterIntent`; sistem odağını değiştirme Kestirme şablonuyla yapılır, sahte başarı verilmez).
  - `home.statusRead` / `home.sceneExecute` / `home.roomControl` / `home.securityControl` (`HMHomeManager` + Matter uyumlu; kapı kilidi/alarm/garaj `.explicitSecurityConfirmation` ile ayrılır ve `isReachable` / karakteristik geri-okuma doğrulanır).
  - `music.control` / `music.play` (`SystemMusicPlayer.shared` + `MusicSubscription.current.canPlayCatalogContent` kontrolü; `AVAudioSession` `duckOthers` ses çakışması engeli).
  - `carplay.drivingBriefing` + `DrivingSafetyPolicy` (CarPlay / `.carAudio` sırasında ekran/mail/güvenlik kilidi işlemleri `.deferredForDrivingSafety` olur, sesli yanıt `<= 160` karakter kalır).
- **Çift Yönlü Kestirme Orkestrasyonu (`ShortcutsBridgeExecutorV2`):**
  - `ShortcutParameterSpec` (girdi tip/aralık doğrulama + sır taraması) ve `ShortcutOutputContract` (`UntrustedContentPolicy` ile korunan JSON/metin çıktısı).
  - App Group tabanlı kalıcı `PendingShortcutCallbackStore` (120 sn TTL sonrası `.uncertain`) ve `ShortcutHealthProbe` sağlık testi.

---

## 7. Çok Modlu Görsel ve Belge Zekâsı (`JARVIS Multimodal Vision Researcher`)

- **Boşluk Özeti:** `Extensions/Share/Info.plist` ve `ShareViewController` yalnızca `plainText` kabul ediyor; `SharedInboxManager` medya varlıklarını saklamıyor; görselden takvim/harcama/kişi taslağı çıkarma boru hattı yok.
- **Bellek Güvenli Yakalama & Paylaşım (`Extensions/Share` + `PhotosPicker` + `VisionKit`):**
  - Eklenti (< 120 MB RAM limiti) çıkarım yapmaz; `CGImageSource` ile max 2048 px küçültme + EXIF GPS sıyırma yaparak `SharedInboxManager` App Group deposuna yazar (`SharedMediaLimits`: PDF ≤ 20 MB / 20 sayfa, Görsel ≤ 10 MB).
  - `PhotosPicker` kullanıldığı için tam galeri izni (`NSPhotoLibraryUsageDescription`) istenmez; kamera izni yalnız tarayıcı açılınca istenir.
- **Cihaz İçi Çıkarım Boru Hattı (`VisualDocumentAnalyzer`):**
  - `PDFKit` (vektör PDF → metin; taranmış PDF → thumbnail), iOS 26 `RecognizeDocumentsRequest` (`.tables`, `.barcodes`, `.detectedData`) + `VNRecognizeTextRequest(.accurate)`, deterministik `IATABCBPParser` (uçak bileti barkodu) ve `TurkishReceiptMathValidator` (fiş KDV/toplam doğrulaması).
  - iOS 26 `SystemLanguageModel` 4.096 token sınırına uygun parçalama; `#available(iOS 27.0, *)` üzerinde doğrudan `Attachment(cgImage)` çapraz doğrulaması.
- **Yeni Eylemler & Prompt Injection Duvarı:**
  - `expenses.noteCreate` (harcama notu), `contacts.draft` (`CNContactViewController(forNewContact:)` ile sessiz yazma olmadan sistem kişi taslağı).
  - `UntrustedContentPolicy.enforceVisualPipelinePolicy`: `VisualIntentScope` dışındaki eylemleri ve metin içi enjekte URL/komutları kesin engeller; dış VLM için `.sharedDocumentOCRText` vs `.visualImagePayload` izinlerini ve PII görsel maskelemeyi ayırır.

---

## 8. 8-Adım Üstü Otonom Planlayıcı ve Saga Motoru (`JARVIS Autonomous Planner Engineer`)

- **Boşluk Özeti:** v1 `maxStepsPerPlan = 8` sert sınırı, `ExecutionLeaseStore` kalıcılığı olmaması, tek döngüde duraklatma/dallanma eksikliği ve kısmi hata telafisi (Saga) bulunmaması.
- **Hiyerarşik Plan (`GoalPlanRevision` → `PlanPhase` → `HierarchicalActionStep`):**
  - Faz başına `<= 8` adım, toplam `<= 32` adım (`PlanBudgetLimits.v2Default`), çapraz faz DAG sıra kısıtı, faz kapısı onayları (`PhaseConfirmationPolicy.perPhaseGate`) ve tüm parametreleri kapsayan `computeGoalApprovalDigest`.
- **Saga Telafi Zinciri (`CompensableStepExecutorProtocol`):**
  - Kritik adım (`.critical`) hata verirse işlem durur; geri alınabilir adımlar LIFO sırayla kullanıcı onaylı `SagaDecisionContext` ile telafi edilir (`FileBackedNoteStore.undoCreate`, `CalendarBackendProtocol.deleteEvent`, yeni `RemindersBackendProtocol.deleteReminder`); geri alınamayan dış iletişim adımları dürüstçe ayrı raporlanır.
- **Akıllı Bağlam Çıkarımı & Oturumlar Arası Kurtarma:**
  - `SafeLocalContextInferenceEngine`: Önceki adım çıktısı, tekil not eşleşmesi veya yalnız `fullAccess` + kilit açıkken boş takvim aralığı bulur (`.writeOnly` ve kilitli ekrana kesin saygı).
  - `PersistentJournalV2` + `TaskCheckpoint`: Çökme sonrası yeniden açılışta kaldığı faz/adımdan devam veya belirsiz adımda kullanıcı kararı (`RecoveryUserDecision`) + canlı plan duraklatma/dallanma (`branchId`).

---
## 9. iPhone Donanım, Kilit Ekranı ve Sistem Entegrasyonu (`JARVIS iOS Hardware & LockScreen Integrator`)

- **Boşluk Özeti:** `AskIAgentIntent` `.alwaysAllowed` sabitli ve `.vocalShortcut` / `.actionButton` kaynakları kullanılmıyor; `Info.plist` içinde Live Activities, `AlarmKit` ve arka plan ses anahtarları yok; `iAgentWidgetExtension` hedefi henüz yok.
- **Dynamic Island & StandBy HUD (`iAgentWidgetExtension` + `ActivityKit`):**
  - `JarvisPlanActivityAttributes` + `ExecutionCoordinator` `onProgress` akışı ile adım adım canlı ilerleme; Kilit Ekranında `.privacySensitive()` maskelemesi ve `ConfirmActivePlanLiveIntent` / `CancelActivePlanLiveIntent` / `InterruptSpeechLiveIntent`.
  - StandBy modunda `@Environment(\.isLuminanceReduced)` ile AOD düşük parlaklık + canlı geri sayım (`Text(targetDate, style: .timer)`).
- **Control Center (`ControlWidget`) & Action Button / Vocal Shortcuts:**
  - `JarvisVoiceControlWidget` (`QuickVoiceJarvisIntent`, `.foreground(.immediate)`), `MorningBriefingControlWidget` (`.requiresLocalDeviceAuthentication`) ve `JarvisStatusToggleControl`.
  - `IAgentShortcutsProvider` içine `"Jarvis Dinle"` (sıfır gecikmeli ses yakalama), `"iAgent Sabah Brifingi"`, `"iAgent Acil Alarm"` eklenir; `OnboardingView` `ShortcutsLink()` ve `SiriTipView` içerir.
- **AlarmKit (iOS 26), AirPods & Apple Watch:**
  - `alarm.create` (`AlarmManager.shared.schedule`, `NSAlarmKitUsageDescription` yeterli — özel portal entitlement gerektirmez!).
  - AirPods `.allowBluetoothHFP` rota bekleme + gövde dokunuşu (`MPRemoteCommandCenter.togglePlayPauseCommand`) ile konuşma kesme.
  - Apple Watch Smart Stack yansıtması (`.supplementalActivityFamilies([.small, .medium])`) ve tam companion için `WatchConnectivity` (`WCSession`, çünkü App Group iPhone↔Watch arasında çalışmaz).
- **Ücretsiz Sideload vs Ücretli İmza Gerçeği:**
  - `iAgent-Sideload.ipa` içinde `PlugIns` çıkarıldığı için `AlarmKit`, Action Button, Vocal Shortcuts ve AirPods %100 çalışır; ancak `App Groups`, `Siri` yetkisi ve `iAgentWidgetExtension` / `iAgentShareExtension` tam çalışması için ücretli Apple Developer (\$99/yıl) veya 2-hedefli (`iAgent` + `iAgentWidgetExtension`) AltStore/SideStore profili gerekir (`aps-environment` ücretsiz derlemede eklenmemelidir!).

---
## 10. Tam Çift Yönlü Ses ve JARVIS Persona (`JARVIS Voice & Persona Specialist`)

- **Boşluk Özeti:** `SpeechSessionController` şu an mikrofonu sentez sırasında kilitliyor (half-duplex), `AVAudioApplication.requestRecordPermission()` istemiyor, `AskIAgentIntent` tek turdan sonra Siri oturumunu kapatıyor ve `az-AZ` için Türkçe TTS/ASR köprüsü sunmuyor.
- **Tam Çift Yönlü Ses Hattı (`FullDuplexAudioPipeline.swift`):**
  - `AVAudioEngine` Voice Processing I/O (VPIO donanım AEC: `inputNode` + `outputNode.setVoiceProcessingEnabled(true)`) ile `AVAudioPlayerNode` üzerinden çalan TTS sesini mikrofondan gerçek zamanlı çıkarır.
  - 500 ms *pre-roll* halka tamponu (ilk hece kesilmez), 220 ms AEC yakınsama maskesi, 2 aşamalı *barge-in* (`0.15` ses kısma → `EchoSimilarityFilter` doğrulamalı kesme).
- **Kademeli ASR & Çevrimdışı Ses Sürekliliği (`SpeechRecognitionEngine.swift` & `OfflineVoiceContinuityManager.swift`):**
  - iOS 26 `SpeechAnalyzer` + `SpeechTranscriber` (`.volatileResults`) + `SpeechDetector` (VAD) birincil motoru; varlık yoksa `SFSpeechRecognizer` (`requiresOnDeviceRecognition`) yedek yolu.
  - TTS için `.premium > .enhanced > .default` kalite sıralaması + 400 ms tampon watchdog ile çevrimdışı kesintisiz ses devamlılığı + DSP ile üretilen 60 ms VPIO-referanslı earcon sesleri.
- **JARVIS Persona & Takip Penceresi (`Packages/AgentCore/Voice/`):**
  - `JarvisPersonaPreset` (`.butler` kahya üslubu vs `.executive` telgraf özeti) ve `JarvisResponseComposer` (makbuz gerçeklerini bozmadan `displayText` / `spokenText` üretir).
  - `WakeContextSession` (45 sn kayan pencere, `"Hey Siri"` demeden `"Evet"`, `"İkinciyi çıkar"`, `"Yarım saat ileri al"` gibi devam komutlarını `ConversationalFollowUpResolver` ile bağlar).
  - `TurkicVoiceTextProcessor` & `AzerbaijaniPhoneticBridge` (`ə→e`, `q→k`, `x→h` yalnızca TTS sesine uygulanır, ekran/not metni bozulmaz).

---

## Önceliklendirilmiş Uygulama Yol Haritası (v1.1 → v2.0)

| Faz | Odak | Başlıca Kapsanan Uzman Tasarımları |
|---|---|---|
| **Faz A · Çekirdek Güvenlik, Akıllı Hafıza & Bağlam** | `MemoryVault` + `BiometricGate` + `CryptographicAuditTrail` + `GoalPlanRevision`/Saga temeli | Uzman #2, #4, #8 |
| **Faz B · Hibrit Yapay Zekâ Beyni & Çift Yönlü Ses** | `HybridModelRouter` (Apple + DeepSeek + OpenAI Responses + Anthropic Messages) + `FullDuplexAudioPipeline` + `JarvisPersona` | Uzman #3, #10 |
| **Faz C · Proaktif JARVIS, Çok Modlu Zekâ & Ekosistem** | Sabah/Akşam brifingi, `MKDirections` ETA, VisionKit/PDFKit fiş/bilet/kartvizit boru hattı, Focus/HomeKit/MusicKit/CarPlay + Çift Yönlü Kestirmeler | Uzman #1, #6, #7 |
| **Faz D · iPhone Donanım Yüzeyleri & Spatial HUD** | Dynamic Island / `ActivityKit`, Control Center `ControlWidget`, StandBy HUD, `AlarmKit`, AirPods HFP/stem, `JarvisStatusOrbView` & `StepReceiptTimelineView` | Uzman #5, #9 |
