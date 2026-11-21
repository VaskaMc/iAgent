# iAgent · Gizlilik, İzin Metinleri ve App Store Beyanları

## 1. Veri Akışı ve Gizlilik İlkesi

| Veri Türü | Cihaz İçi Mod (`Otomatik` / `Yalnız bu iPhone`) | Harici Sağlayıcı (`Kendi sağlayıcım` — Kullanıcı İzinliyse) | Saklama Yeri ve Süresi |
|---|---|---|---|
| Komut metni | Yalnız iPhone içi bellek / `SystemLanguageModel` | Yalnız kullanıcının açık onayıyla seçtiği HTTPS uç noktasına gönderilir | Varsayılan görev geçmişi **30 gün** (veya `"Geçmişi tutma"`) |
| Yerel notlar | Cihazda App Group / App Support JSON deposu | Ek kapsam izni verilmedikçe dışarı gönderilmez | Kalıcıdır; geçmiş silme işleminden ayrıdır |
| Takvim ve Anımsatıcılar | EventKit cihaz içi sorgu/yazım | Adres/rehber çözümlemesi cihazda kalır; ek kapsam olmadıkça gönderilmez | Sistem Takvim / Anımsatıcılar + görev makbuzu kimliği |
| API Anahtarları | Kullanılmaz | Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) içinde seçilen `host` ile eşli | Yalnız cihaz Keychain; yönlendirmede başka sunucuya iletilmez |
| Ham Ses | `SpeechTranscriber` cihaz içi dikte | Ham ses **hiçbir zaman** ağa gönderilmez ve diske kaydedilmez | Bellekte anlık; işlem bitince atılır |
| Tanılama Günlükleri | `RedactingLogger` | Komut, kişi, not, telefon, e-posta ve anahtarlar maskelenir | Yalnız görev ID ve eylem durum kodu |

## 2. `Info.plist` İzin Açıklamaları ile Gerçek Kullanım Eşleşmesi

- `NSSiriUsageDescription`: Siri App Shortcut ile komut alma.
- `NSCalendarsFullAccessUsageDescription`: Yalnız kullanıcının takvimini okumak istediği komutlarda (`calendar.read`).
- `NSCalendarsWriteOnlyAccessUsageDescription`: Takvime yeni etkinlik eklerken (`calendar.create`).
- `NSRemindersFullAccessUsageDescription`: Zaman bazlı anımsatıcı ve `EKAlarm` eklerken (`reminders.create`).
- `NSContactsUsageDescription`: Aynı adlı kişiler arasında tek alıcı seçimi için (`ContactResolver`).
- `NSMicrophoneUsageDescription` & `NSSpeechRecognitionUsageDescription`: Yalnız uygulama içi “Konuş” düğmesine dokunulduğunda istenir; Siri çağrısında veya ilk açılışta istenmez.

## 3. Apple App Review §5.1.2 Üçüncü Taraf AI Veri Paylaşımı Uyumu

- Kullanıcı **“Apple Intelligence · Bu iPhone”** veya **“Sabit Yerel Komutlar”** ile çalışırken hiçbir üçüncü taraf AI sunucusuna veri gitmez.
- Kullanıcı ilk kez harici bir sağlayıcıya (DeepSeek veya özel HTTPS uç noktası) bağlanırken `ExternalDataConsentManager` şu bilgileri açıkça gösterir ve onay alır:
  1. Sağlayıcının adı ve tam alan adı (`host`),
  2. Paylaşılacak veri kapsamı (varsayılan: `Yalnız komut metni`),
  3. Örnek JSON yükü.
- Kullanıcı onayı geri çektiğinde sonraki istekte ağ çağrısı sayısı **sıfırdır (`0`)**. Sağlayıcı değiştirildiğinde izin sıfırlanır.

## 4. Bilinen Sınırlamalar (İlk Sürüm v1.0)

1. Üçüncü taraf uygulamaların UI ekranına dokunma veya sohbet geçmişini (ör. WhatsApp mesajları, Apple Notlar arşivi) doğrudan okuma desteklenmez; yalnız sistem paylaşım sayfası veya kullanıcının kurduğu adlı Kestirmeler üzerinden çalışır.
2. Konuma bağlı anımsatıcılar ilk sürümde doğrudan EventKit coğrafi çit olarak oluşturulmaz; kullanıcıya saat seçimi veya kurulu Kestirme önerilir.
3. Azerbaycanca sesli dikte cihaz içi `SpeechTranscriber` desteği olmayan sistemlerde otomatik olarak yazılı girişe yönlendirilir.
4. Kilitli ekranda hassas kişisel veriler (takvim okuma, dış iletişim taslağı) cihaz kilidi açılmadan yürütülmez.
