# iAgent Repository Rules (Windows → Codemagic macOS/iOS 26)

## Ortam ve Uzak Derleme Gerçeği
- Bu çalışma alanı Windows üzerindedir; yerel makinede `swift` ve `xcodebuild` bulunmaz. Tüm Swift/iOS derleme ve simülatör test doğrulamaları Codemagic (`Mac mini M2`, `Xcode 26.6`, `IPHONEOS_DEPLOYMENT_TARGET=26.0`, workflow: `ios-sideload-and-tests`) üzerinden alınır.
- Uzak Codemagic derlemesi başlatıldığında veya itildiğinde kullanıcıdan onay/tetikleme beklemeden `schedule` zamanlayıcısı ile durumu takip et; yeşil derleme + `.ipa` çıktısı doğrulanana veya kullanıcı etkileşimi gerektiren bir engel çıkana kadar döngüyü otonom sürdür.

## Push Öncesi Zorunlu Yerel Kapı
- `git push` öncesinde daima `python scripts/verify_all.py` çalıştır ve tüm kontrollerin (`Structure & Security Checks`, `Chapter 9 Scenarios`, `Turkish Beta Dataset`, `Azerbaijani Dataset`, `Safety Violations = 0`) geçtiğini doğrula.

## `project.pbxproj` ve SwiftPM Değişmezleri
- `Apps/iAgent/iAgent.xcodeproj/project.pbxproj` elle düzenleniyorsa Xcode nesne `isa` tiplerini eksiksiz ve doğru kullan: `XCLocalSwiftPackageReference`, `XCSwiftPackageProductDependency`, `XCBuildConfiguration`, `XCConfigurationList`.
- `Packages/*/Package.swift` dosyalarında desteklenen platform tanımlarını (`platforms: [.macOS(.v15), .iOS(.v18)]`) koru.

## Swift 6 Concurrency & XCTest Kuralları
- Swift 6 katı eşzamanlılık modunda `XCTAssertEqual(...)`, `XCTAssertTrue(...)` gibi `@autoclosure` tabanlı makro ifadelerinin içine doğrudan `await` yazma; önce `let sonuc = await ...` ile yerel sabite al, sonra doğrula.

## Çift `.ipa` Paketleme Politikası
- `codemagic.yaml` içindeki çift paketleme ayrımını koru: ücretsiz Apple ID ile Windows Sideloadly/AltStore kurulumu için `PlugIns/` çıkarılmış `iAgent-Sideload.ipa` ve eklentileri içeren `iAgent-Full.ipa` birlikte üretilmelidir.
