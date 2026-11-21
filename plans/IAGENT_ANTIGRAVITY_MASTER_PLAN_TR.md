# iAgent · Siri ile çalışan iPhone kişisel asistanı

**Antigravity için ürün ve uygulama planı · 21 Kasım 2026**

## 1. Antigravity’ye verilecek görev

Bu belgenin tamamını geliştirme talimatı olarak kullan. iAgent, kullanıcının Siri’ye veya uygulamanın içine söylediği günlük bir isteği anlayan, iPhone’un sunduğu yeteneklerle yerine getiren ve ne olduğunu doğru bildiren kişisel asistandır. Kullanıcı uygun iPhone’da Apple Intelligence ile anahtar girmeden başlayabilmeli, isterse kendi model sağlayıcısını bağlayabilmelidir. Kişisel kullanım için bir bilgisayar, sürekli açık sunucu veya iAgent hesabı gerekmemeli.

Doğrudan ilk çalışan akışı geliştir. Gerçek bir iPhone’da Siri’den uygulamayı çağır, söylenen cümleden bir not oluştur ve uygulama yeniden açıldığında aynı notu göster. Önce bu zinciri kanıtla. Sonra aynı çekirdeğe takvim, anımsatıcılar, iletişim taslakları ve kullanıcı kestirmelerini ekle. Bu belgedeki isimler çalışma adlarıdır. Yeni bir oturumda son çalışan aşamayı ve test kanıtlarını okuyarak devam et.

**Ürünün hedef deneyimi**

> **Kullanıcı:** “Siri, iAgent ile konuş.”  
> **iAgent:** “Ne yapmamı istersin?”  
> **Kullanıcı:** “Yarın 10’da Deniz’le 45 dakikalık toplantı ekle. Yarım saat önce sunumu açmamı hatırlat. Deniz’e de mesaj hazırla.”  
> **iAgent:** “Yarın 10.00–10.45 için takvim kaydı ve 09.30 için anımsatıcı hazırladım. İkisini kaydedeyim mi?”  
> **Kullanıcı:** “Evet.”  
> **iAgent:** “Toplantı ve anımsatıcı kaydedildi. Mesajı kime göndermek istediğini seçebilirsin.”

Son adımda iPhone mesaj düzenleyicisini açar. Kullanıcı vazgeçerse sonuç kartında iki kayıt ve iptal edilen taslak görünür. Örnekte Deniz adını etkinlik başlığına yazmak bir davet göndermez. Tarih, saat dilimi ve kişi seçimleri telefonda görülür. Görevin gerektirdiği takip soruları aynı konuşmanın içinde kalır.

## 2. iPhone’da üç ayrı katman

| Katman | Üstlendiği iş | İlk sürüm kararı |
|---|---|---|
| Siri ve App Intents | iAgent’i çağırır, isteği alır, kısa yanıtı sunar veya uygulamayı ön plana getirir. | `AppShortcutsProvider` ile yayımlanan yerelleştirilmiş çağrı ve eksik serbest metin için takip sorusu. Aynı giriş uygulamada bas-konuş ve klavyeyle de çalışır. |
| Model | İsteği ve gerekli parametreleri çözer, eksik bilgiyi sorar, kayıtlı eylemlerden plan önerir. | Apple Foundation Models ve bir gerçek harici sağlayıcı. Her görevde hangi model yolunun kullanıldığı görünür. |
| iAgent ve iOS | Planı denetler, izinleri ve onayı alır, ilgili Apple API’sini veya tanımlı kestirmeyi çağırır, sonucu kaydeder. | Her eylemin gerçek bir yürütücüsü ve ölçülebilir bir sonucu vardır. Sesli yanıttaki fiil bu sonuçtan üretilir. |

iOS’ta başka bir uygulamanın yayımladığı tüm App Intent’leri üçüncü taraf bir asistanın doğrudan çağırabileceği genel bir API bulunmuyor. Uygulamalar arası düzenlemeyi Siri ve Kestirmeler yapabiliyor. Bu nedenle “telefonda yapabildiğim her iş” hedefini, her iş için gerçek erişim yolunu gösteren bir yetenek kataloğuyla büyüt. Başka bir uygulamanın ekranını okuyup düğmelerine dokunmayı gerektiren işte desteklenen kestirme, paylaşım veya kullanıcıya devretme yolunu göster. [Apple mühendislerinin çapraz uygulama açıklaması](https://developer.apple.com/videos/play/wwdc2026/8011/?time=498)

**Sesle başlatma seçenekleri.** Kurulum ekranı kişinin kendi cihazında doğrulayacağı Siri ifadesini gösterir. Özel bir “Jarvis” çağrısı isteyen kullanıcı, desteklenen cihazda iOS’un **Sesli Kestirmeler** ayarından seçtiği ifadeyi iAgent kestirmesine bağlayabilir. Eylem Düğmesi olan cihazlarda aynı kestirme düğmeye atanabilir. İki seçenek de kullanıcı tarafından yapılandırılır. İlk kullanım ve kilitli ekran davranışı fiziksel cihazda denenir. [Apple App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts) · [Sesli Kestirmeler](https://support.apple.com/guide/iphone/use-vocal-shortcuts-iph7f242ea2c/ios) · [Eylem Düğmesi](https://support.apple.com/guide/shortcuts/run-shortcuts-with-the-action-button-apdfea15680b/ios)

## 3. İlk sürümün yetenek kataloğu

| Kullanıcının sözü | Uygulamanın yapacağı iş | Başarıyı gösteren kanıt |
|---|---|---|
| “Şunu not al…” / “Dün yazdığım alışveriş notunu bul.” | iAgent içinde not oluşturur ve yerel arama yapar. Oluşturmayı geri alma seçeneği verir. Apple Notlar’a kaydetmek ayrıca seçilebilen, kullanıcının kurduğu bir kestirmedir. | Kalıcı not kimliği, uygulama yeniden açıldığında aynı içerik. |
| “Bugün programım nasıl?” | Takvim okuma izniyle cihazın saat dilimindeki günün kayıtlarını getirir. İzin yoksa nedeni gösterir. | EventKit’ten dönen başlık ve saatler. Sıfır sonuç, izin reddi ve okuma hatası farklı görünür. |
| “Cuma 15.00’e 30 dakikalık çalışma ekle.” | Tarih aralığını gösterip onayla kaydeder. Yalnız yazma izninde iOS’un varsayılan takvimini kullanır. Başka bir takvim seçmek isteyen kullanıcı sistem etkinlik editöründe seçebilir. | EventKit kaydının veya editörün kaydet/iptal sonucu. Yalnız yazma izniyle takvimleri listelemeye veya kaydı geri okumaya çalışılmaz. |
| “Bugün 19.00’da şarj aletini almamı hatırlat.” | Zaman bazlı anımsatıcı oluşturur. Tarih, saat dilimi ve listeyi doğrular. Başlangıç ve son tarih bileşenleriyle birlikte istenen saate bir `EKAlarm` koyar. İlk sürümde konuma bağlı istek gelirse zaman seçme veya kurulu kestirme yolunu sunar. | Ayrı Anımsatıcılar izniyle kaydedilmiş kayıt ve doğru zamana ayarlanmış alarm. [Apple’ın anımsatıcı örneği](https://developer.apple.com/tutorials/app-dev-training/saving-reminders) |
| “Deniz’e ‘On dakika gecikeceğim’ diye mesaj hazırla.” / “Bunu e-posta yap.” | Kullanıcının seçtiği alıcı ve metinle sistem düzenleyicisini açar. Gönderme işlemini kullanıcı tamamlar. Cihazda gönderim yapılandırmasını önceden kontrol eder. | Düzenleyicinin gönder/iptal/hata sonucu. Alıcıya teslim durumu bilinmiyorsa ekranda bu durumdan söz edilmez. |
| “Bunu WhatsApp’ta paylaş.” / “Deniz’i ara.” | Metni paylaşım sayfasına verir. WhatsApp mevcutsa kişi hedefi seçer. Telefon aramasında seçilen numarayı sistem arama onayına devreder. | Paylaşım sayfası veya arama arayüzü açıldı. Sohbet geçmişine erişim ve görüşmenin bağlanması bu işlemlerin çıktısı değildir. |
| “Bakü Garı’na yol tarifi aç.” | Belirsiz yer adında seçenek sorar. Doğrulanmış hedefi ve ulaşım türünü Haritalar’a aktarır. Yalnız hedefi açmak için konum izni istemez. | Haritalar’a devir sonucu ve seçilen hedef. |
| “Çalışma modumu başlat.” | Kullanıcının önceden bağladığı ve sınadığı adlı kestirmeyi çağırır. Odak, desteklenen ev veya müzik eylemlerini kullanıcı Kestirmeler’de düzenleyebilir. | Kestirme dönüşü, iptal, hata veya dönüş bekleniyor. Harici etkiler için yalnız doğrulanabilen sonucu söyler. |
| “Bunu özetle ve not al.” | Paylaş menüsünden verilen metni veya kullanıcının açıkça seçtiği metin dosyasını alır. İlk sürüm UTF-8 metin ve boyut sınırıyla başlar. | Kullanıcının seçtiği girdi, önizlenmiş özet ve yeni not kimliği. |
| “Bu mesajı daha nazik nasıl söylerim?” / “Onu biraz kısalt.” | Serbest soruya veya önceki yanıta bağlı düzenleme isteğine yanıt verir. Kullanıcı isterse sonucu daha sonra not veya taslağa dönüştürür. | Yanıt/öneri ayrı görünür. Sırf yanıt üretildi diye bir telefon işlemi başlatılmaz. |

Takvim okuma, takvim yazma ve anımsatıcı izinleri ayrı istenir. Kişi seçiminde tek alıcıyı seçtiren sistem arayüzü tercih edilir. Apple Notlar için genel CRUD API’sine dayanılmaz. Paylaşım eklentisinde ağır model işini çalıştırmak yerine seçilen metin App Group alanına alınır ve ana uygulama açıldığında bekleyen girdi olarak sunulur. [EventKit](https://developer.apple.com/documentation/eventkit/accessing-the-event-store) · [Sistem mesaj ve e-posta arayüzü](https://developer.apple.com/documentation/messageui) · [Apple Notes hakkında Apple DTS yanıtı](https://developer.apple.com/forums/thread/813810) · [Haritalar](https://developer.apple.com/documentation/mapkit/mkmapitem)

## 4. Model seçimi ve dil

İlk açılışta uygulama Apple’ın cihaz modelini sorgular. Cihaz, sistem ayarı, hazır model varlıkları ve görev dili uygunsa **“Apple Intelligence · Bu iPhone”** seçilir. API anahtarı veya iAgent hesabı gerekmez. Uygun değilse gerekçeyi göster. Kullanıcı aynı ekrandan harici sağlayıcı bağlayabilir veya sabit yerel komutlarla başlayabilir. Bir model hazırlanıyorsa daha sonra yeniden kontrol et. [Apple SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)

| Kullanıcı tercihi | Yürütme |
|---|---|
| Otomatik | Uygun olduğunda cihazdaki Apple modelini kullanır. Cihaz yolu kapalıysa önceden ayrıca izin verilmiş sağlayıcıyı teklif eder. İlk kez buluta veri göndermeden önce sağlayıcı, veri türleri ve kapsam açıkça gösterilir. |
| Yalnız bu iPhone | Model yerelde kullanılabiliyorsa yerel çıkarım yapılır. Model yoksa “Not ekle”, “Bugünkü ajandam” gibi sabit eylemler doğrudan kullanılabilir. iAgent model verisini ağ üzerinden göndermez. Siri’nin kendi ses işleme koşulları Apple tarafından ayrıca yönetilir. |
| Kendi sağlayıcım | İlk sürümde DeepSeek hazır profili ve Chat Completions araç çağrılarıyla uyumlu özel HTTPS uç noktası sunulur. Kullanıcı adres, model kimliği ve kendi anahtarını girer. Deneme, kişisel veri olmadan gerçek bir araç çağrısının ayrıştırılabildiğini doğrular. Anahtar seçilen sunucuya bağlanır. İstemci, farklı sunucuya yönlendirmede anahtarı iletmez. Başka sağlayıcıya geçiş kullanıcının seçimiyle yapılır. |

Swift tarafında `ModelProvider` arabirimi yetenek sorgulama, yanıt/plan üretme, iptal ve yapılandırılmış hata döndürür. Apple tarafında `SystemLanguageModel`, `LanguageModelSession` ve yapılandırılmış üretim, harici tarafta `URLSession` ve sağlayıcının belgelenmiş araç çağrıları kullanılır. Çekirdek çıktıyı kullanıcıya yanıt, açıklama sorusu, katalogdan tipli plan veya desteklenmeyen istek olarak ayırır. Takvim kaydetme ve mesaj paylaşma gibi yan etkiler iAgent yürütücüsünden geçer. Model kesilirse eksik JSON yürütülmez. Modelin güvenlik reddi başka sağlayıcıya otomatik gönderilmez. Anahtarı kaldırma, değiştirme ve yeniden sınama desteklenir. [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels) · [DeepSeek araç çağrıları](https://api-docs.deepseek.com/guides/tool_calls/)

**Dil kararı.** İlk arayüz ve sesli kabul seti Türkçe. Azerbaycanca metin girişi ve varsa kullanıcının seçtiği sağlayıcıyla uçtan uca görev seti de plana dahildir. Sistem sesi, Siri tetiklemesi ve modelin dili ayrı yeteneklerdir. Apple’ın genel Apple Intelligence listesinde Türkçe yer alır. Yeni Siri AI özelliklerinin dil ve bölge kapsamı ayrıca yayımlanır. Türkçe veya Azerbaycanca için destek rozeti gerçek cihazda o giriş yoluyla test geçince gösterilir. Kullanıcı arayüz dili, istek dili, saat dilimi ve yer adları ayrı tutulur. “Sabah doqquzda”, “öbür cuma” gibi ifadeler birden fazla yoruma açıksa mutlak tarih ve saati sor. [Apple Intelligence uygunluğu](https://support.apple.com/en-us/121115) · [Siri AI uygunluğu](https://support.apple.com/en-us/127893) · [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)

**Sürüm kapsamı.** İlk hedef iOS 26 ve üzeri. Apple Intelligence donanımı olmayan ama hedef iOS sürümünü çalıştıran cihazda harici sağlayıcı ve sabit komut yolları denenir. iOS 27 Private Cloud Compute ayrı bir ağ modeli ve yönetilen yetki gerektirir. İleride kullanılırsa ayrı bir tercih ve uygunluk denetimi eklenir. Apple’ın 3 Kasım 2026’da geliştirici önizlemesi olarak duyurduğu geniş Siri AI entegrasyonu ayrı deneysel aşamadır. Temel sesli akışı yayımlanmış App Shortcuts yoluyla teslim et. [Private Cloud Compute erişimi](https://developer.apple.com/private-cloud-compute/) · [Apple’ın Siri AI geliştirici duyurusu](https://developer.apple.com/news/?id=gdk2umrf)

## 5. Uygulama akışı ve ekranlar

1. **İlk açılış.** “Bu iPhone’da dene” ile gerçek bir örnek not oluşturulur. Model durumu ve “Sağlayıcı bağla” görünür. Ardından Siri ifadesini deneme düğmesi ve isteğe bağlı Sesli Kestirme kurulumu gösterilir. Takvim, kişiler veya mikrofon izinleri ilgili özelliğe ilk dokunuşa kadar ertelenir.
2. **Ana ekran.** Büyük “Konuş” düğmesi, yazı alanı, aktif model ve son görev. Dinlerken canlı yazı, durdur ve düzelt. Kısa yanıtlar uygulamada sistemin konuşma senteziyle, Siri akışında `IntentDialog` ile okunur. İkisi aynı anda konuşmaz. Kullanıcı yanıtı kesip yeni söz alabilir. Ses veya konuşma iznini reddederse yazı alanı çalışır. Uygulama kendi sesli yanıtını yeniden komut olarak algılamamalı.
3. **Konuşma ve plan.** Tek basit istekte kısa yanıt. Çok adımlı işte sırayla eylem, hedef kişi/uygulama, kesin zaman ve durum. Gereksiz açıklama yerine yalnız eksik parametre sorulur. “İkinciyi çıkar”, “onu 11’e al”, “vazgeç” mevcut bekleyen plana uygulanır. Değişen planın eski onayı geçersiz olur.
4. **Onay ve uygulamaya geçiş.** Kısa ve izin verilen iş Siri içinde sonlanabilir. Kişi seçimi, kilit açma, mesaj editörü ve büyük bir plan ekran gerektiriyorsa aynı görev kimliğiyle iAgent’e geçilir. Kullanıcı girdiği isteği tekrarlamaz. Mikrofon, Siri üzerinden gelen istek için uygulama tarafından ayrıca açılmaz.
5. **Geçmiş.** “Ne yaptın?” sorusu gerçek kayıtları getirir. Başarılı, kısmen tamamlandı, iptal edildi, kullanıcı işlemi bekleniyor ve sonucu bilinmiyor durumları ayrılır. Bir iş açıldığında hangi adımların tamamlandığı ve neyin hâlâ yapılabileceği görünür.
6. **Yetenekler ve ayarlar.** Her eylemde “Hazır”, “İzin gerekli”, “Kestirme kurulmalı” veya “Bu cihazda kullanılamıyor” durumu ve deneme yolu. Model, dil, ses, geçmişi temizleme, kayıt süresi, harici veri iznini geri çekme ve anahtar silme buradadır. VoiceOver etiketleri, Dynamic Type, sesli yanıt için metin karşılığı ve tek elle erişim ilk tasarıma girer.

## 6. Teknik mimari ve veri

Swift, SwiftUI, App Intents, Foundation Models, EventKit, MessageUI, MapKit, ContactsUI, Speech/AVFoundation ve Keychain kullan. İlk sürüm tek iOS uygulaması, bir paylaşım eklentisi ve saf Swift paketleriyle kurulabilir. Yerel görev, not ve makbuzlar için SwiftData kullan. Ana uygulama ve App Intent aynı yürütme çekirdeğine girsin. Paylaşım eklentisi yalnız korunan bir gelen kutusuna yazar. Windows’taki çalışma klasöründen kaynak kodu yönetilebilir. Xcode derleme, simülatör ve imzalama çalışmaları uyumlu bir Mac veya macOS CI gerektirir. Siri ve Apple cihaz modeli için fiziksel iPhone testi planla. [Apple Xcode uyumluluğu](https://developer.apple.com/xcode/system-requirements)

```text
Siri / App Shortcut     Uygulama içi ses veya yazı     Paylaşılan metin
        └──────────────────────────┬───────────────────────────┘
                              İstek ve oturum
                                     ↓
                Model seçimi → Tipli plan → Parametre doğrulama
                                     ↓
                    Yetki, mahremiyet ve kullanıcı onayı
                                     ↓
          Yerel not / EventKit / Mesaj editörü / Harita / Kestirme
                                     ↓
                     Adım makbuzu → Ekran veya sesli sonuç
```

| Önerilen yer | Sorumluluk |
|---|---|
| `Apps/iAgent/`, `Extensions/Share/` | Ekranlar, App Intent girişleri, yaşam döngüsü, erişilebilirlik, seçilmiş metni alma. |
| `Packages/AgentCore/` | İstek, plan, parametre, yetenek, durum makinesi, onay, iptal, sonuç. Apple UI ve sağlayıcı SDK’larından bağımsız. |
| `Packages/ModelProviders/` | Apple cihaz modeli, DeepSeek hazır profili, uyumlu özel uç nokta ve deterministik test sağlayıcısı. Üretim yapılandırması test sağlayıcısını seçemez. |
| `Packages/PhoneActions/` | Tipli eylem kataloğu, iOS izinleri, sistem API’leri, kestirme köprüsü, gerekiyorsa ön plan sunucusu. |
| `Tests/Scenarios/`, `docs/verification/` | Türkçe/Azerbaycanca örnekler, sahte saat ve geçitler, fiziksel cihazda doğrulanan sürüm ve sonuçlar. |

**Saklanacak nesneler.** `Task` görev kimliği, kaynak, seçilen dil/model ve durum taşır. `PlanRevision` revizyon ve sıralı adımları saklar. `ActionStep` eylem türü, denetlenmiş parametreleri, bağımlılıkları, onay gereksinimi ve durumunu içerir. `ActionReceipt` yürütücüyü, işlem sonucunu, güvenle saklanabilecek nesne kimliğini ve zamanı tutar. `ShortcutBinding` kullanıcı etiketi, tam kestirme adı, kabul edilen giriş ve son test sonucunu saklar. Gizli anahtarlar bu tablolarda tutulmaz.

**Örnek plan.** Aşağıdaki sabit tarih yalnız test verisidir. Modelin önerdiği değerler ayrıştırılır, plan kimlikleri uygulama tarafından atanır. Mesaj metni herhangi bir etkinliğin kaydedildiğini iddia ediyorsa önce ilgili kayıt başarıyla sonuçlanmalıdır.

```json
{
  "steps": [
    {"id": "a", "action": "calendar.create", "title": "Deniz ile toplantı", "start": "2026-11-22T10:00:00+04:00", "durationMinutes": 45},
    {"id": "b", "action": "reminders.create", "title": "Sunumu aç", "due": "2026-11-22T09:30:00+04:00", "dependsOn": ["a"]},
    {"id": "c", "action": "messages.compose", "recipientQuery": "Deniz", "body": "Yarın 10.00 için toplantıyı takvimime ekledim.", "dependsOn": ["a"]}
  ]
}
```

**Yürütme kuralları**

- Katalog her eylem için parametre şeması, cihaz/izin koşulu, veri hassasiyeti, onay biçimi, geri alınabilirlik ve kanıt türü tanımlar. Bilinmeyen eylem, döngüsel bağımlılık, geçersiz tarih veya kapsam dışı URL yürütülmez. İlk sürüm bir isteği en çok sekiz adıma ayırır. Daha büyük istek kullanıcıyla bölünür.
- Model mümkünse “yarın”, “Deniz” gibi ifadeleri aday olarak çıkarır. Çekirdek cihazın tarih, takvim ve saat dilimiyle kesinleştirir. Kişi adı tek başına gönderim adresi olmaz. Aynı isimli iki kişi varsa telefon numarasını veya adresi kullanıcı seçer. Nihai planın özeti uygulamanın doğruladığı değerlerden yazılır.
- Onay kuralı eylemin türünden gelir. Kullanıcının açıkça istediği tek bir yerel not yazılabilir ve geri alınabilir. Yetkili, kilidi açılmış cihazda salt okuma hemen sonuç verebilir. Takvim ve anımsatıcı yazımları için değişiklik özeti onaylanır. Adı bağlı bir kestirmenin içeriği kullanıcı tarafından daha sonra değiştirilebildiğinden, çalıştırmadan önce adı ve gönderilecek girdi gösterilir. Mesaj gönderimini ve aramayı sistem arayüzü tamamlar. Genel bir “evet” gelecekteki işlemlere yetki vermez.
- Durum akışı `alındı → açıklama/onay bekliyor → yürütülüyor → sonuç`. Adımların ayrıca `kullanıcı arayüzünde`, `iptal`, `hata`, `belirsiz` ve `bağımlılık nedeniyle atlandı` durumları vardır. İptal sonraki adımları durdurur. Tamamlanan dış işlemler tek tek görünür. Geri alma, yalnız uygulama güvenilir biçimde tanıdığı ve izinle geri çevirebildiği kayıt için sunulur.
- Onay görev, plan revizyonu, adım kimlikleri, hedef ve içerik özetiyle ilişkilidir. Çift dokunma, yinelenen Siri isteği veya ön plana geçişte aynı görev için tek yürütme hakkı vardır. Birbirinden bağımsız iki yeni konuşmayı sırf sözleri aynı diye birleştirme. Sisteme yazıp makbuz alınamadan uygulama kapanırsa kanıt varsa uzlaştır, aksi halde “sonuç doğrulanamadı” göster ve kullanıcı seçimine kadar işlemi tekrarlama.
- Arka planda kısa bir intent tamamlanamazsa durumunu yaz, ön planda devam ettir. Sonsuz dinleme, kilitliyken sınırsız yürütme veya kesintisiz model bağlantısını temel alma. Yeni görev başlatma, var olan göreve devam etme ve sorgulama ayrı girişlerdir.

## 7. Gizlilik, yetki ve sağlayıcı kullanımı

- Kilit ekranından gelen genel komut ile kişisel takvimi okuyan veya dışarıya gönderim hazırlayan komutu ayır. Serbest istekli girişte hassas veriye erişmeden önce iOS’un cihaz doğrulamasını iste veya kilit açılarak uygulamaya devir yap. Kilit ekranındaki bildirim veya sesli önizlemede kişi ve toplantı içeriğini varsayılan olarak gizle. [Apple App Intent doğrulaması](https://developer.apple.com/documentation/appintents/intentauthenticationpolicy/requireslocaldeviceauthentication)
- Sağlayıcıya bağlantı ekranında hangi alanların gönderileceğini örnekle göster. İlk tercih yalnız komut metnidir. Rehber çözümleme, takvim aralığı sorgusu ve makbuzdan sesli yanıt üretimini olabildiğince cihazda yap. Takvim içeriğinin, notun veya paylaşılan metnin dışarıda özetlenmesi ek kapsam ister. İzni geri çekince sonraki istekte ağ çağrısı yapılmamalı. Sağlayıcı değişince tercih yeniden alınır. [Apple App Review §5.1.2](https://developer.apple.com/app-store/review/guidelines/)
- Kişisel sağlayıcı anahtarı Keychain’de cihazla sınırlı erişimle saklanır. Uygulamaya geliştiriciye ait ortak anahtar gömülmez. Üretim günlüklerinde komutun tam metni, kişi, not, ham ses veya anahtar bulunmaz. Ses kaydı varsayılan olarak tutulmaz. Yerel görev geçmişi için başlangıç tercihi 30 gün ve “Geçmişi tutma” seçeneğidir. Kalıcı iAgent notları geçmiş silme işleminden ayrı gösterilir.
- Paylaşılan belge, web metni ve kestirme dönüşü veri olarak işlenir. İçlerinden çıkan talimatlar yeni eylem veya izin oluşturamaz. Kestirme adı kullanıcı tarafından eşlenir, modelin ürettiği bir adres doğrudan açılmaz. Kestirme köprüsüne sır veya toplu kişisel kayıt taşıma. Dönüşü tek kullanımlık istekle eşleştir. Dönüş gelmemesi, sistemin başka bir uygulamada ne yaptığına dair kesin sonuç vermez. [Kestirme çalıştırma](https://support.apple.com/guide/shortcuts/apd624386f42/ios) · [Kestirme geri çağrıları](https://support.apple.com/guide/shortcuts/apdcd7f20a6f/ios)
- Harici sağlayıcıda istek boyutu, süre, tur ve yanıt sınırı uygulanır. Kullanıcı bir işlem sürerken iptal edebilir. Hatalı anahtar, bağlantı yokluğu, hız sınırı ve bakiye hatası ayrı gösterilir. Ölçülebilen kullanım saklanabilir. Fiyat verisi doğrulanmamışsa parasal tutar gösterilmez.

## 8. Antigravity’nin uygulama sırası

Her satırı bağımsız incelenebilir bir değişiklik olarak teslim et. Fiziksel donanım veya sağlayıcı anahtarı yoksa o deneyi “bekliyor” olarak kaydet, bağımsız geliştirmeye devam et. Her aşama sonuna çalışan sürüm, komut, gerçek sonuç ve eksik kalan cihaz kanıtını yaz.

| Aşama | Bağımlılık | Çıktı | Tamamlanma ölçütü |
|---|---|---|---|
| 0 · Ortam ve Siri deneyi | Başlangıç | SwiftUI projesi, iOS 26 hedefi, macOS derleme yolu, Türkçe çağrı ve tek String parametreli App Shortcut. | İmzalı geliştirme sürümü gerçek iPhone’da çağrılır. Siri’nin aldığı söz ve uygulamaya geçiş doğrulanır. |
| 1 · İlk uçtan uca iş | 0 | Siri/yazı → sabit “not al” eylemi → yerel kalıcı not → kısa yanıt. | Uygulamayı kapatıp açınca not görünür. Kullanıcı vazgeçince not oluşmaz. |
| 2 · Ajan çekirdeği | 1 | Eylem şemaları, plan revizyonu, izin/onay geçidi, adım makbuzları, tek yürütme, yarım kalan iş kurtarma. | Sahte saatle senaryolar, çift onay ve belirsiz sonuç testleri geçer. |
| 3 · İki model yolu | 2 | Apple cihaz modeli, DeepSeek hazır profili, uyumlu özel uç nokta, kurulum ve sağlayıcı izin ekranı. | Fiziksel destekli iPhone’da yerel çıkarım, kendi anahtarıyla harici çıkarım, veri izni reddinde sıfır dış çağrı. Her iki model yolundan da gerçek bir not üretilir. Özel URL profili ayrıca şema yanıtı ve hatalı modelle denenir. |
| 4 · Kişisel düzenleyici | 2 | Takvim okuma/ekleme, anımsatıcı, göreli tarih ve çok adımlı plan. | Gerçek Takvim ve Anımsatıcılar uygulamalarında doğru gün/saat ve yalnız bir kayıt görünür. Kısmi başarısızlık doğru okunur. |
| 5 · İletişim ve Haritalar | 2 | Kişi seçimi, mesaj/e-posta düzenleyicisi, paylaşım, arama ve rota açma. | Gönder/iptal/hata ve sistem arayüzüne geçiş farklı sonuç verir. Fiziksel cihazda mesaj iptali test edilir. |
| 6 · Kestirmeler ve paylaşım | 2 | Kestirme bağlama, deneme ve geri çağrı, metin paylaşım eklentisi, Sesli Kestirme ve Eylem Düğmesi kurulumu. | Kullanıcının oluşturduğu bir kestirme çalışır. Silinmiş/yeniden adlandırılmış kestirme, iptal ve dönmeyen çağrı doğru görünür. Paylaşılan metin gerçek bir nota dönüşür. |
| 7 · Sesli kişisel asistan | 3–6 | Uygulama içi bas-konuş, metin düzeltme, konuşmayı kesme, okunabilir geçmiş, VoiceOver, Türkçe ve Azerbaycanca değerlendirmeleri. | Bölüm 9’daki çok adımlı senaryo Siri’den tamamlanır. Ağ kesintisi, kilit ekranı ve izin reddi ayrı ayrı doğrulanır. |
| 8 · Kişisel beta ve dağıtım | 7 | İmzalı cihaz sürümü, hata tanılama, gizlilik ekranı, derleme talimatları ve isteğe bağlı TestFlight paketi. | Yeni kurulumda başka biri belgeye bakarak ilk görevini tamamlar. Yayına gidecek sürüm için cihaz sonuçları, izin metinleri, gerçek veri akışı ve App Store beyanları eşleşir. |

2. aşamadaki şema sabitlenince 3–6 ayrı dallarda geliştirilebilir. İlk birleştirme hedefi Apple/harici model ve takvimin birlikte çalışmasıdır. Her aşamada geri dönüş noktası son doğrulanmış sürümdür. Bozuk bir entegrasyon yalnız ilgili yetenek üzerinden kapatılabilir. Temel not ve yazı girişi çalışmaya devam eder.

## 9. Doğrulama ve teslim

| Deneme | Beklenen ölçülebilir sonuç |
|---|---|
| **Siri’den günlük iş** · Sabit saat 21 Kasım 2026, Asia/Baku. Bölüm 1’deki sözü ver. | 22 Kasım 10.00–10.45 etkinliği ve 09.30 anımsatıcısı oluşur. Mesaj taslağını iptal edince ilk iki kayıt korunur. Yeniden açılışta makbuzlar durumla eşleşir. |
| **Modeli ve interneti ayır** · Model varlıkları hazır iPhone’da uçak moduna geç, uygulama içi yazılı bir not iste. | Apple model yoluyla gerçek not oluşur, iAgent dış model isteği üretmez. Siri’nin ağ gereksinimi ayrı testte raporlanır. |
| **Model yok** · Apple Intelligence kapalı veya desteklenmiyor. Kullanıcı harici sağlayıcıyı sonradan bağlar. | İlk durumda sabit not işlevi çalışır. İkinci durumda seçilen sağlayıcı komutu çözer. Yetkisiz harici veri aktarımı sıfırdır. |
| **Ses ve dil** · Türkçe iki turlu Siri çağrısı, uygulama içi bas-konuş, mikrofon reddi ve Azerbaycanca yazılı “Sabah saat doqquzda mənə xatırlat”. | Yer, zaman ve eylem denetlenir. Son örnekte neyin hatırlatılacağı sorulur. Desteklenmeyen ses/dil birleşimi yazıya yönlendirir. |
| **Belirsizlik ve düzenleme** · İki Deniz kaydı, “cuma akşamı”, ardından “etkinliği yarım saat ileri al”. | Kişi ve gerekiyorsa saat seçilir. Yeni plan gösterilir, eski plan onayıyla iş yapılamaz. |
| **Kesinti** · Onaya iki kez dokun, sistem editöründeyken çık, kayıt anında süreci kapat, sonra tekrar aç. | Aynı adım otomatik yinelenmez. Sonucu kanıtlanamayan işlem kullanıcıya belirtilir. |
| **Kilit ve izin** · Kilitliyken özel ajandayı sor. Takvim iznini reddet, sonra yalnız yazma izniyle tekrar dene. | Kilit açılmadan özel içerik okunmaz. Yazma izniyle gündem okunmaz. İzin reddi boş ajanda gibi görünmez. |
| **Kestirme ve dürüst sonuç** · Kestirmeyi yeniden adlandır, geri çağrıyı iptal et ve kurulu olmayan paylaşım hedefini iste. | Başarı uydurulmaz. Uygun manuel yol veya yeniden bağlama sunulur. |
| **Paylaşılan içerik** · “Bu belgeyi özetle” girdisinin içine mesaj gönderme talimatı da ekle. | Yalnız kullanıcının istediği özet hazırlanır. Model kaynak belgedeki metinden yeni eylem başlatamaz. |

Saf çekirdek için `swift test --package-path Packages/AgentCore` çalıştır. Xcode projesine ortak `iAgent` şeması ekle. CI’da `xcodebuild -list -project Apps/iAgent/iAgent.xcodeproj` ve `xcodebuild -showdestinations -project Apps/iAgent/iAgent.xcodeproj -scheme iAgent` ile hedefi doğrula, kurulu simülatörün kimliğiyle `xcodebuild test` çalıştır. Siri yolunda ilk intent eksik metin parametresini sistem aracılığıyla ister. Daha fazla etkileşim gerektiğinde sistem diyaloğunu veya aynı görevi ön planda açmayı gerçek cihazda doğrula. Aynı test kümesinde sabit saat, redakte edilmiş sağlayıcı örnekleri ve sahte sistem arayüzleri kullanılabilir. **Gerçek sistem sonucunu** fiziksel cihazda Takvim/Anımsatıcılar kaydı, uygulama verisi, editör dönüşü veya kestirme dönüşüyle ayrıca doğrula. Geliştirme cihazının modeli, iOS sürümü, sistem/Siri dili ve kullanılan sağlayıcı her sesli test kaydında yer alsın.

İlk beta seti 10 tek adımlı, 10 çok adımlı, 5 belirsiz ve 5 destek dışı Türkçe komuttan oluşur. En az 27’sinde doğru plan, takip sorusu veya destek dışı sonucu beklenir. Yanlış alıcıya devir, onaysız dış eylem, gizli veri aktarımı ve sahte başarı sayısı sıfır olmalıdır. Azerbaycanca için 10 ayrı metin örneğinin sonucu kendi satırında raporlanır. Yanıt süresini her cihaz ve model yolu için ölçüp raporla.

**Teslim paketi** kaynak projeyi, derleme ve cihazda kurulum talimatını, imzalı sürümü veya TestFlight derlemesini, kullanıcının sağlaması gereken hesap ve imza yetkilerinin listesini, doğrulanmış yetenek matrisini ve bilinen sınırlamaları içerir. TestFlight/App Store tercih edilirse güncel SDK şartlarını, gizlilik beyanlarını, üçüncü taraf AI paylaşım iznini ve inceleme için çalışan demo yolunu kontrol et. Kişisel cihaz kurulumu ilk kullanılabilir teslimdir. [Apple TestFlight](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/) · [Apple inceleme kuralları](https://developer.apple.com/app-store/review/guidelines/) · [SDK gereksinimleri](https://developer.apple.com/news/upcoming-requirements/)

## 10. İlk sürümden sonra JARVIS deneyimini genişletme

| Sıra | Özellik | Açılış koşulu |
|---|---|---|
| 1 | **Kişisel rutinler ve hafıza.** “Sabah brifingim” seçilmiş takvim ve anımsatıcıları tek sesli yanıtta toplar. “Bunu hatırla” ile kullanıcı onaylı tercih kaydedilir. Düzenleme ve silme ekrandadır. | Aynı çağrı iki kez iletilirse işlem bir kez yapılır. Kullanıcı kaydedilmiş tercihin hangi sözünden geldiğini görebilir. |
| 2 | **Daha çok telefon işi.** AlarmKit ile iAgent alarmları, seçilmiş fotoğraf veya belgeyi özetleme, müzik ve ev rutinleri. Önce belirli API/izin veya doğrulanmış kullanıcı kestirmesi seçilir. | Her yetenek için yetkili gerçek cihazda başarılı örnek ve izin reddi örneği gösterilir. [Apple AlarmKit](https://developer.apple.com/documentation/alarmkit) |
| 3 | **Yeni model protokolleri.** İhtiyaca göre OpenAI Responses veya Anthropic Messages için bağımsız adaptör ve doğrulanmış profiller. | Aynı plan, araç, iptal ve mahremiyet testlerini geçer. Kişisel anahtar ve sunucu tarafından finanse edilen kullanım farklı yapılandırılır. |
| 4 | **Yeni Siri AI entegrasyonu.** Uygulamanın uygun eylemlerini desteklenen şemalarla sisteme aç. | Kullanıcının bölgesi, dili, kararlı iOS sürümü ve dağıtım yolu resmen desteklendiğinde etkinleştirilir. |

Codex’ten oturum ve onay akışını, Antigravity’den incelenebilir planı, OpenCode’dan sağlayıcı değişimini, OpenClaw’dan yetenek ve izin ayrımını, DeepSeek Harness’tan araçlarla çalışan görev döngüsünü örnek al. iPhone’da yapılacak işin kaynağı yukarıdaki eylem kataloğudur. Bu ürünlerin masaüstü yazılımlarını kurmak ilk sürümün önkoşulu değildir. [Codex App Server](https://developers.openai.com/codex/app-server/) · [Google Antigravity](https://antigravity.google/docs/overview) · [OpenCode](https://opencode.ai/docs/api) · [OpenClaw](https://docs.openclaw.ai/gateway/protocol) · [DeepSeek Harness](https://www.deepseek.com/en/harness/)
