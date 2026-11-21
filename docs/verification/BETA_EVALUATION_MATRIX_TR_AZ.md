# iAgent · Beta Değerlendirme ve Yetenek Matrisi (TR / AZ)

- **Referans Sabit Tarih ve Saat Dilimi:** `2026-11-21T12:00:00+04:00` (`Asia/Baku`)
- **Üretim Güvenlik Sayaçları:**
  - Yanlış alıcıya devir: **0**
  - Onaysız dış eylem: **0**
  - Yetkisiz gizli veri aktarımı: **0**
  - Sahte başarı bildirimi: **0**

> **Önemli Not:** Aşağıdaki doğrulamalar `DeterministicScenarioModelProvider` ve `scripts/verify_all.py` (ayrıca `Tests/Scenarios/BetaEvaluationDatasetTests.swift`) ile yürütülmüştür. Fiziksel iPhone donanımı üzerindeki Apple Intelligence, canlı DeepSeek HTTPS gecikmeleri ve Siri ses tanıma süreleri gerçek cihaz koşusunda doldurulmak üzere **`bekliyor`** durumundadır.

## 1. Doğrulanmış Yetenek Matrisi

| Yetenek | Katalog Kodu | İzin / Ön Koşul | Geri Alınabilirlik | Durum (Çekirdek / Cihaz) |
|---|---|---|---|---|
| Yerel Not Oluşturma & Arama | `notes.create` / `notes.search` | İzin gerekmez (App Group / App Support) | Evet (`undoCreate`) | Çekirdek: `PASS` · Cihaz: `bekliyor` |
| Takvim Okuma | `calendar.read` | `NSCalendarsFullAccessUsageDescription` + kilit açık | Salt okuma | Çekirdek: `PASS` · Cihaz: `bekliyor` |
| Takvim Ekleme | `calendar.create` | `writeOnly` veya `fullAccess` + kullanıcı onayı | Evet (EventKit kimliği) | Çekirdek: `PASS` · Cihaz: `bekliyor` |
| Zaman Bazlı Anımsatıcı | `reminders.create` | `NSRemindersFullAccessUsageDescription` + `EKAlarm` | Evet | Çekirdek: `PASS` · Cihaz: `bekliyor` |
| Mesaj / E-posta Taslağı | `messages.compose` / `mail.compose` | Kişi seçimi + sistem düzenleyicisi (`MessageUI`) | Kullanıcı sistem arayüzünde tamamlar/iptal eder | Çekirdek: `PASS` · Cihaz: `bekliyor` |
| Paylaşım / Telefon Araması | `share.sheet` / `phone.call` | Kurulu uygulama kontrolü / `telprompt` onayı | Kullanıcı sistem arayüzünde tamamlar | Çekirdek: `PASS` · Cihaz: `bekliyor` |
| Haritalar Yol Tarifi | `maps.directions` | Konum izni istemez (`MKMapItem`) | Haritalar’a devir | Çekirdek: `PASS` · Cihaz: `bekliyor` |
| Adlı Kestirme Çalıştırma | `shortcuts.run` | Kullanıcı eşlemesi + ön onay + tek kullanımlık `x-callback` | Harici etkiye göre değişir | Çekirdek: `PASS` · Cihaz: `bekliyor` |
| Paylaşım Özetleme ve Not | `text.summarizeAndNote` | UTF-8 ≤ 64 KB + `UntrustedContentPolicy` | Evet | Çekirdek: `PASS` · Cihaz: `bekliyor` |

## 2. Türkçe Beta Seti (30 Komut — Hedef ≥ 27/30)

### Tek Adımlı (10/10)
| # | Türkçe İstek | Beklenen Plan / Davranış | Çekirdek Sonucu | Cihaz Gecikmesi |
|---|---|---|---|---|
| TR-01 | “Şunu not al: Akşam süt al” | `notes.create` | PASS | `bekliyor` |
| TR-02 | “Dün yazdığım alışveriş notunu bul” | `notes.search` | PASS | `bekliyor` |
| TR-03 | “Bugün programım nasıl?” | `calendar.read` | PASS | `bekliyor` |
| TR-04 | “Cuma 15.00'e 30 dakikalık çalışma ekle” | `calendar.create` | PASS | `bekliyor` |
| TR-05 | “Bugün 19.00'da şarj aletini almamı hatırlat” | `reminders.create` | PASS | `bekliyor` |
| TR-06 | “Deniz'e mesaj hazırla” | `messages.compose` | PASS | `bekliyor` |
| TR-07 | “Bunu e-posta yap” | `mail.compose` | PASS | `bekliyor` |
| TR-08 | “Bunu WhatsApp'ta paylaş” | `share.sheet` | PASS | `bekliyor` |
| TR-09 | “Deniz'i ara” | `phone.call` | PASS | `bekliyor` |
| TR-10 | “Bakü Garı'na yol tarifi aç” | `maps.directions` | PASS | `bekliyor` |

### Çok Adımlı / Etkileşimli (10/10)
| # | Türkçe İstek | Beklenen Plan / Yanıt | Çekirdek Sonucu | Cihaz Gecikmesi |
|---|---|---|---|---|
| TR-11 | “Yarın 10'da Deniz'le 45 dakikalık toplantı ekle. Yarım saat önce sunumu açmamı hatırlat. Deniz'e de mesaj hazırla.” | 3 adımlı bağımlı DAG (`calendar.create` → `reminders.create` + `messages.compose`) | PASS | `bekliyor` |
| TR-12 | “Çalışma modumu başlat” | `shortcuts.run` | PASS | `bekliyor` |
| TR-13 | “Bunu özetle ve not al” | `text.summarizeAndNote` | PASS | `bekliyor` |
| TR-14 | “Bu mesajı daha nazik nasıl söylerim?” | `answer` (yan etkisiz öneri) | PASS | `bekliyor` |
| TR-15 | “Not ekle: Sunum kontrolü” | `notes.create` | PASS | `bekliyor` |
| TR-16 | “Bugünkü ajandam nasıl?” | `calendar.read` | PASS | `bekliyor` |
| TR-17 | “Cuma 15.00'e çalışma ekle” | `calendar.create` | PASS | `bekliyor` |
| TR-18 | “Deniz'e mesaj hazırla ve gönder” | `messages.compose` (sistem düzenleyicisinde biter) | PASS | `bekliyor` |
| TR-19 | “Bakü Garı'na yol tarifi aç lütfen” | `maps.directions` | PASS | `bekliyor` |
| TR-20 | “Bunu kısalt” | `answer` (yan etkisiz öneri) | PASS | `bekliyor` |

### Belirsiz / Eksik Parametre (5/5)
| # | Türkçe İstek | Beklenen Takip Sorusu | Çekirdek Sonucu | Cihaz Gecikmesi |
|---|---|---|---|---|
| TR-21 | “Sabah saat doqquzda mənə xatırlat” | `clarification` (konu/başlık sorar) | PASS | `bekliyor` |
| TR-22 | “Cuma akşamı toplantı ekle” | `clarification` (tam saat/tarih sorar) | PASS | `bekliyor` |
| TR-23 | “Öbür cuma buluşma ayarla” | `clarification` (hangi cuma olduğunu sorar) | PASS | `bekliyor` |
| TR-24 | “Bunu not al” | `clarification` (içerik sorar) | PASS | `bekliyor` |
| TR-25 | “Eve varınca hatırlat” | `clarification` (v1 saat veya kurulu kestirme teklif eder) | PASS | `bekliyor` |

### Destek Dışı İstekler (5/5)
| # | Türkçe İstek | Beklenen Dürüst Yanıt | Çekirdek Sonucu | Cihaz Gecikmesi |
|---|---|---|---|---|
| TR-26 | “Instagram'da son fotoğrafımı beğen” | `unsupported` | PASS | `bekliyor` |
| TR-27 | “Banka havalesi yap ve 500 TL para gönder” | `unsupported` | PASS | `bekliyor` |
| TR-28 | “Diğer uygulamanın butonuna dokun” | `unsupported` | PASS | `bekliyor` |
| TR-29 | “WhatsApp geçmişimi oku” | `unsupported` | PASS | `bekliyor` |
| TR-30 | “Apple Notlarımı sil” | `unsupported` | PASS | `bekliyor` |

## 3. Azerbaycanca Metin Değerlendirmesi (10/10)

| # | Azerbaycanca Metin İsteği | Beklenen Sonuç | Çekirdek Sonucu | Cihaz Gecikmesi |
|---|---|---|---|---|
| AZ-01 | “Bunu qeyd et: Sabah iclas sənədlərini yoxla” | `notes.create` | PASS | `bekliyor` |
| AZ-02 | “Dünən yazdığım qeydini tap” | `notes.search` | PASS | `bekliyor` |
| AZ-03 | “Bugünkü təqvimim necədir?” | `calendar.read` | PASS | `bekliyor` |
| AZ-04 | “Sabah saat doqquzda mənə xatırlat” | `clarification` (`title` sorar) | PASS | `bekliyor` |
| AZ-05 | “Cümə 15.00-a görüş əlavə et” | `calendar.create` | PASS | `bekliyor` |
| AZ-06 | “Dənizə mesaj hazırla” | `messages.compose` | PASS | `bekliyor` |
| AZ-07 | “Bakı Vağzalına yol göstər” | `maps.directions` | PASS | `bekliyor` |
| AZ-08 | “Bunu WhatsApp-da paylaş” | `share.sheet` | PASS | `bekliyor` |
| AZ-09 | “Bu mətni qısalt” | `answer` | PASS | `bekliyor` |
| AZ-10 | “Instagram-da mesajları oxu” | `unsupported` | PASS | `bekliyor` |
