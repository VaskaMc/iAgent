---
name: ios-jarvis-engineering
description: >-
  Swift 6 strict concurrency, iOS 26 AppIntents, SwiftUI HUD, EventKit/Maps/Speech,
  Zero-Trust security, and Codemagic Xcode 26.6 packaging standards for iAgent JARVIS builders.
---

# iAgent JARVIS Engineering Skill (Swift 6 · iOS 26 · Codemagic M2)

Authoritative engineering guide for developing the `iAgent` personal assistant across `Packages/AgentCore`, `Packages/ModelProviders`, `Packages/PhoneActions`, `Apps/iAgent`, `Extensions/*`, and `Tests/Scenarios`.

Derived from open-source Swift/iOS agent skills (`twostraws/swift-concurrency-agent-skill`, `avdlee/Swift-Concurrency-Agent-Skill`, `pchelnikov/swift-6-agent-skill`, `dpearson2699/swift-ios-skills`, `FloWritesCode/fwc-swiftui-skills`) and bound to `iAgent`'s hard CI and security invariants.

---

## 1. Environment, Build Matrix & Pre-Push Gate

- **Host vs. Build Reality:** Workspace runs on Windows (no local `swift` or `xcodebuild`). Every Swift/iOS compile and test runs remotely on Codemagic (`mac_mini_m2`, `Xcode 26.6`, workflow `ios-sideload-and-tests`) and GitHub Actions (`macos-26`).
- **Two Separate Build Targets in CI:**
  1. **macOS SwiftPM CLI Tests** (`swift test --package-path Packages/AgentCore`, `ModelProviders`, `PhoneActions`): compiles against `macOS` (`platforms: [.macOS(.v15), .iOS(.v18)]`).
  2. **iOS Simulator & Release `iphoneos` Build** (`xcodebuild test` + `xcodebuild build -sdk iphoneos` on `Apps/iAgent/iAgent.xcodeproj`, `IPHONEOS_DEPLOYMENT_TARGET = 26.0`, `SWIFT_VERSION = 6.0`, `CODE_SIGNING_ALLOWED=NO`).
- **Mandatory Pre-Push Local Gate:** Always run `python scripts/verify_all.py` before pushing; confirm `Structure & Security Checks: PASS`, `9/9` Chapter 9 scenarios, `30/30` TR + `10/10` AZ dataset, and `0` safety violations.

---

## 2. Package Layering & Conditional Compilation Invariants

| Layer | Allowed Imports | Forbidden Imports |
|---|---|---|
| `Packages/AgentCore` | `Foundation`, `CryptoKit` (`XCTest` in tests) | `UIKit`, `SwiftUI`, `SwiftData`, `NaturalLanguage`, `EventKit`, `LocalAuthentication`, `Security`, `Vision`, `AlarmKit`, `HomeKit`, `MusicKit` |
| `Packages/ModelProviders` | `Foundation`, `AgentCore`, optional `#if canImport(FoundationModels)`, `#if canImport(Security)`, `#if canImport(CryptoKit)` | `UIKit`, `SwiftUI`, iOS-only hardware frameworks |
| `Packages/PhoneActions` | `Foundation`, `AgentCore`, guarded system frameworks (`EventKit`, `Contacts`, `MapKit`, `LocalAuthentication`, `Vision`, `MusicKit`, `PDFKit`, `CoreImage`, `ImageIO`) | Unguarded iOS-only frameworks (`UIKit`, `MessageUI`, `ContactsUI`, `AlarmKit`, `HomeKit`, `ActivityKit`, `WidgetKit`, `BackgroundTasks`, `AVAudioSession`, `VisionKit`, `WatchConnectivity`) |
| `Apps/iAgent` & `Extensions/*` | Full iOS 26 / SwiftUI / AppIntents / WidgetKit / AVFoundation stack | Hardcoded secrets (`sk-...`), private UI automation |

### Platform & Availability Rules for `Packages/*`
1. **Never alter `platforms: [.macOS(.v15), .iOS(.v18)]`** in any `Package.swift`.
2. **Guard iOS-only frameworks strictly** with `#if os(iOS) && canImport(<Framework>)` (e.g., `AlarmKit`, `HomeKit`, `UIKit`, `MessageUI`, `ContactsUI`, `AVAudioSession`, `VisionKit`, `BackgroundTasks`, `ActivityKit`, `WatchConnectivity`). Without `#if os(iOS)`, `swift test` on Codemagic macOS M2 fails.
3. **Guard iOS 26+ / macOS 26+ APIs** (`FoundationModels`, `SpeechAnalyzer`, `SpeechTranscriber`, `SpeechDetector`, `RecognizeDocumentsRequest`, `AlarmManager`) with `#if compiler(>=6.2)` and runtime `if #available(iOS 26.0, *)` (or `if #available(iOS 26.0, macOS 26.0, *)` when cross-platform).
4. **Protocol-first Testability:** Every OS backend (`EventKit`, `AlarmKit`, `HomeKit`, `MusicKit`, `LocalAuthentication`, `Vision`, `AVAudioEngine`, `BGTaskScheduler`) must expose a `Sendable` protocol in `AgentCore` or `PhoneActions` with deterministic `InMemory*` / `Mock*` implementations for macOS SwiftPM & Simulator CI tests.

---

## 3. Swift 6 Strict Concurrency & XCTest Discipline

1. **Sendable Value Types:** Model records, receipts, envelopes, and errors crossing isolation boundaries must be `Sendable` value types (`struct`/`enum`) or `actor`-isolated.
2. **Synchronization:** Use `actor` for async state machines (`HybridModelRouter`, `CircuitBreakerRegistry`). For synchronous locks on `.macOS(.v15), .iOS(.v18)`, prefer `Synchronization.Mutex` or `NSLock.withLock` over unsynchronized mutable state; only use `@unchecked Sendable` when every mutable field is proven lock-guarded.
3. **Actor Reentrancy Rule:** Never assume actor properties remain unchanged across an `await` suspension point. Re-read/revalidate state after every `await` (e.g., circuit breaker state, lease checks, token budgets).
4. **MainActor UI & Audio Delegates:** Isolate `@Observable` UI models, `AppCoordinator`, `SpeechSessionController`, and `AppIntent.perform()` state mutations to `@MainActor`. Bridge background `AVSpeechSynthesizerDelegate` / `AVAudioEngine` / `WKNavigation` / `SFSpeechRecognitionTask` callbacks safely via `nonisolated` methods dispatching `Task { @MainActor [weak self] in ... }`.
5. **Structured Concurrency:** Prefer `withTaskGroup` and `async let` (e.g., `JarvisSpecialistSwarm`) over detached tasks; check `Task.isCancelled` / `try Task.checkCancellation()` in loops and SSE streams.
6. **Swift 6 XCTest `@autoclosure` Rule:** Never place `await` directly inside `XCTAssertEqual`, `XCTAssertTrue`, `XCTAssertNil`, or `XCTAssertThrowsError` (Swift 6 rejects `async` inside synchronous `@autoclosure`). Always bind first:
   ```swift
   let result = await executor.querySchedule(for: date, timeZone: tz, isDeviceLocked: false)
   XCTAssertEqual(result, .emptySchedule)

   do {
       _ = try await router.routeAndGenerate(request: req, preference: .automatic)
       XCTFail("Expected error")
   } catch let error as ModelProviderError {
       XCTAssertEqual(error, .consentRequired)
   }
   ```

---

## 4. iOS 26 Foundation Models, AppIntents & Speech Engine

### Apple `FoundationModels` (`SystemLanguageModel` 4,096-Token Budget)
- Always check `SystemLanguageModel.default.availability` and thermal state before inference; treat `az` locale fallback explicitly if unsupported on-device.
- Respect the strict **4,096-token** context budget (`contextSize` / `tokenCount(for:)`). Apply a 15% safety margin for Turkish/Azerbaijani agglutinative BPE expansion via `TurkicHeuristicTokenEstimator`.
- Keep `@Generable` schemas and tool descriptions minimal; compact conversation history (`JarvisContextCompactor`) before creating a fresh `LanguageModelSession`.
- Never execute partial/truncated tool calls: validate `finish_reason` (`stop`/`tool_calls` only; reject `length`/`max_tokens`/`incomplete`) and accumulate SSE deltas in raw `Data` to prevent multi-byte UTF-8 splits.

### `AppIntents`, Control Center, Live Activities & Shortcuts
- Use `#if compiler(>=6.2)` `static let supportedModes: IntentModes` (`[.background, .foreground(.dynamic)]`, or `.foreground(.immediate)` only when launching live voice capture).
- Do not invoke `continueInForeground` during CarPlay / driving states; respect `IntentAuthenticationPolicy.requiresLocalDeviceAuthentication` for locked-device sensitive intents (`MorningBriefingControlWidget`, private schedule/memory reads).
- Keep `IAgentShortcutsProvider` phrases localized in Turkish (`tr`) and concise (`"Jarvis Dinle"`, `"iAgent ile Konuş"`).
- Mirror Live Activities to Apple Watch Smart Stack via `.supplementalActivityFamilies([.small, .medium])` in `ActivityConfiguration`; mask lock-screen sensitive payloads with `.privacySensitive()`.

### Speech (`SpeechAnalyzer` / `VPIO` / `AVAudioSession`) & `AlarmKit`
- **Double Permission Gate:** Request both `AVAudioApplication.requestRecordPermission()` and `SFSpeechRecognizer.requestAuthorization` only on in-app voice interaction (never on onboarding or Siri handoffs).
- **Simulator Safety:** Never start `AVAudioEngine` / VPIO (`setVoiceProcessingEnabled(true)`) unconditionally in `init()` or unit tests. Wrap behind an injectable audio pipeline protocol and catch hardware setup failures cleanly on iOS Simulator.
- **Asset Check First:** When using `SpeechTranscriber` + `SpeechDetector` + `SpeechAnalyzer`, verify `SpeechTranscriber.supportedLocale(equivalentTo:)` and `AssetInventory` availability; fall back to `SFSpeechRecognizer(requiresOnDeviceRecognition: true)` or text input for `az-AZ`, applying `AzerbaijaniPhoneticBridge` solely to spoken TTS output (never mutating stored notes).
- **`AlarmKit` (`AlarmManager.shared`):** Declare `NSAlarmKitUsageDescription` in `Apps/iAgent/Info.plist`; requires no paid portal entitlement and works in both `iAgent-Full.ipa` and `iAgent-Sideload.ipa`.

---

## 5. SwiftUI Liquid Glass HUD & Accessibility

- Use dark-first adaptive surfaces paired with native `.ultraThinMaterial` and iOS 26 Liquid Glass (`GlassEffectContainer(spacing:)` + `.glassEffect(_:in:)`). Wrap iOS 26 glass modifiers in an `#available(iOS 26.0, *)` ViewModifier helper with `.ultraThinMaterial` fallback.
- Respect `@Environment(\.accessibilityReduceMotion)`: disable continuous orb/wave animations and morphing transitions when enabled, rendering a crisp static indicator.
- Respect `@Environment(\.isLuminanceReduced)` in StandBy / Always-On Live Activity views (hide high-frequency waveform updates; use `Text(targetDate, style: .timer)`).
- Enforce >= 44x44 pt hit targets, `.monospacedDigit()` on countdowns/timestamps, `ViewThatFits` for `AX5` Dynamic Type in bottom thumb-zone docks, and `accessibilityAction(named:)` rotor actions on plan steps.

---

## 6. EventKit, Maps, Vision & Smart Home Boundaries

- **Long-Lived Store:** Keep a single `EKEventStore` instance per backend (never re-instantiate per call).
- **Strict `.writeOnly` Isolation:** Under `CalendarAuthorizationState.writeOnly`, never call `predicateForEvents` or list calendars, and never synthesize an "empty schedule" — return `.writeOnlyCannotReadSchedule`.
- **No Unconsented Location:** `MapsActionExecutor` and `MapDisambiguationCard` resolve places via `MKLocalSearch` and `MKDirections.calculateETA()` without demanding `CLLocationManager` permission unless the user explicitly enables departure-from-current-location ETA.
- **Memory-Safe Extensions (< 120 MB):** `ShareViewController` must never load full-resolution images or ML models into memory. Downsample via `CGImageSourceCreateThumbnailAtIndex` (`maxPixelSize: 2048`), strip GPS/EXIF metadata, enforce `SharedMediaLimits` (images <= 10 MB, PDF <= 20 MB / 20 pages), and write to App Group `group.com.iagent.shared` with `FileProtectionType.complete`.
- **CarPlay / Driving Safety:** Gate visual composers, mail, and home security lock/alarm mutations with `DrivingSafetyPolicy` (`.deferredForDrivingSafety`), keeping spoken responses <= 160 characters.

---

## 7. Zero-Trust Security, Canonical Approval & Audit Integrity

- **Canonical Digest (`CanonicalApprovalDigest`):** Hash `taskId`, `revisionNumber`, `dependsOn`, and ALL `ActionParameters` fields using length-prefixed, type-tagged canonical encoding (`nil` != `""` != `0`). Any plan edit, time shift, reflection patch, or candidate selection (`selectContactCandidate`) MUST invalidate the previous `PlanRevision`, increment `revisionNumber`, and recompute `approvalDigest`.
- **Tiered Biometric Gate (`LocalAuthentication`):** Use a fresh `LAContext` per `tier3BiometricRequired` action (`touchIDAuthenticationAllowableReuseDuration = 0`) producing an HMAC-SHA256 `BiometricAttestation` bound to `(taskId, revisionNumber, approvalDigest)`.
- **Atomic Keychain & Disk Protection:** Update Keychain items atomically via `SecItemUpdate` -> fallback `SecItemAdd` using `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (never `UserDefaults`). Persist local vaults, WAL, leases, and audit logs with `.completeFileProtection` and `cloudKitDatabase: .none`.
- **SSRF & SPKI Pinning:** `StrictEndpointValidator` rejects `http://`, localhost, `.local`, and RFC1918/link-local private IPs; `PinnedHTTPSDelegate` validates SPKI SHA-256 pins and blocks cross-host redirects (`RedirectBlockingSessionDelegate`).
- **Prompt Injection Defense & Secret Guards:** Strip Unicode BiDi/Tag control chars and hidden HTML (`PromptInjectionSanitizer`), enforce `UntrustedContentPolicy` action allowlists on shared docs/OCR/shortcut outputs, and reject IBAN/TCKN/PAN/JWT/API keys in `MemorySecretGuard`, `ArtifactSecretGuard`, and `RedactingLogger`.
- **Immutable Audit Chain & Saga:** Chain every `ActionReceipt` / compensation entry in `CryptographicAuditTrail` with SHA-256 + HMAC-SHA256 (`verifyIntegrity() -> Bool`). On critical step failure, compensate undoable steps in LIFO order via `SagaCompensationEngine` and report external UI handoffs honestly as `.notUndoableExternally` — never fabricate success.

---

## 8. `project.pbxproj`, Extensions & `verify_all.py` Rules

1. **Exact Xcode `isa` Sections:** Every `/* Begin <Section> section */` in `Apps/iAgent/iAgent.xcodeproj/project.pbxproj` must contain ONLY `isa = <Section>;` entries (`XCLocalSwiftPackageReference`, `XCSwiftPackageProductDependency`, `XCBuildConfiguration`, `XCConfigurationList`, etc.).
2. **Target & Path Sync (`verify_all.py` trap!):** `scripts/verify_all.py` validates every `path = <file>.swift;` reference in `project.pbxproj` against `[Apps/iAgent, Apps/iAgent/Intents, Apps/iAgent/Speech, Apps/iAgent/Views, Apps/iAgent/Diagnostics]` (or explicit `../../` paths). If adding Swift files in new subfolders (e.g., `Apps/iAgent/HUD/` or `Extensions/Widget/`), either use explicit relative `path = HUD/File.swift` without group `path` attribute OR update `verify_all.py`'s candidate path resolver in the same PR.
3. **Secret Scan Rule:** Never place literal strings matching `"sk-[A-Za-z0-9]{12,}"` anywhere in non-`Tests/` `.swift` files (not even in comments or previews).
4. **Dual `.ipa` Packaging (`codemagic.yaml`):** Preserve `iAgent-Full.ipa` (includes `PlugIns/`) and `iAgent-Sideload.ipa` (`rm -rf .../PlugIns` for free Apple ID Sideloadly/AltStore). Never add `aps-environment` to `iAgent.entitlements`; keep `Localizable.xcstrings` `sourceLanguage = "tr"` and `IPHONEOS_DEPLOYMENT_TARGET = 26.0;`.
