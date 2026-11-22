import Foundation
import CryptoKit
import AgentCore

#if os(iOS) && canImport(AlarmKit) && canImport(SwiftUI)
import AlarmKit
import SwiftUI
#endif

#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

#if os(iOS) && canImport(HomeKit)
import HomeKit
#endif

#if canImport(Intents)
import Intents
#endif

#if os(iOS) && canImport(MusicKit)
import MusicKit
#endif

// MARK: - 1. Sabah / Akşam Brifing Sentezleyicisi (BriefingSynthesizer)

public struct MorningBriefingReport: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let language: AgentLanguage
    public let calendarPermissionBlockedReason: String?
    public let scheduleEvents: [CalendarEventRecord]
    public let openReminders: [ReminderRecord]
    public let estimatedTravelMinutes: Int?
    public let conflictWarningsTR: [String]
    public let markdownSummary: String
    public let spokenSummary: String

    public init(
        generatedAt: Date,
        language: AgentLanguage,
        calendarPermissionBlockedReason: String? = nil,
        scheduleEvents: [CalendarEventRecord] = [],
        openReminders: [ReminderRecord] = [],
        estimatedTravelMinutes: Int? = nil,
        conflictWarningsTR: [String] = [],
        markdownSummary: String,
        spokenSummary: String
    ) {
        self.generatedAt = generatedAt
        self.language = language
        self.calendarPermissionBlockedReason = calendarPermissionBlockedReason
        self.scheduleEvents = scheduleEvents
        self.openReminders = openReminders
        self.estimatedTravelMinutes = estimatedTravelMinutes
        self.conflictWarningsTR = conflictWarningsTR
        self.markdownSummary = markdownSummary
        self.spokenSummary = spokenSummary
    }
}

/// Takvim, açık anımsatıcılar ve ilk konumlu toplantı ETA bilgisini tek dürüst brifing raporunda birleştirir.
/// `.writeOnly` takvim izninde veya kilitli cihazda asla sahte "boş ajanda" üretmez.
public struct BriefingSynthesizer: Sendable {
    public init() {}

    public func composeBriefing(
        for date: Date,
        timeZone: TimeZone,
        isDeviceLocked: Bool,
        language: AgentLanguage,
        calendarExecutor: CalendarActionExecutor,
        remindersExecutor: RemindersActionExecutor,
        mapsExecutor: MapsActionExecutor? = nil
    ) async -> MorningBriefingReport {
        if isDeviceLocked {
            let reason = language == .azerbaijani
                ? "Cihaz kilidli ikən təqvim və şəxsi brifinq oxuna bilməz; əvvəlcə kilidi açın."
                : "Cihaz kilitliyken takvim ve kişisel brifing okunamaz; önce kilidi açın."
            let md = language == .azerbaijani
                ? "## Gündəlik Brifinq\n\n- **Giriş dayandırıldı:** \(reason)"
                : "## Günlük Brifing\n\n- **Erişim engellendi:** \(reason)"
            return MorningBriefingReport(
                generatedAt: date,
                language: language,
                calendarPermissionBlockedReason: reason,
                scheduleEvents: [],
                openReminders: [],
                estimatedTravelMinutes: nil,
                conflictWarningsTR: [],
                markdownSummary: md,
                spokenSummary: reason
            )
        }

        let calendarOutcome = await calendarExecutor.querySchedule(
            for: date,
            timeZone: timeZone,
            isDeviceLocked: isDeviceLocked
        )
        let remindersAuth = await remindersExecutor.authorizationState()
        let remindersBlockedReason: String?
        let reminders: [ReminderRecord]
        if remindersAuth == .fullAccess {
            remindersBlockedReason = nil
            reminders = await remindersExecutor.fetchOpenReminders(isDeviceLocked: isDeviceLocked)
        } else {
            remindersBlockedReason = language == .azerbaijani
                ? "Xatırlatmalar oxuma icazəsi verilməyib; açıq xatırlatmalar oxunmadı."
                : "Anımsatıcı okuma izni verilmedi; açık anımsatıcılar okunamadı."
            reminders = []
        }

        var blockedReason: String?
        var events: [CalendarEventRecord] = []

        switch calendarOutcome {
        case .events(let fetched):
            events = fetched.sorted { $0.startDate < $1.startDate }
        case .emptySchedule:
            events = []
        case .writeOnlyCannotReadSchedule:
            blockedReason = language == .azerbaijani
                ? "Təqvim icazəsi yalnız yazma (.writeOnly) səviyyəsindədir; cədvəl oxunmur."
                : "Takvim izni yalnızca yazma (.writeOnly) düzeyinde; ajanda okunamıyor."
        case .permissionDenied:
            blockedReason = language == .azerbaijani
                ? "Təqvim oxuma icazəsi verilməyib; cədvəl oxunmur."
                : "Takvim okuma izni verilmedi; ajanda okunamıyor."
        case .deviceLockedRequiresAuthentication:
            blockedReason = language == .azerbaijani
                ? "Cihaz kilidli olduğu üçün təqvim oxunmur."
                : "Cihaz kilitli olduğu için takvim okunamıyor."
        case .readError(let errorMessage):
            blockedReason = language == .azerbaijani
                ? "Təqvim oxunarkən xəta baş verdi: \(errorMessage)"
                : "Takvim okunurken hata oluştu: \(errorMessage)"
        }

        let conflicts = Self.detectConflicts(events: events, timeZone: timeZone)

        var etaMinutes: Int?
        var firstLocatedEvent: CalendarEventRecord?
        if blockedReason == nil,
           let mapsExecutor,
           let located = events.first(where: {
               let loc = ($0.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
               return !loc.isEmpty
           }),
           let locationQuery = located.location?.trimmingCharacters(in: .whitespacesAndNewlines) {
            firstLocatedEvent = located
            etaMinutes = await mapsExecutor.estimateTravelMinutes(destinationQuery: locationQuery, mode: .driving)
        }

        var allWarnings = conflicts
        if let etaMinutes, let located = firstLocatedEvent {
            let leadMinutes = located.startDate.timeIntervalSince(date) / 60.0
            if leadMinutes >= 0 && leadMinutes < Double(etaMinutes) {
                allWarnings.append(
                    "Yetişme riski: '\(located.title)' etkinliğine \(Int(leadMinutes.rounded())) dk kaldı ancak tahmini ulaşım \(etaMinutes) dk."
                )
            }
        }

        let markdown = Self.buildMarkdownSummary(
            date: date,
            timeZone: timeZone,
            language: language,
            blockedReason: blockedReason,
            remindersBlockedReason: remindersBlockedReason,
            events: events,
            reminders: reminders,
            firstLocatedEvent: firstLocatedEvent,
            estimatedTravelMinutes: etaMinutes,
            conflicts: allWarnings
        )

        let spoken = Self.buildSpokenSummary(
            date: date,
            timeZone: timeZone,
            language: language,
            blockedReason: blockedReason,
            remindersBlockedReason: remindersBlockedReason,
            events: events,
            reminders: reminders,
            firstLocatedEvent: firstLocatedEvent,
            estimatedTravelMinutes: etaMinutes,
            conflicts: allWarnings
        )

        return MorningBriefingReport(
            generatedAt: date,
            language: language,
            calendarPermissionBlockedReason: blockedReason,
            scheduleEvents: events,
            openReminders: reminders,
            estimatedTravelMinutes: etaMinutes,
            conflictWarningsTR: allWarnings,
            markdownSummary: markdown,
            spokenSummary: spoken
        )
    }

    private static func detectConflicts(events: [CalendarEventRecord], timeZone: TimeZone) -> [String] {
        guard events.count > 1 else { return [] }
        var warnings: [String] = []
        for i in 0..<(events.count - 1) {
            let current = events[i]
            for j in (i + 1)..<events.count {
                let next = events[j]
                if next.startDate < current.endDate && next.endDate > current.startDate {
                    let cStart = formatTime(current.startDate, timeZone: timeZone)
                    let cEnd = formatTime(current.endDate, timeZone: timeZone)
                    let nStart = formatTime(next.startDate, timeZone: timeZone)
                    let nEnd = formatTime(next.endDate, timeZone: timeZone)
                    warnings.append("Çakışma: '\(current.title)' (\(cStart)–\(cEnd)) ile '\(next.title)' (\(nStart)–\(nEnd)) çakışıyor.")
                }
            }
        }
        return warnings
    }

    private static func buildMarkdownSummary(
        date: Date,
        timeZone: TimeZone,
        language: AgentLanguage,
        blockedReason: String?,
        remindersBlockedReason: String?,
        events: [CalendarEventRecord],
        reminders: [ReminderRecord],
        firstLocatedEvent: CalendarEventRecord?,
        estimatedTravelMinutes: Int?,
        conflicts: [String]
    ) -> String {
        var lines: [String] = []
        lines.append(language == .azerbaijani ? "## Gündəlik Brifinq" : "## Günlük Brifing")
        lines.append("")

        if let blockedReason {
            lines.append(language == .azerbaijani ? "### Təqvim Durumu" : "### Takvim Durumu")
            lines.append("- **Okunamadı:** \(blockedReason)")
        } else if events.isEmpty {
            lines.append(language == .azerbaijani ? "### Təqvim" : "### Takvim")
            lines.append(language == .azerbaijani ? "- Bu gün üçün planlaşdırılmış tədbir yoxdur." : "- Bugün planlanmış etkinlik bulunmuyor.")
        } else {
            lines.append(language == .azerbaijani ? "### Təqvim (\(events.count))" : "### Takvim (\(events.count))")
            for event in events {
                let range = "\(formatTime(event.startDate, timeZone: timeZone))–\(formatTime(event.endDate, timeZone: timeZone))"
                if let loc = event.location, !loc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("- **\(range)** · \(event.title) (\(loc))")
                } else {
                    lines.append("- **\(range)** · \(event.title)")
                }
            }
        }

        if let eta = estimatedTravelMinutes, let target = firstLocatedEvent {
            let suggestedLeave = target.startDate.addingTimeInterval(-TimeInterval(eta * 60))
            let leaveText = formatTime(suggestedLeave, timeZone: timeZone)
            lines.append("")
            lines.append(language == .azerbaijani ? "### Yol və Çıxış Vaxtı" : "### Ulaşım ve Çıkış Önerisi")
            lines.append(
                language == .azerbaijani
                    ? "- '\(target.title)' üçün təxmini yol: **\(eta) dəq** (təklif olunan çıxış: **\(leaveText)**)."
                    : "- '\(target.title)' için tahmini ulaşım: **\(eta) dk** (önerilen çıkış: **\(leaveText)**)."
            )
        }

        lines.append("")
        if let remindersBlockedReason {
            lines.append(language == .azerbaijani ? "### Xatırlatmalar Durumu" : "### Anımsatıcı Durumu")
            lines.append("- **Okunamadı:** \(remindersBlockedReason)")
        } else if reminders.isEmpty {
            lines.append(language == .azerbaijani ? "### Açıq Xatırlatmalar" : "### Açık Anımsatıcılar")
            lines.append(language == .azerbaijani ? "- Açıq xatırlatma yoxdur." : "- Açık anımsatıcı bulunmuyor.")
        } else {
            lines.append(language == .azerbaijani ? "### Açıq Xatırlatmalar (\(reminders.count))" : "### Açık Anımsatıcılar (\(reminders.count))")
            for rem in reminders {
                let dueStr = formatTime(rem.dueDate, timeZone: timeZone)
                lines.append("- \(rem.title) (**\(dueStr)**)")
            }
        }

        if !conflicts.isEmpty {
            lines.append("")
            lines.append(language == .azerbaijani ? "### Diqqət və Toqquşmalar" : "### Çakışma ve Uyarılar")
            for warning in conflicts {
                lines.append("- \(warning)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func buildSpokenSummary(
        date: Date,
        timeZone: TimeZone,
        language: AgentLanguage,
        blockedReason: String?,
        remindersBlockedReason: String?,
        events: [CalendarEventRecord],
        reminders: [ReminderRecord],
        firstLocatedEvent: CalendarEventRecord?,
        estimatedTravelMinutes: Int?,
        conflicts: [String]
    ) -> String {
        var parts: [String] = []
        if let blockedReason {
            parts.append(blockedReason)
        } else if events.isEmpty {
            parts.append(
                language == .azerbaijani
                    ? "Bu gün təqviminiz boşdur."
                    : "Bugün takviminizde kayıtlı etkinlik yok."
            )
        } else {
            let first = events[0]
            let firstTime = formatTime(first.startDate, timeZone: timeZone)
            if language == .azerbaijani {
                parts.append("Bu gün \(events.count) tədbir var; ilki saat \(firstTime) · \(first.title).")
            } else {
                parts.append("Bugün \(events.count) etkinliğiniz var; ilki saat \(firstTime) · \(first.title).")
            }
        }

        if let eta = estimatedTravelMinutes, let target = firstLocatedEvent {
            let leaveText = formatTime(target.startDate.addingTimeInterval(-TimeInterval(eta * 60)), timeZone: timeZone)
            parts.append(
                language == .azerbaijani
                    ? "\(target.location ?? target.title) üçün təxmini yol \(eta) dəqiqədir, saat \(leaveText) çıxmağınız tövsiyə olunur."
                    : "\(target.location ?? target.title) konumu için tahmini yol \(eta) dakika, saat \(leaveText) çıkmanız önerilir."
            )
        }

        if let remindersBlockedReason {
            parts.append(remindersBlockedReason)
        } else if !reminders.isEmpty {
            parts.append(
                language == .azerbaijani
                    ? "\(reminders.count) açıq xatırlatma gözləyir."
                    : "\(reminders.count) açık anımsatıcınız bulunuyor."
            )
        }

        if !conflicts.isEmpty {
            parts.append(conflicts[0])
        }

        return parts.joined(separator: " ")
    }

    private static func formatTime(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 2. iOS 26 AlarmKit Yürütücüsü (AlarmActionExecutor)

public enum AlarmAuthorizationState: String, Codable, Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
}

public struct AlarmRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let fireDate: Date
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        fireDate: Date,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.fireDate = fireDate
        self.createdAt = createdAt
    }
}

public enum AlarmScheduleOutcome: Equatable, Sendable {
    case scheduled(AlarmRecord)
    case permissionDenied
    case invalidFireDate(String)
    case failed(String)
}

public protocol AlarmBackendProtocol: Sendable {
    func authorizationState() async -> AlarmAuthorizationState
    func scheduleAlarm(id: UUID, title: String, fireDate: Date) async throws -> AlarmRecord
    func cancelAlarm(identifier: String) async throws
}

public final class InMemoryAlarmBackend: AlarmBackendProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public var state: AlarmAuthorizationState
    public var scheduledAlarms: [AlarmRecord] = []
    public var simulatedError: Error?

    public init(state: AlarmAuthorizationState = .authorized, scheduledAlarms: [AlarmRecord] = []) {
        self.state = state
        self.scheduledAlarms = scheduledAlarms
    }

    public func authorizationState() async -> AlarmAuthorizationState {
        lock.withLock { state }
    }

    public func scheduleAlarm(id: UUID, title: String, fireDate: Date) async throws -> AlarmRecord {
        try lock.withLock {
            if let simulatedError {
                throw simulatedError
            }
            let record = AlarmRecord(
                id: id.uuidString,
                title: title,
                fireDate: fireDate,
                createdAt: Date()
            )
            scheduledAlarms.append(record)
            return record
        }
    }

    public func cancelAlarm(identifier: String) async throws {
        lock.withLock {
            scheduledAlarms.removeAll { $0.id == identifier }
        }
    }
}

#if os(iOS) && canImport(AlarmKit) && canImport(SwiftUI)
#if compiler(>=6.2)
@available(iOS 26.0, *)
private struct JarvisAlarmMetadata: AlarmMetadata {
    let title: String
}

@available(iOS 26.0, *)
public final class LiveAlarmKitBackend: AlarmBackendProtocol, @unchecked Sendable {
    public init() {}

    public func authorizationState() async -> AlarmAuthorizationState {
        switch AlarmManager.shared.authorizationState {
        case .authorized:
            return .authorized
        case .notDetermined:
            do {
                let updated = try await AlarmManager.shared.requestAuthorization()
                return updated == .authorized ? .authorized : .denied
            } catch {
                return .denied
            }
        default:
            return .denied
        }
    }

    public func scheduleAlarm(id: UUID, title: String, fireDate: Date) async throws -> AlarmRecord {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = cleanTitle.isEmpty ? "iAgent Alarm" : cleanTitle
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: finalTitle)
        )
        let presentation = AlarmPresentation(alert: alert)
        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: JarvisAlarmMetadata(title: finalTitle),
            tintColor: Color.cyan
        )
        let configuration = AlarmManager.AlarmConfiguration<JarvisAlarmMetadata>.alarm(
            schedule: .fixed(fireDate),
            attributes: attributes,
            sound: .default
        )
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        return AlarmRecord(id: id.uuidString, title: finalTitle, fireDate: fireDate, createdAt: Date())
    }

    public func cancelAlarm(identifier: String) async throws {
        if let uuid = UUID(uuidString: identifier) {
            try AlarmManager.shared.cancel(id: uuid)
        }
    }
}
#endif
#endif

/// iOS 26 AlarmKit (veya test belleği) üzerinden zamanlı sistem alarmı kurar ve dürüst makbuz üretir.
public final class AlarmActionExecutor: @unchecked Sendable {
    private let backend: AlarmBackendProtocol

    public init(backend: AlarmBackendProtocol) {
        self.backend = backend
    }

    public func scheduleAlarm(
        taskId: UUID,
        revisionNumber: Int,
        stepId: String,
        title: String,
        fireDate: Date,
        now: Date
    ) async -> ActionReceipt {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = trimmedTitle.isEmpty ? "iAgent Alarm" : trimmedTitle

        guard fireDate > now else {
            return ActionReceipt(
                taskId: taskId,
                revisionNumber: revisionNumber,
                stepId: stepId,
                executorName: "AlarmKit",
                outcome: .failed,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Geçmiş zamana alarm kurulamaz",
                spokenVerbAZ: "Keçmiş zamana zəngli saat qurula bilməz",
                detail: "Alarm zamanı mevcut saatten ileri olmalıdır."
            )
        }

        let auth = await backend.authorizationState()
        guard auth == .authorized else {
            return ActionReceipt(
                taskId: taskId,
                revisionNumber: revisionNumber,
                stepId: stepId,
                executorName: "AlarmKit",
                outcome: .failed,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Alarm izni verilmedi",
                spokenVerbAZ: "Zəngli saat icazəsi verilmədi",
                detail: "AlarmKit yetkilendirmesi olmadan alarm kurulamaz."
            )
        }

        do {
            let alarmId = UUID()
            let record = try await backend.scheduleAlarm(id: alarmId, title: effectiveTitle, fireDate: fireDate)
            return ActionReceipt(
                taskId: taskId,
                revisionNumber: revisionNumber,
                stepId: stepId,
                executorName: "AlarmKit",
                outcome: .succeeded,
                externalObjectId: record.id,
                timestamp: now,
                canUndo: true,
                spokenVerbTR: "Alarm kuruldu",
                spokenVerbAZ: "Zəngli saat quruldu",
                detail: "\(record.title) (\(record.id))"
            )
        } catch {
            return ActionReceipt(
                taskId: taskId,
                revisionNumber: revisionNumber,
                stepId: stepId,
                executorName: "AlarmKit",
                outcome: .failed,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Alarm kurulamadı",
                spokenVerbAZ: "Zəngli saat qurula bilmədi",
                detail: error.localizedDescription
            )
        }
    }

    public func cancelAlarm(identifier: String) async -> Bool {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let auth = await backend.authorizationState()
        guard auth == .authorized else { return false }
        do {
            try await backend.cancelAlarm(identifier: trimmed)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - 3. Sıfır-Güven Biyometrik Doğrulama Kapısı (BiometricAuthExecutor)

#if canImport(LocalAuthentication)
/// Her yüksek riskli (`tier3BiometricRequired`) adım için taze `LAContext` (`touchIDAuthenticationAllowableReuseDuration = 0`)
/// başlatıp `(taskId, revisionNumber, approvalDigest)` üçlüsüne bağlı HMAC-SHA256 `BiometricAttestation` üretir.
public final class LiveLocalAuthenticationGate: BiometricAuthGateProtocol, @unchecked Sendable {
    private let signingKey: SymmetricKey
    private let allowDevicePasscodeFallback: Bool
    private let clock: ClockProtocol

    public init(
        signingKey: SymmetricKey = SymmetricKey(size: .bits256),
        allowDevicePasscodeFallback: Bool = true,
        clock: ClockProtocol = SystemClock()
    ) {
        self.signingKey = signingKey
        self.allowDevicePasscodeFallback = allowDevicePasscodeFallback
        self.clock = clock
    }

    public var key: SymmetricKey { signingKey }

    public func authenticate(
        reason: String,
        taskId: UUID,
        revisionNumber: Int,
        approvalDigest: String
    ) async throws -> BiometricAttestation {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0

        let policy: LAPolicy = allowDevicePasscodeFallback
            ? .deviceOwnerAuthentication
            : .deviceOwnerAuthenticationWithBiometrics

        var evalError: NSError?
        guard context.canEvaluatePolicy(policy, error: &evalError) else {
            throw BiometricAuthError.unavailable
        }

        do {
            let success = try await context.evaluatePolicy(policy, localizedReason: reason)
            guard success else {
                throw BiometricAuthError.failed("Biyometrik doğrulama tamamlanamadı.")
            }
            return BiometricAttestation(
                taskId: taskId,
                revisionNumber: revisionNumber,
                approvalDigest: approvalDigest,
                attestedAt: clock.now(),
                signingKey: signingKey
            )
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                throw BiometricAuthError.cancelled
            case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                throw BiometricAuthError.unavailable
            default:
                throw BiometricAuthError.failed(laError.localizedDescription)
            }
        } catch let bioError as BiometricAuthError {
            throw bioError
        } catch {
            throw BiometricAuthError.failed(error.localizedDescription)
        }
    }
}
#endif

public struct BiometricAuthorizationResult: Equatable, Sendable {
    public let required: Bool
    public let granted: Bool
    public let attestation: BiometricAttestation?
    public let failureReason: String?

    public init(
        required: Bool,
        granted: Bool,
        attestation: BiometricAttestation? = nil,
        failureReason: String? = nil
    ) {
        self.required = required
        self.granted = granted
        self.attestation = attestation
        self.failureReason = failureReason
    }
}

public final class BiometricAuthExecutor: @unchecked Sendable {
    private let gate: BiometricAuthGateProtocol

    public init(gate: BiometricAuthGateProtocol) {
        self.gate = gate
    }

    #if canImport(LocalAuthentication)
    public convenience init(
        signingKey: SymmetricKey = SymmetricKey(size: .bits256),
        allowDevicePasscodeFallback: Bool = true,
        clock: ClockProtocol = SystemClock()
    ) {
        self.init(
            gate: LiveLocalAuthenticationGate(
                signingKey: signingKey,
                allowDevicePasscodeFallback: allowDevicePasscodeFallback,
                clock: clock
            )
        )
    }
    #endif

    public func authenticate(
        reason: String,
        taskId: UUID,
        revisionNumber: Int,
        approvalDigest: String
    ) async throws -> BiometricAttestation {
        try await gate.authenticate(
            reason: reason,
            taskId: taskId,
            revisionNumber: revisionNumber,
            approvalDigest: approvalDigest
        )
    }

    public func authorizeStepIfNeeded(
        step: ActionStep,
        revision: PlanRevision,
        reason: String
    ) async -> BiometricAuthorizationResult {
        let tier = ActionRiskTier.classify(
            action: step.action,
            shortcutLabel: step.parameters.shortcutLabel,
            shortcutInput: step.parameters.shortcutInput
        )
        guard tier == .tier3BiometricRequired else {
            return BiometricAuthorizationResult(required: false, granted: true, attestation: nil, failureReason: nil)
        }

        do {
            let attestation = try await gate.authenticate(
                reason: reason,
                taskId: revision.taskId,
                revisionNumber: revision.revisionNumber,
                approvalDigest: revision.approvalDigest
            )
            return BiometricAuthorizationResult(
                required: true,
                granted: true,
                attestation: attestation,
                failureReason: nil
            )
        } catch let bioError as BiometricAuthError {
            let message: String
            switch bioError {
            case .cancelled:
                message = "Biyometrik doğrulama kullanıcı tarafından iptal edildi."
            case .unavailable:
                message = "Bu cihazda Face ID / Touch ID veya parola doğrulaması kullanılamıyor."
            case .failed(let detail):
                message = detail
            }
            return BiometricAuthorizationResult(
                required: true,
                granted: false,
                attestation: nil,
                failureReason: message
            )
        } catch {
            return BiometricAuthorizationResult(
                required: true,
                granted: false,
                attestation: nil,
                failureReason: error.localizedDescription
            )
        }
    }
}

// MARK: - 4. Sürüş / CarPlay Güvenlik Politikası ve Kısa Brifing (DrivingSafetyPolicy & CarPlayBriefingComposer)

public enum DrivingSafetyDecision: Equatable, Sendable {
    case allowed
    case deferredForDrivingSafety(reasonTR: String)
}

public struct DrivingSafetyPolicy: Sendable {
    public static let maxDrivingSpokenCharacters = 160

    public init() {}

    public func evaluate(action: ActionKind, isDrivingOrCarPlay: Bool) -> DrivingSafetyDecision {
        Self.evaluate(action: action, isDrivingOrCarPlay: isDrivingOrCarPlay)
    }

    public static func evaluate(action: ActionKind, isDrivingOrCarPlay: Bool) -> DrivingSafetyDecision {
        guard isDrivingOrCarPlay else {
            return .allowed
        }
        switch action {
        case .messagesCompose, .mailCompose, .shareSheet:
            return .deferredForDrivingSafety(
                reasonTR: "Sürüş/CarPlay sırasında ekran ve iletişim düzenleyicisi güvenlik nedeniyle ertelendi; park ettiğinizde devam edebilirsiniz."
            )
        case .shortcutsRun:
            return .deferredForDrivingSafety(
                reasonTR: "Sürüş/CarPlay sırasında harici Kestirme uygulamasına geçiş güvenlik nedeniyle ertelendi."
            )
        case .notesSearch, .textSummarizeAndNote:
            return .deferredForDrivingSafety(
                reasonTR: "Sürüş/CarPlay sırasında uzun metin inceleme ve belge özeti güvenlik nedeniyle ertelendi."
            )
        case .memoryForget:
            return .deferredForDrivingSafety(
                reasonTR: "Sürüş/CarPlay sırasında kalıcı hafıza silme işlemi güvenlik nedeniyle ertelendi."
            )
        case .notesCreate,
             .calendarRead,
             .calendarCreate,
             .remindersCreate,
             .remindersRead,
             .phoneCall,
             .mapsDirections,
             .mapsEstimateETA,
             .assistantReply,
             .briefingCompose,
             .memoryRemember,
             .memoryRecall,
             .alarmCreate:
            return .allowed
        }
    }

    public func evaluateHomeOperation(_ category: HomeActionCategory, isDrivingOrCarPlay: Bool) -> DrivingSafetyDecision {
        Self.evaluateHomeOperation(category, isDrivingOrCarPlay: isDrivingOrCarPlay)
    }

    public static func evaluateHomeOperation(_ category: HomeActionCategory, isDrivingOrCarPlay: Bool) -> DrivingSafetyDecision {
        guard isDrivingOrCarPlay else {
            return .allowed
        }
        switch category {
        case .securityControl:
            return .deferredForDrivingSafety(
                reasonTR: "Sürüş/CarPlay sırasında kapı kilidi veya güvenlik alarmı kontrolü güvenlik nedeniyle ertelendi."
            )
        case .statusRead, .sceneExecute:
            return .allowed
        }
    }

    public func trimSpokenForDriving(_ text: String) -> String {
        Self.trimSpokenForDriving(text)
    }

    public static func trimSpokenForDriving(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxDrivingSpokenCharacters else {
            return collapsed
        }

        let targetLength = maxDrivingSpokenCharacters - 3
        let prefixSlice = collapsed.prefix(targetLength)
        if let lastSpace = prefixSlice.lastIndex(of: " "),
           collapsed.distance(from: prefixSlice.startIndex, to: lastSpace) >= targetLength / 2 {
            return String(prefixSlice[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }
        return String(prefixSlice).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}

public struct CarPlayBriefingComposer: Sendable {
    public init() {}

    public func composeDrivingBriefing(
        from report: MorningBriefingReport,
        language: AgentLanguage? = nil
    ) -> String {
        let lang = language ?? report.language
        if let blocked = report.calendarPermissionBlockedReason {
            return DrivingSafetyPolicy.trimSpokenForDriving(blocked)
        }

        var segments: [String] = []
        if report.scheduleEvents.isEmpty {
            segments.append(lang == .azerbaijani ? "Bu gün təqvim boşdur." : "Bugün takvim boş.")
        } else {
            let first = report.scheduleEvents[0]
            if let eta = report.estimatedTravelMinutes {
                segments.append(
                    lang == .azerbaijani
                        ? "\(report.scheduleEvents.count) tədbir var. İlki: \(first.title), yol \(eta) dəq."
                        : "\(report.scheduleEvents.count) etkinlik var. İlki: \(first.title), yol \(eta) dk."
                )
            } else {
                segments.append(
                    lang == .azerbaijani
                        ? "\(report.scheduleEvents.count) tədbir var. İlki: \(first.title)."
                        : "\(report.scheduleEvents.count) etkinlik var. İlki: \(first.title)."
                )
            }
        }

        if !report.openReminders.isEmpty {
            segments.append(
                lang == .azerbaijani
                    ? "\(report.openReminders.count) xatırlatma."
                    : "\(report.openReminders.count) anımsatıcı."
            )
        }

        if !report.conflictWarningsTR.isEmpty {
            segments.append(lang == .azerbaijani ? "Toqquşma xəbərdarlığı var." : "Çakışma uyarısı var.")
        }

        return DrivingSafetyPolicy.trimSpokenForDriving(segments.joined(separator: " "))
    }
}

// MARK: - 5. Akıllı Ev (HomeKit), Odak (Focus) ve Müzik (MusicKit) Yürütücüleri

public enum HomeAuthorizationState: String, Codable, Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
}

public enum HomeActionCategory: String, Codable, Sendable, Equatable {
    case statusRead = "home.statusRead"
    case sceneExecute = "home.sceneExecute"
    case securityControl = "home.securityControl"
}

public struct HomeAccessorySnapshot: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let roomName: String?
    public let isReachable: Bool
    public let isSecurityAccessory: Bool
    public let stateSummary: String

    public init(
        id: String,
        name: String,
        roomName: String? = nil,
        isReachable: Bool = true,
        isSecurityAccessory: Bool = false,
        stateSummary: String
    ) {
        self.id = id
        self.name = name
        self.roomName = roomName
        self.isReachable = isReachable
        self.isSecurityAccessory = isSecurityAccessory
        self.stateSummary = stateSummary
    }
}

public struct HomeSceneSnapshot: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let containsSecurityAction: Bool

    public init(id: String, name: String, containsSecurityAction: Bool = false) {
        self.id = id
        self.name = name
        self.containsSecurityAction = containsSecurityAction
    }
}

public enum HomeActionOutcome: Equatable, Sendable {
    case status([HomeAccessorySnapshot])
    case sceneExecuted(sceneName: String, verifiedStates: [HomeAccessorySnapshot])
    case securityActionExecuted(accessoryName: String, verifiedState: String)
    case explicitSecurityConfirmationRequired(targetName: String, reasonTR: String)
    case deferredForDrivingSafety(reasonTR: String)
    case accessoryUnreachable(name: String)
    case notFound(query: String)
    case permissionDenied
    case failed(String)
}

public protocol HomeBackendProtocol: Sendable {
    func authorizationState() async -> HomeAuthorizationState
    func fetchAccessories() async throws -> [HomeAccessorySnapshot]
    func fetchScenes() async throws -> [HomeSceneSnapshot]
    func executeScene(named sceneName: String) async throws -> HomeSceneSnapshot
    func setSecurityState(accessoryName: String, lockedOrArmed: Bool) async throws -> HomeAccessorySnapshot
}

public final class InMemoryHomeBackend: HomeBackendProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public var state: HomeAuthorizationState
    public var accessories: [HomeAccessorySnapshot]
    public var scenes: [HomeSceneSnapshot]
    public var executedScenes: [String] = []

    public init(
        state: HomeAuthorizationState = .authorized,
        accessories: [HomeAccessorySnapshot] = [],
        scenes: [HomeSceneSnapshot] = []
    ) {
        self.state = state
        self.accessories = accessories
        self.scenes = scenes
    }

    public func authorizationState() async -> HomeAuthorizationState {
        lock.withLock { state }
    }

    public func fetchAccessories() async throws -> [HomeAccessorySnapshot] {
        try lock.withLock {
            guard state == .authorized else {
                throw NSError(domain: "HomeAction", code: 403, userInfo: [NSLocalizedDescriptionKey: "HomeKit izni verilmedi."])
            }
            return accessories
        }
    }

    public func fetchScenes() async throws -> [HomeSceneSnapshot] {
        try lock.withLock {
            guard state == .authorized else {
                throw NSError(domain: "HomeAction", code: 403, userInfo: [NSLocalizedDescriptionKey: "HomeKit izni verilmedi."])
            }
            return scenes
        }
    }

    public func executeScene(named sceneName: String) async throws -> HomeSceneSnapshot {
        try lock.withLock {
            let norm = TurkicTextNormalizer.normalize(sceneName.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let scene = scenes.first(where: { TurkicTextNormalizer.normalize($0.name) == norm }) else {
                throw NSError(domain: "HomeAction", code: 404, userInfo: [NSLocalizedDescriptionKey: "Sahne bulunamadı: \(sceneName)"])
            }
            executedScenes.append(scene.name)
            return scene
        }
    }

    public func setSecurityState(accessoryName: String, lockedOrArmed: Bool) async throws -> HomeAccessorySnapshot {
        try lock.withLock {
            let norm = TurkicTextNormalizer.normalize(accessoryName.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let idx = accessories.firstIndex(where: { TurkicTextNormalizer.normalize($0.name) == norm }) else {
                throw NSError(domain: "HomeAction", code: 404, userInfo: [NSLocalizedDescriptionKey: "Güvenlik aksesuarı bulunamadı: \(accessoryName)"])
            }
            let current = accessories[idx]
            guard current.isReachable else {
                return current
            }
            let updated = HomeAccessorySnapshot(
                id: current.id,
                name: current.name,
                roomName: current.roomName,
                isReachable: current.isReachable,
                isSecurityAccessory: true,
                stateSummary: lockedOrArmed ? "Kilitli / Kuruldu" : "Açık / Devre Dışı"
            )
            accessories[idx] = updated
            return updated
        }
    }
}

#if os(iOS) && canImport(HomeKit)
public final class LiveHomeKitBackend: NSObject, HomeBackendProtocol, HMHomeManagerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var manager: HMHomeManager?
    private var didReceiveInitialHomes = false
    private var pendingHomeLoadContinuations: [CheckedContinuation<Void, Never>] = []

    public override init() {
        super.init()
    }

    nonisolated public func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        flushPendingHomeContinuations()
    }

    private func flushPendingHomeContinuations() {
        let continuations: [CheckedContinuation<Void, Never>] = lock.withLock {
            didReceiveInitialHomes = true
            let items = pendingHomeLoadContinuations
            pendingHomeLoadContinuations.removeAll()
            return items
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    @MainActor
    private func ensureManagerReady() async -> HMHomeManager {
        let activeManager: HMHomeManager
        if let existing = manager {
            activeManager = existing
        } else {
            let created = HMHomeManager()
            created.delegate = self
            manager = created
            activeManager = created
        }

        let alreadyLoaded = lock.withLock { didReceiveInitialHomes }
        if !alreadyLoaded && activeManager.authorizationStatus.contains(.authorized) {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(750))
                self?.flushPendingHomeContinuations()
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let shouldResumeNow = lock.withLock { () -> Bool in
                    if didReceiveInitialHomes {
                        return true
                    }
                    pendingHomeLoadContinuations.append(continuation)
                    return false
                }
                if shouldResumeNow {
                    continuation.resume()
                }
            }
        }
        return activeManager
    }

    @MainActor
    public func authorizationState() async -> HomeAuthorizationState {
        let hm = await ensureManagerReady()
        let status = hm.authorizationStatus
        if status.contains(.authorized) {
            return .authorized
        }
        if status.contains(.restricted) || status.contains(.determined) {
            return .denied
        }
        return .notDetermined
    }

    @MainActor
    public func fetchAccessories() async throws -> [HomeAccessorySnapshot] {
        let hm = await ensureManagerReady()
        guard let home = hm.primaryHome ?? hm.homes.first else {
            return []
        }
        return home.accessories.map(Self.snapshot(from:))
    }

    @MainActor
    public func fetchScenes() async throws -> [HomeSceneSnapshot] {
        let hm = await ensureManagerReady()
        guard let home = hm.primaryHome ?? hm.homes.first else {
            return []
        }
        return home.actionSets.map { actionSet in
            HomeSceneSnapshot(
                id: actionSet.uniqueIdentifier.uuidString,
                name: actionSet.name,
                containsSecurityAction: Self.sceneContainsSecurityAction(actionSet)
            )
        }
    }

    @MainActor
    public func executeScene(named sceneName: String) async throws -> HomeSceneSnapshot {
        let hm = await ensureManagerReady()
        guard let home = hm.primaryHome ?? hm.homes.first else {
            throw NSError(domain: "HomeKit", code: 404, userInfo: [NSLocalizedDescriptionKey: "Kayıtlı HomeKit evi bulunamadı."])
        }
        let norm = TurkicTextNormalizer.normalize(sceneName.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let targetSet = home.actionSets.first(where: { TurkicTextNormalizer.normalize($0.name) == norm }) else {
            throw NSError(domain: "HomeKit", code: 404, userInfo: [NSLocalizedDescriptionKey: "Sahne bulunamadı: \(sceneName)"])
        }
        try await runActionSet(targetSet, in: home)
        return HomeSceneSnapshot(
            id: targetSet.uniqueIdentifier.uuidString,
            name: targetSet.name,
            containsSecurityAction: Self.sceneContainsSecurityAction(targetSet)
        )
    }

    @MainActor
    public func setSecurityState(accessoryName: String, lockedOrArmed: Bool) async throws -> HomeAccessorySnapshot {
        let hm = await ensureManagerReady()
        guard let home = hm.primaryHome ?? hm.homes.first else {
            throw NSError(domain: "HomeKit", code: 404, userInfo: [NSLocalizedDescriptionKey: "Kayıtlı HomeKit evi bulunamadı."])
        }
        let norm = TurkicTextNormalizer.normalize(accessoryName.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let accessory = home.accessories.first(where: { TurkicTextNormalizer.normalize($0.name) == norm }) else {
            throw NSError(domain: "HomeKit", code: 404, userInfo: [NSLocalizedDescriptionKey: "Aksesuar bulunamadı: \(accessoryName)"])
        }
        guard accessory.isReachable else {
            return Self.snapshot(from: accessory)
        }

        for service in accessory.services {
            if let lockTarget = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeTargetLockMechanismState }) {
                let target = NSNumber(value: (lockedOrArmed ? HMCharacteristicValueLockMechanismState.secured : .unsecured).rawValue)
                try await writeCharacteristic(lockTarget, value: target)
                if let lockCurrent = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeCurrentLockMechanismState }) {
                    try? await readCharacteristic(lockCurrent)
                }
                return Self.snapshot(from: accessory)
            }
            if let securityTarget = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeTargetSecuritySystemState }) {
                let target = NSNumber(value: (lockedOrArmed ? HMCharacteristicValueTargetSecuritySystemState.awayArm : .disarm).rawValue)
                try await writeCharacteristic(securityTarget, value: target)
                if let securityCurrent = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeCurrentSecuritySystemState }) {
                    try? await readCharacteristic(securityCurrent)
                }
                return Self.snapshot(from: accessory)
            }
        }

        throw NSError(domain: "HomeKit", code: 422, userInfo: [NSLocalizedDescriptionKey: "Bu aksesuarda kilit veya güvenlik karakteristiği yok."])
    }

    @MainActor
    private func runActionSet(_ actionSet: HMActionSet, in home: HMHome) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.executeActionSet(actionSet) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    @MainActor
    private func writeCharacteristic(_ characteristic: HMCharacteristic, value: NSNumber) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.writeValue(value) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    @MainActor
    private func readCharacteristic(_ characteristic: HMCharacteristic) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.readValue { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func snapshot(from accessory: HMAccessory) -> HomeAccessorySnapshot {
        let securityServiceTypes: Set<String> = [
            HMServiceTypeLockMechanism,
            HMServiceTypeSecuritySystem,
            HMServiceTypeGarageDoorOpener
        ]
        let isSecurity = accessory.services.contains { securityServiceTypes.contains($0.serviceType) }
        return HomeAccessorySnapshot(
            id: accessory.uniqueIdentifier.uuidString,
            name: accessory.name,
            roomName: accessory.room?.name,
            isReachable: accessory.isReachable,
            isSecurityAccessory: isSecurity,
            stateSummary: accessory.isReachable ? "Erişilebilir" : "Erişilemiyor"
        )
    }

    private static func sceneContainsSecurityAction(_ actionSet: HMActionSet) -> Bool {
        if actionSet.actionSetType == HMActionSetTypeHomeDeparture {
            return true
        }
        let normName = TurkicTextNormalizer.normalize(actionSet.name)
        let securityMarkers = ["kilit", "lock", "alarm", "guvenlik", "security", "garaj", "garage"]
        if securityMarkers.contains(where: { normName.contains($0) }) {
            return true
        }
        let charSelector = NSSelectorFromString("characteristic")
        return actionSet.actions.contains { action in
            guard action.responds(to: charSelector),
                  let characteristic = action.value(forKey: "characteristic") as? HMCharacteristic else {
                return false
            }
            let type = characteristic.characteristicType
            return type == HMCharacteristicTypeTargetLockMechanismState
                || type == HMCharacteristicTypeTargetSecuritySystemState
                || type == HMCharacteristicTypeTargetDoorState
        }
    }
}
#endif

/// Akıllı ev durum okuma, sahne yürütme ve güvenlik kilidi/alarmı (`explicitSecurityConfirmation` ile) yönetir.
public final class HomeActionExecutor: @unchecked Sendable {
    private let backend: HomeBackendProtocol
    private let safetyPolicy: DrivingSafetyPolicy

    public init(backend: HomeBackendProtocol, safetyPolicy: DrivingSafetyPolicy = DrivingSafetyPolicy()) {
        self.backend = backend
        self.safetyPolicy = safetyPolicy
    }

    public func readStatus(isDeviceLocked: Bool = false) async -> HomeActionOutcome {
        guard !isDeviceLocked else {
            return .failed("Cihaz kilitliyken ev durumu okunamaz.")
        }
        guard await backend.authorizationState() == .authorized else {
            return .permissionDenied
        }
        do {
            let items = try await backend.fetchAccessories()
            return .status(items)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func executeScene(
        named sceneName: String,
        hasExplicitSecurityConfirmation: Bool = false,
        isDrivingOrCarPlay: Bool = false,
        isDeviceLocked: Bool = false
    ) async -> HomeActionOutcome {
        guard !isDeviceLocked else {
            return .failed("Cihaz kilitliyken akıllı ev sahnesi çalıştırılamaz.")
        }
        guard await backend.authorizationState() == .authorized else {
            return .permissionDenied
        }
        do {
            let scenes = try await backend.fetchScenes()
            let norm = TurkicTextNormalizer.normalize(sceneName.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let target = scenes.first(where: { TurkicTextNormalizer.normalize($0.name) == norm }) else {
                return .notFound(query: sceneName)
            }
            if target.containsSecurityAction {
                if case .deferredForDrivingSafety(let reason) = safetyPolicy.evaluateHomeOperation(.securityControl, isDrivingOrCarPlay: isDrivingOrCarPlay) {
                    return .deferredForDrivingSafety(reasonTR: reason)
                }
                guard hasExplicitSecurityConfirmation else {
                    return .explicitSecurityConfirmationRequired(
                        targetName: target.name,
                        reasonTR: "'\(target.name)' sahnesi kilit/alarm içerdiği için ayrı güvenlik onayı gerektirir."
                    )
                }
            }
            let executed = try await backend.executeScene(named: target.name)
            let updatedAccessories = (try? await backend.fetchAccessories()) ?? []
            return .sceneExecuted(sceneName: executed.name, verifiedStates: updatedAccessories)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func controlSecurityAccessory(
        named accessoryName: String,
        lockedOrArmed: Bool,
        hasExplicitSecurityConfirmation: Bool,
        isDrivingOrCarPlay: Bool = false,
        isDeviceLocked: Bool = false
    ) async -> HomeActionOutcome {
        if case .deferredForDrivingSafety(let reason) = safetyPolicy.evaluateHomeOperation(.securityControl, isDrivingOrCarPlay: isDrivingOrCarPlay) {
            return .deferredForDrivingSafety(reasonTR: reason)
        }
        guard !isDeviceLocked else {
            return .failed("Cihaz kilitliyken kapı kilidi veya alarm değiştirilemez.")
        }
        guard hasExplicitSecurityConfirmation else {
            return .explicitSecurityConfirmationRequired(
                targetName: accessoryName,
                reasonTR: "Kapı kilidi ve güvenlik alarmı işlemleri için ayrı açık güvenlik onayı gereklidir."
            )
        }
        guard await backend.authorizationState() == .authorized else {
            return .permissionDenied
        }
        do {
            let result = try await backend.setSecurityState(accessoryName: accessoryName, lockedOrArmed: lockedOrArmed)
            guard result.isReachable else {
                return .accessoryUnreachable(name: result.name)
            }
            return .securityActionExecuted(accessoryName: result.name, verifiedState: result.stateSummary)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - Odak Durumu (FocusActionExecutor)

public enum FocusAuthorizationState: String, Codable, Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

public struct FocusStatusSnapshot: Codable, Equatable, Sendable {
    public let authorizationState: FocusAuthorizationState
    public let isFocused: Bool?
    public let checkedAt: Date
    public let guidanceTR: String
    public let guidanceAZ: String

    public init(
        authorizationState: FocusAuthorizationState,
        isFocused: Bool?,
        checkedAt: Date,
        guidanceTR: String,
        guidanceAZ: String
    ) {
        self.authorizationState = authorizationState
        self.isFocused = isFocused
        self.checkedAt = checkedAt
        self.guidanceTR = guidanceTR
        self.guidanceAZ = guidanceAZ
    }
}

public protocol FocusStatusReaderProtocol: Sendable {
    func readStatus(now: Date) async -> FocusStatusSnapshot
}

public final class InMemoryFocusStatusReader: FocusStatusReaderProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public var authorizationState: FocusAuthorizationState
    public var isFocused: Bool?

    public init(authorizationState: FocusAuthorizationState = .authorized, isFocused: Bool? = false) {
        self.authorizationState = authorizationState
        self.isFocused = isFocused
    }

    public func readStatus(now: Date) async -> FocusStatusSnapshot {
        let (auth, focused) = lock.withLock { (authorizationState, isFocused) }
        return FocusActionExecutor.makeSnapshot(authorizationState: auth, isFocused: focused, now: now)
    }
}

#if canImport(Intents)
public final class LiveFocusStatusReader: FocusStatusReaderProtocol, @unchecked Sendable {
    public init() {}

    public func readStatus(now: Date) async -> FocusStatusSnapshot {
        let center = INFocusStatusCenter.default
        let mappedAuth: FocusAuthorizationState
        switch center.authorizationStatus {
        case .authorized: mappedAuth = .authorized
        case .denied: mappedAuth = .denied
        case .restricted: mappedAuth = .restricted
        case .notDetermined: mappedAuth = .notDetermined
        @unknown default: mappedAuth = .denied
        }

        let focused: Bool? = mappedAuth == .authorized ? center.focusStatus.isFocused : nil
        return FocusActionExecutor.makeSnapshot(authorizationState: mappedAuth, isFocused: focused, now: now)
    }
}
#endif

/// Sistem Odak durumunu dürüstçe okur; sistem odağını üçüncü taraf uygulamadan gizlice değiştirmeye kalkışmaz,
/// gerekirse kullanıcının eşlediği bir Kestirme kullanmasını önerir.
public final class FocusActionExecutor: @unchecked Sendable {
    private let reader: FocusStatusReaderProtocol

    public init(reader: FocusStatusReaderProtocol) {
        self.reader = reader
    }

    public func readFocusStatus(now: Date = Date()) async -> FocusStatusSnapshot {
        await reader.readStatus(now: now)
    }

    public func suggestShortcutForFocusToggle(modeName: String, language: AgentLanguage = .turkish) -> String {
        let cleanMode = modeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = cleanMode.isEmpty ? "Çalışma" : cleanMode
        if language == .azerbaijani {
            return "Sistem Fokus rejimini birbaşa dəyişmək mümkün deyil; '\(label)' üçün Kestirmələr körpüsündən istifadə edə bilərsiniz."
        }
        return "iOS sistem Odak modunu doğrudan değiştirmeye izin vermediği için '\(label)' modunu kurulu bir Kestirme üzerinden tetikleyebilirsiniz."
    }

    public static func makeSnapshot(
        authorizationState: FocusAuthorizationState,
        isFocused: Bool?,
        now: Date
    ) -> FocusStatusSnapshot {
        let tr: String
        let az: String
        switch authorizationState {
        case .authorized:
            if isFocused == true {
                tr = "Odak modu şu an etkin; bildirimler filtreleniyor."
                az = "Fokus rejimi hazırda aktivdir; bildirişlər filtrlənir."
            } else if isFocused == false {
                tr = "Odak modu şu an kapalı."
                az = "Fokus rejimi hazırda bağlıdır."
            } else {
                tr = "Odak durumu sistem tarafından bildirilmedi."
                az = "Fokus vəziyyəti sistem tərəfindən bildirilmədi."
            }
        case .notDetermined:
            tr = "Odak durumu okuma izni henüz istenmedi."
            az = "Fokus vəziyyətini oxuma icazəsi hələ verilməyib."
        case .denied, .restricted:
            tr = "Odak durumu erişimi kapalı; durum varsayılmaz."
            az = "Fokus vəziyyətinə giriş bağlıdır."
        }
        return FocusStatusSnapshot(
            authorizationState: authorizationState,
            isFocused: isFocused,
            checkedAt: now,
            guidanceTR: tr,
            guidanceAZ: az
        )
    }
}

// MARK: - Müzik Yürütücüsü (MusicActionExecutor)

public enum MusicAuthorizationState: String, Codable, Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

public enum MusicPlaybackCommand: String, Codable, Sendable, Equatable {
    case play
    case pause
    case resume
    case nextTrack
    case previousTrack
}

public struct MusicPlaybackStatus: Codable, Equatable, Sendable {
    public let isPlaying: Bool
    public let currentTrackTitle: String?
    public let artistName: String?
    public let canPlayCatalogContent: Bool

    public init(
        isPlaying: Bool,
        currentTrackTitle: String? = nil,
        artistName: String? = nil,
        canPlayCatalogContent: Bool = true
    ) {
        self.isPlaying = isPlaying
        self.currentTrackTitle = currentTrackTitle
        self.artistName = artistName
        self.canPlayCatalogContent = canPlayCatalogContent
    }
}

public enum MusicActionOutcome: Equatable, Sendable {
    case executed(command: MusicPlaybackCommand, status: MusicPlaybackStatus)
    case subscriptionRequired(reasonTR: String)
    case permissionDenied
    case notFound(query: String)
    case failed(String)
}

public protocol MusicBackendProtocol: Sendable {
    func authorizationState() async -> MusicAuthorizationState
    func playbackStatus() async -> MusicPlaybackStatus
    func execute(command: MusicPlaybackCommand, query: String?) async throws -> MusicPlaybackStatus
}

public final class InMemoryMusicBackend: MusicBackendProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public var state: MusicAuthorizationState
    public var status: MusicPlaybackStatus
    public var knownTracks: [String: (title: String, artist: String)]
    public var executedCommands: [(command: MusicPlaybackCommand, query: String?)] = []

    public init(
        state: MusicAuthorizationState = .authorized,
        status: MusicPlaybackStatus = MusicPlaybackStatus(isPlaying: false, canPlayCatalogContent: true),
        knownTracks: [String: (title: String, artist: String)] = [:]
    ) {
        self.state = state
        self.status = status
        self.knownTracks = knownTracks
    }

    public func authorizationState() async -> MusicAuthorizationState {
        lock.withLock { state }
    }

    public func playbackStatus() async -> MusicPlaybackStatus {
        lock.withLock { status }
    }

    public func execute(command: MusicPlaybackCommand, query: String?) async throws -> MusicPlaybackStatus {
        try lock.withLock {
            executedCommands.append((command, query))
            switch command {
            case .play:
                if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let norm = TurkicTextNormalizer.normalize(query)
                    if let match = knownTracks.first(where: { TurkicTextNormalizer.normalize($0.key).contains(norm) || norm.contains(TurkicTextNormalizer.normalize($0.key)) }) {
                        status = MusicPlaybackStatus(
                            isPlaying: true,
                            currentTrackTitle: match.value.title,
                            artistName: match.value.artist,
                            canPlayCatalogContent: status.canPlayCatalogContent
                        )
                    } else if knownTracks.isEmpty {
                        status = MusicPlaybackStatus(
                            isPlaying: true,
                            currentTrackTitle: query,
                            artistName: status.artistName,
                            canPlayCatalogContent: status.canPlayCatalogContent
                        )
                    } else {
                        throw NSError(domain: "MusicAction", code: 404, userInfo: [NSLocalizedDescriptionKey: "Parça bulunamadı: \(query)"])
                    }
                } else {
                    status = MusicPlaybackStatus(
                        isPlaying: true,
                        currentTrackTitle: status.currentTrackTitle,
                        artistName: status.artistName,
                        canPlayCatalogContent: status.canPlayCatalogContent
                    )
                }
            case .resume:
                status = MusicPlaybackStatus(
                    isPlaying: true,
                    currentTrackTitle: status.currentTrackTitle,
                    artistName: status.artistName,
                    canPlayCatalogContent: status.canPlayCatalogContent
                )
            case .pause:
                status = MusicPlaybackStatus(
                    isPlaying: false,
                    currentTrackTitle: status.currentTrackTitle,
                    artistName: status.artistName,
                    canPlayCatalogContent: status.canPlayCatalogContent
                )
            case .nextTrack, .previousTrack:
                status = MusicPlaybackStatus(
                    isPlaying: status.isPlaying,
                    currentTrackTitle: status.currentTrackTitle,
                    artistName: status.artistName,
                    canPlayCatalogContent: status.canPlayCatalogContent
                )
            }
            return status
        }
    }
}

#if os(iOS) && canImport(MusicKit)
public final class LiveMusicKitBackend: MusicBackendProtocol, @unchecked Sendable {
    public init() {}

    public func authorizationState() async -> MusicAuthorizationState {
        switch MusicAuthorization.currentStatus {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    @MainActor
    public func playbackStatus() async -> MusicPlaybackStatus {
        let player = SystemMusicPlayer.shared
        let canPlayCatalog = (try? await MusicSubscription.current.canPlayCatalogContent) ?? false
        return MusicPlaybackStatus(
            isPlaying: player.state.playbackStatus == .playing,
            currentTrackTitle: player.queue.currentEntry?.title,
            artistName: nil,
            canPlayCatalogContent: canPlayCatalog
        )
    }

    @MainActor
    public func execute(command: MusicPlaybackCommand, query: String?) async throws -> MusicPlaybackStatus {
        let player = SystemMusicPlayer.shared
        switch command {
        case .play:
            if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let request = MusicCatalogSearchRequest(term: query, types: [Song.self])
                let response = try await request.response()
                guard let song = response.songs.first else {
                    throw NSError(domain: "MusicKit", code: 404, userInfo: [NSLocalizedDescriptionKey: "Parça bulunamadı: \(query)"])
                }
                player.queue = [song]
            }
            try await player.play()
        case .resume:
            try await player.play()
        case .pause:
            player.pause()
        case .nextTrack:
            try await player.skipToNextEntry()
        case .previousTrack:
            try await player.skipToPreviousEntry()
        }
        return await playbackStatus()
    }
}
#endif

public final class MusicActionExecutor: @unchecked Sendable {
    private let backend: MusicBackendProtocol

    public init(backend: MusicBackendProtocol) {
        self.backend = backend
    }

    public func handle(command: MusicPlaybackCommand, query: String? = nil) async -> MusicActionOutcome {
        let auth = await backend.authorizationState()
        guard auth == .authorized else {
            return .permissionDenied
        }

        let currentStatus = await backend.playbackStatus()
        if command == .play,
           let query,
           !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !currentStatus.canPlayCatalogContent {
            return .subscriptionRequired(reasonTR: "Apple Music katalog çalma için etkin Apple Music aboneliği gerekiyor.")
        }

        do {
            let updated = try await backend.execute(command: command, query: query)
            return .executed(command: command, status: updated)
        } catch let nsError as NSError where nsError.code == 404 {
            return .notFound(query: query ?? "")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - 6. Kalıcı Kestirme Geri Çağrı Deposu, Sağlık Testi ve V2 Köprüsü

public struct PendingShortcutCallbackRecord: Codable, Equatable, Sendable {
    public let token: String
    public let taskId: UUID
    public let revisionNumber: Int
    public let stepId: String
    public let bindingId: UUID
    public let bindingLabel: String
    public let createdAt: Date
    public let ttlSeconds: TimeInterval

    public init(
        token: String,
        taskId: UUID,
        revisionNumber: Int,
        stepId: String,
        bindingId: UUID,
        bindingLabel: String,
        createdAt: Date,
        ttlSeconds: TimeInterval = 120
    ) {
        self.token = token
        self.taskId = taskId
        self.revisionNumber = revisionNumber
        self.stepId = stepId
        self.bindingId = bindingId
        self.bindingLabel = bindingLabel
        self.createdAt = createdAt
        self.ttlSeconds = ttlSeconds
    }

    public func isExpired(at now: Date) -> Bool {
        now.timeIntervalSince(createdAt) >= ttlSeconds
    }
}

public protocol PendingShortcutCallbackStoreProtocol: Sendable {
    func save(_ record: PendingShortcutCallbackRecord) throws
    func consume(token: String) throws -> PendingShortcutCallbackRecord?
    func allPending() throws -> [PendingShortcutCallbackRecord]
    func sweepExpired(now: Date) throws -> [PendingShortcutCallbackRecord]
}

/// Kestirme x-callback dönüş token'larını uygulama kapansa bile koruyan disk kalıcılıklı depo (varsayılan 120 sn TTL).
public final class FileBackedShortcutCallbackStore: PendingShortcutCallbackStoreProtocol, @unchecked Sendable {
    public static let defaultTTLSeconds: TimeInterval = 120

    private let fileURL: URL
    private let lock = NSLock()
    private var records: [String: PendingShortcutCallbackRecord] = [:]

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            if !data.isEmpty {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                self.records = try decoder.decode([String: PendingShortcutCallbackRecord].self, from: data)
            }
        }
    }

    public static func defaultStoreURL() -> URL {
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.iagent.shared"
        ) {
            return groupURL.appendingPathComponent("ShortcutCallbacks/pending.json")
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("iAgentShortcutCallbacks", isDirectory: true)
            .appendingPathComponent("pending.json")
    }

    public func save(_ record: PendingShortcutCallbackRecord) throws {
        try lock.withLock {
            records[record.token] = record
            try persistLocked()
        }
    }

    public func consume(token: String) throws -> PendingShortcutCallbackRecord? {
        try lock.withLock {
            let removed = records.removeValue(forKey: token)
            if removed != nil {
                try persistLocked()
            }
            return removed
        }
    }

    public func allPending() throws -> [PendingShortcutCallbackRecord] {
        lock.withLock {
            Array(records.values).sorted { $0.createdAt < $1.createdAt }
        }
    }

    public func sweepExpired(now: Date) throws -> [PendingShortcutCallbackRecord] {
        try lock.withLock {
            let expired = records.values.filter { $0.isExpired(at: now) }
            if !expired.isEmpty {
                for item in expired {
                    records.removeValue(forKey: item.token)
                }
                try persistLocked()
            }
            return expired.sorted { $0.createdAt < $1.createdAt }
        }
    }

    private func persistLocked() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: Self.secureWriteOptions)
    }

    private static var secureWriteOptions: Data.WritingOptions {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        return [.atomic, .completeFileProtection]
        #else
        return [.atomic]
        #endif
    }
}

public struct ShortcutParameterSpec: Codable, Equatable, Sendable {
    public let name: String
    public let maxLength: Int
    public let allowEmpty: Bool

    public init(name: String, maxLength: Int = 512, allowEmpty: Bool = true) {
        self.name = name
        self.maxLength = maxLength
        self.allowEmpty = allowEmpty
    }
}

public struct ShortcutHealthReport: Codable, Equatable, Sendable {
    public let bindingId: UUID
    public let userLabel: String
    public let shortcutName: String
    public let isReachable: Bool
    public let status: ShortcutTestStatus
    public let checkedAt: Date
    public let detail: String

    public init(
        bindingId: UUID,
        userLabel: String,
        shortcutName: String,
        isReachable: Bool,
        status: ShortcutTestStatus,
        checkedAt: Date,
        detail: String
    ) {
        self.bindingId = bindingId
        self.userLabel = userLabel
        self.shortcutName = shortcutName
        self.isReachable = isReachable
        self.status = status
        self.checkedAt = checkedAt
        self.detail = detail
    }
}

public final class ShortcutHealthProbe: @unchecked Sendable {
    private let opener: ShortcutURLOpenerProtocol

    public init(opener: ShortcutURLOpenerProtocol) {
        self.opener = opener
    }

    public func probeBinding(
        _ binding: ShortcutBinding,
        simulatedCallbackURL: URL? = nil,
        now: Date = Date()
    ) async -> ShortcutHealthReport {
        let bridge = ShortcutsBridgeExecutor(opener: opener, initialBindings: [binding])
        do {
            let plan = try bridge.prepareLaunch(
                label: binding.userLabel,
                input: nil,
                taskId: UUID(),
                revisionNumber: 1,
                stepId: "health-probe"
            )
            let launchReceipt = await bridge.launch(plan, now: now)
            if let launchReceipt, launchReceipt.outcome == .failed {
                return ShortcutHealthReport(
                    bindingId: binding.id,
                    userLabel: binding.userLabel,
                    shortcutName: binding.shortcutName,
                    isReachable: false,
                    status: .failed,
                    checkedAt: now,
                    detail: launchReceipt.detail
                )
            }
            if let simulatedCallbackURL {
                let receipt = try bridge.handleCallbackURL(simulatedCallbackURL, now: now)
                let finalStatus: ShortcutTestStatus = receipt.outcome == .succeeded ? .verified : .missingOrRenamed
                return ShortcutHealthReport(
                    bindingId: binding.id,
                    userLabel: binding.userLabel,
                    shortcutName: binding.shortcutName,
                    isReachable: receipt.outcome == .succeeded,
                    status: finalStatus,
                    checkedAt: now,
                    detail: receipt.detail
                )
            }
            return ShortcutHealthReport(
                bindingId: binding.id,
                userLabel: binding.userLabel,
                shortcutName: binding.shortcutName,
                isReachable: false,
                status: .untested,
                checkedAt: now,
                detail: "Kestirme URL'si açıldı ancak geri çağrı yanıtı bekleniyor."
            )
        } catch {
            return ShortcutHealthReport(
                bindingId: binding.id,
                userLabel: binding.userLabel,
                shortcutName: binding.shortcutName,
                isReachable: false,
                status: .failed,
                checkedAt: now,
                detail: error.localizedDescription
            )
        }
    }
}

/// Kalıcı x-callback token deposu, 120 sn TTL zaman aşımı (`.uncertain`) ve çıktı enjeksiyon korumalı V2 kestirme yürütücüsü.
public final class ShortcutsBridgeExecutorV2: @unchecked Sendable {
    private let bridge: ShortcutsBridgeExecutor
    private let callbackStore: PendingShortcutCallbackStoreProtocol
    private let ttlSeconds: TimeInterval

    public init(
        opener: ShortcutURLOpenerProtocol,
        callbackStore: PendingShortcutCallbackStoreProtocol,
        initialBindings: [ShortcutBinding] = [],
        ttlSeconds: TimeInterval = FileBackedShortcutCallbackStore.defaultTTLSeconds
    ) {
        self.bridge = ShortcutsBridgeExecutor(opener: opener, initialBindings: initialBindings)
        self.callbackStore = callbackStore
        self.ttlSeconds = ttlSeconds
    }

    public func registerBinding(_ binding: ShortcutBinding) {
        bridge.registerBinding(binding)
    }

    public func prepareAndPersistLaunch(
        label: String,
        input: String?,
        parameterSpec: ShortcutParameterSpec = ShortcutParameterSpec(name: "input"),
        taskId: UUID,
        revisionNumber: Int,
        stepId: String,
        now: Date
    ) throws -> ShortcutLaunchPlan {
        if let input, MemorySecretGuard.containsSensitiveSecret(input) {
            throw ShortcutBridgeError.secretOrBulkDataRejected
        }
        let normalizedInput = input?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !parameterSpec.allowEmpty && (normalizedInput ?? "").isEmpty {
            throw ShortcutBridgeError.arbitraryModelURLRejected
        }
        let clippedInput = normalizedInput.map { String($0.prefix(parameterSpec.maxLength)) }
        let plan = try bridge.prepareLaunch(
            label: label,
            input: clippedInput,
            taskId: taskId,
            revisionNumber: revisionNumber,
            stepId: stepId
        )
        let record = PendingShortcutCallbackRecord(
            token: plan.callbackToken,
            taskId: taskId,
            revisionNumber: revisionNumber,
            stepId: stepId,
            bindingId: plan.binding.id,
            bindingLabel: plan.binding.userLabel,
            createdAt: now,
            ttlSeconds: ttlSeconds
        )
        try callbackStore.save(record)
        return plan
    }

    public func launch(_ plan: ShortcutLaunchPlan, now: Date) async -> ActionReceipt? {
        await bridge.launch(plan, now: now)
    }

    public func handleCallbackURL(_ url: URL, now: Date) throws -> ActionReceipt {
        guard url.scheme == "iagent", url.host == "shortcut-callback",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ShortcutBridgeError.unknownOrExpiredCallbackToken("invalid-url")
        }

        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        guard let token = query["token"],
              let pending = try callbackStore.consume(token: token) else {
            throw ShortcutBridgeError.unknownOrExpiredCallbackToken(query["token"] ?? "")
        }

        if pending.isExpired(at: now) {
            return ActionReceipt(
                taskId: pending.taskId,
                revisionNumber: pending.revisionNumber,
                stepId: pending.stepId,
                executorName: "ShortcutsBridgeV2",
                outcome: .uncertain,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Kestirme yanıt süresi aşıldı",
                spokenVerbAZ: "Qısayol cavab müddəti bitdi",
                detail: "120 sn bekleme süresi aşıldığı için sonuç belirsiz işaretlendi."
            )
        }

        // Bellek içi köprüde mevcutsa durumunu da güncelle; her durumda kalıcı kayıt ve sanitizasyonla tutarlı makbuz üret.
        _ = try? bridge.handleCallbackURL(url, now: now)

        let status = query["status"] ?? "error"
        switch status {
        case "success":
            let rawOutput = query["result"] ?? ""
            let sanitized = PromptInjectionSanitizer.sanitize(rawOutput)
            return ActionReceipt(
                taskId: pending.taskId,
                revisionNumber: pending.revisionNumber,
                stepId: pending.stepId,
                executorName: "ShortcutsBridgeV2",
                outcome: .succeeded,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Kestirme tamamlandı",
                spokenVerbAZ: "Qısayol tamamlandı",
                detail: sanitized.isEmpty ? "Kestirme başarıyla döndü." : "Kestirme çıktısı (temizlenmiş): \(sanitized)"
            )
        case "cancel":
            return ActionReceipt(
                taskId: pending.taskId,
                revisionNumber: pending.revisionNumber,
                stepId: pending.stepId,
                executorName: "ShortcutsBridgeV2",
                outcome: .cancelled,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Kestirme iptal edildi",
                spokenVerbAZ: "Qısayol ləğv edildi",
                detail: "Kullanıcı Kestirmeler akışını iptal etti."
            )
        default:
            let errMsg = query["errorMessage"] ?? "Kestirme bulunamadı veya hata döndürdü."
            return ActionReceipt(
                taskId: pending.taskId,
                revisionNumber: pending.revisionNumber,
                stepId: pending.stepId,
                executorName: "ShortcutsBridgeV2",
                outcome: .failed,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Kestirme çalıştırılamadı",
                spokenVerbAZ: "Qısayol işə salına bilmədi",
                detail: errMsg
            )
        }
    }

    public func reapExpiredCallbacks(now: Date) throws -> [ActionReceipt] {
        let expired = try callbackStore.sweepExpired(now: now)
        return expired.map { pending in
            ActionReceipt(
                taskId: pending.taskId,
                revisionNumber: pending.revisionNumber,
                stepId: pending.stepId,
                executorName: "ShortcutsBridgeV2",
                outcome: .uncertain,
                timestamp: now,
                canUndo: false,
                spokenVerbTR: "Kestirmeden dönüş alınamadı",
                spokenVerbAZ: "Qısayoldan cavab alınmadı",
                detail: "'\(pending.bindingLabel)' için 120 sn içinde geri çağrı dönmedi; sonuç doğrulanamadı."
            )
        }
    }
}

// MARK: - 7. Çok Modlu Belge Doğrulayıcıları: Fiş/KDV ve IATA BCBP Barkod

public struct ReceiptMathValidationResult: Codable, Equatable, Sendable {
    public let isValid: Bool
    public let subtotal: Double?
    public let kdvAmount: Double?
    public let total: Double
    public let discrepancy: Double
    public let reasonTR: String

    public init(
        isValid: Bool,
        subtotal: Double?,
        kdvAmount: Double?,
        total: Double,
        discrepancy: Double,
        reasonTR: String
    ) {
        self.isValid = isValid
        self.subtotal = subtotal
        self.kdvAmount = kdvAmount
        self.total = total
        self.discrepancy = discrepancy
        self.reasonTR = reasonTR
    }
}

public struct ParsedTurkishReceipt: Codable, Equatable, Sendable {
    public let merchantName: String?
    public let subtotal: Double?
    public let kdvAmount: Double?
    public let total: Double?
    public let validation: ReceiptMathValidationResult?

    public init(
        merchantName: String?,
        subtotal: Double?,
        kdvAmount: Double?,
        total: Double?,
        validation: ReceiptMathValidationResult?
    ) {
        self.merchantName = merchantName
        self.subtotal = subtotal
        self.kdvAmount = kdvAmount
        self.total = total
        self.validation = validation
    }
}

/// Türkçe POS fişi ve e-Arşiv faturası satırlarından Ara Toplam / KDV / Genel Toplam çıkarır ve matematiğini doğrular.
public struct TurkishReceiptMathValidator: Sendable {
    public init() {}

    public func validate(
        subtotal: Double?,
        kdvAmount: Double?,
        total: Double,
        tolerance: Double = 0.05
    ) -> ReceiptMathValidationResult {
        Self.validate(subtotal: subtotal, kdvAmount: kdvAmount, total: total, tolerance: tolerance)
    }

    public static func validate(
        subtotal: Double?,
        kdvAmount: Double?,
        total: Double,
        tolerance: Double = 0.05
    ) -> ReceiptMathValidationResult {
        guard total.isFinite, total >= 0, tolerance >= 0 else {
            return ReceiptMathValidationResult(
                isValid: false,
                subtotal: subtotal,
                kdvAmount: kdvAmount,
                total: total,
                discrepancy: abs(total),
                reasonTR: "Geçersiz veya negatif genel toplam tutarı."
            )
        }
        if let subtotal, (!subtotal.isFinite || subtotal < 0) {
            return ReceiptMathValidationResult(
                isValid: false,
                subtotal: subtotal,
                kdvAmount: kdvAmount,
                total: total,
                discrepancy: abs(subtotal),
                reasonTR: "Geçersiz veya negatif ara toplam tutarı."
            )
        }
        if let kdvAmount, (!kdvAmount.isFinite || kdvAmount < 0) {
            return ReceiptMathValidationResult(
                isValid: false,
                subtotal: subtotal,
                kdvAmount: kdvAmount,
                total: total,
                discrepancy: abs(kdvAmount),
                reasonTR: "Geçersiz veya negatif KDV tutarı."
            )
        }

        if let subtotal, let kdvAmount {
            let expectedTotal = subtotal + kdvAmount
            let diff = (abs(expectedTotal - total) * 10_000).rounded() / 10_000
            if diff <= tolerance + 1e-9 {
                return ReceiptMathValidationResult(
                    isValid: true,
                    subtotal: subtotal,
                    kdvAmount: kdvAmount,
                    total: total,
                    discrepancy: diff,
                    reasonTR: "Ara toplam ve KDV toplamı genel toplam ile tutarlıdır."
                )
            }
            return ReceiptMathValidationResult(
                isValid: false,
                subtotal: subtotal,
                kdvAmount: kdvAmount,
                total: total,
                discrepancy: diff,
                reasonTR: String(
                    format: "Fiş toplam tutarsızlığı: Ara toplam + KDV (%.2f) ile genel toplam (%.2f) arasında %.2f TL fark var.",
                    expectedTotal,
                    total,
                    diff
                )
            )
        }

        if let kdvAmount {
            if kdvAmount > total + tolerance + 1e-9 {
                let diff = (abs(kdvAmount - total) * 10_000).rounded() / 10_000
                return ReceiptMathValidationResult(
                    isValid: false,
                    subtotal: nil,
                    kdvAmount: kdvAmount,
                    total: total,
                    discrepancy: diff,
                    reasonTR: "KDV tutarı genel toplamdan büyük olamaz."
                )
            }
            return ReceiptMathValidationResult(
                isValid: true,
                subtotal: nil,
                kdvAmount: kdvAmount,
                total: total,
                discrepancy: 0,
                reasonTR: "KDV tutarı genel toplam sınırı içinde tutarlı."
            )
        }

        if let subtotal {
            if subtotal > total + tolerance + 1e-9 {
                let diff = (abs(subtotal - total) * 10_000).rounded() / 10_000
                return ReceiptMathValidationResult(
                    isValid: false,
                    subtotal: subtotal,
                    kdvAmount: nil,
                    total: total,
                    discrepancy: diff,
                    reasonTR: "Ara toplam genel toplamdan büyük olamaz."
                )
            }
            return ReceiptMathValidationResult(
                isValid: true,
                subtotal: subtotal,
                kdvAmount: nil,
                total: total,
                discrepancy: 0,
                reasonTR: "Ara toplam genel toplam ile uyumlu."
            )
        }

        return ReceiptMathValidationResult(
            isValid: true,
            subtotal: nil,
            kdvAmount: nil,
            total: total,
            discrepancy: 0,
            reasonTR: "Yalnız genel toplam satırı doğrulandı."
        )
    }

    public func parseReceiptText(_ rawText: String) -> ParsedTurkishReceipt {
        Self.parseReceiptText(rawText)
    }

    public static func parseReceiptText(_ rawText: String) -> ParsedTurkishReceipt {
        let sanitized = PromptInjectionSanitizer.sanitize(rawText)
        let lines = sanitized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var merchantName: String?
        var subtotal: Double?
        var topKDV: Double?
        var itemizedKDVSum: Double = 0
        var hasItemizedKDV = false
        var total: Double?

        for line in lines {
            let norm = TurkicTextNormalizer.normalize(line)

            if merchantName == nil && isLikelyMerchantLine(norm: norm, rawLine: line) {
                merchantName = line
            }

            if norm.contains("ara toplam") || norm.contains("aratoplam") || norm.contains("matrah") || norm.contains("kdv haric") || norm.contains("subtotal") {
                if let amount = parseLastMonetaryAmount(from: line) {
                    subtotal = amount
                }
                continue
            }

            if norm.contains("topkdv") || norm.contains("top kdv") || norm.contains("kdv toplam") || norm.contains("toplam kdv") {
                if let amount = parseLastMonetaryAmount(from: line) {
                    topKDV = amount
                }
                continue
            }

            if norm.contains("genel toplam") || norm.contains("toplam") || norm.contains("odenecek") || norm.contains("total") {
                if !norm.contains("kdv") {
                    if let amount = parseLastMonetaryAmount(from: line) {
                        total = amount
                    }
                    continue
                }
            }

            if norm.contains("kdv") {
                if let amount = parseLastMonetaryAmount(from: line) {
                    itemizedKDVSum += amount
                    hasItemizedKDV = true
                }
            }
        }

        let resolvedKDV = topKDV ?? (hasItemizedKDV ? (itemizedKDVSum * 100).rounded() / 100 : nil)
        let validation = total.map { validate(subtotal: subtotal, kdvAmount: resolvedKDV, total: $0) }

        return ParsedTurkishReceipt(
            merchantName: merchantName,
            subtotal: subtotal,
            kdvAmount: resolvedKDV,
            total: total,
            validation: validation
        )
    }

    private static func isLikelyMerchantLine(norm: String, rawLine: String) -> Bool {
        if norm.contains("tarih") || norm.contains("saat") || norm.contains("fis no")
            || norm.contains("toplam") || norm.contains("kdv") || norm.contains("vkn")
            || norm.contains("mersis") || norm.contains("izole_edilmis") {
            return false
        }
        return rawLine.contains(where: { $0.isLetter })
    }

    private static func parseLastMonetaryAmount(from line: String) -> Double? {
        // "%20" veya "20%" gibi vergi oranlarını parasal tutarla karıştırmamak için temizle.
        let withoutPercentages = line
            .replacingOccurrences(of: #"%\s*\d+(?:[.,]\d+)?"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\d+(?:[.,]\d+)?\s*%"#, with: " ", options: .regularExpression)

        let pattern = #"(?<!\d)(\d{1,3}(?:\.\d{3})*,\d{1,2}|\d+,\d{1,2}|\d+(?:,\d{3})*\.\d{1,2}|\d+)(?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(withoutPercentages.startIndex..., in: withoutPercentages)
        let matches = regex.matches(in: withoutPercentages, options: [], range: range)
        guard let last = matches.last,
              let swiftRange = Range(last.range(at: 1), in: withoutPercentages) else {
            return nil
        }
        var token = String(withoutPercentages[swiftRange])
        if token.contains(".") && token.contains(",") {
            token = token.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else if token.contains(",") {
            token = token.replacingOccurrences(of: ",", with: ".")
        }
        return Double(token)
    }
}

public struct BoardingPassRecord: Codable, Equatable, Sendable {
    public let formatCode: String
    public let legCount: Int
    public let passengerName: String
    public let pnrCode: String
    public let departureAirport: String
    public let arrivalAirport: String
    public let carrierCode: String
    public let flightNumber: String
    public let julianDayOfYear: Int?
    public let compartmentCode: String?
    public let seatNumber: String?
    public let checkInSequence: String?

    public var fullFlightDesignator: String {
        "\(carrierCode)\(flightNumber)"
    }

    public init(
        formatCode: String = "M",
        legCount: Int,
        passengerName: String,
        pnrCode: String,
        departureAirport: String,
        arrivalAirport: String,
        carrierCode: String,
        flightNumber: String,
        julianDayOfYear: Int? = nil,
        compartmentCode: String? = nil,
        seatNumber: String? = nil,
        checkInSequence: String? = nil
    ) {
        self.formatCode = formatCode
        self.legCount = legCount
        self.passengerName = passengerName
        self.pnrCode = pnrCode
        self.departureAirport = departureAirport
        self.arrivalAirport = arrivalAirport
        self.carrierCode = carrierCode
        self.flightNumber = flightNumber
        self.julianDayOfYear = julianDayOfYear
        self.compartmentCode = compartmentCode
        self.seatNumber = seatNumber
        self.checkInSequence = checkInSequence
    }
}

/// IATA Resolution 792 (M1) biniş kartı barkodunu sabit genişlikli alanlardan deterministik olarak ayrıştırır.
public struct IATABCBPParser: Sendable {
    public init() {}

    public func parse(_ rawBarcode: String) -> BoardingPassRecord? {
        Self.parse(rawBarcode)
    }

    public static func parse(_ rawBarcode: String) -> BoardingPassRecord? {
        // Sabit genişlikli alan ofsetlerini korumak için yalnızca satır başı/sonu yeni satır ve baştaki boşluklar temizlenir.
        let cleanedNewlines = rawBarcode.trimmingCharacters(in: .newlines)
        guard let mIndex = cleanedNewlines.firstIndex(of: "M") else {
            return nil
        }
        let prefixBeforeM = cleanedNewlines[..<mIndex]
        guard prefixBeforeM.allSatisfy({ $0.isWhitespace }) else {
            return nil
        }

        let candidate = String(cleanedNewlines[mIndex...])
        let chars = Array(candidate)
        guard chars.count >= 58 else {
            return nil
        }
        guard chars[0] == "M",
              let legCount = Int(String(chars[1])),
              (1...9).contains(legCount) else {
            return nil
        }

        func slice(_ start: Int, _ end: Int) -> String {
            String(chars[start..<end])
        }

        let rawPassengerName = slice(2, 22).trimmingCharacters(in: .whitespaces)
        let passengerName = PromptInjectionSanitizer.sanitize(rawPassengerName)
        guard !passengerName.isEmpty else {
            return nil
        }

        let pnrCode = slice(23, 30).trimmingCharacters(in: .whitespaces)
        let departureAirport = slice(30, 33).trimmingCharacters(in: .whitespaces)
        let arrivalAirport = slice(33, 36).trimmingCharacters(in: .whitespaces)
        let carrierCode = slice(36, 39).trimmingCharacters(in: .whitespaces)
        let flightNumber = slice(39, 44).trimmingCharacters(in: .whitespaces)
        let julianRaw = slice(44, 47).trimmingCharacters(in: .whitespaces)
        let compartment = slice(47, 48).trimmingCharacters(in: .whitespaces)
        let seat = slice(48, 52).trimmingCharacters(in: .whitespaces)
        let sequence = slice(52, 57).trimmingCharacters(in: .whitespaces)

        guard isThreeUppercaseASCIILetters(departureAirport),
              isThreeUppercaseASCIILetters(arrivalAirport),
              !pnrCode.isEmpty,
              !carrierCode.isEmpty,
              !flightNumber.isEmpty else {
            return nil
        }

        let julianDay = Int(julianRaw)
        return BoardingPassRecord(
            formatCode: "M",
            legCount: legCount,
            passengerName: passengerName,
            pnrCode: pnrCode,
            departureAirport: departureAirport,
            arrivalAirport: arrivalAirport,
            carrierCode: carrierCode,
            flightNumber: flightNumber,
            julianDayOfYear: julianDay,
            compartmentCode: compartment.isEmpty ? nil : compartment,
            seatNumber: seat.isEmpty ? nil : seat,
            checkInSequence: sequence.isEmpty ? nil : sequence
        )
    }

    private static func isThreeUppercaseASCIILetters(_ code: String) -> Bool {
        code.count == 3 && code.unicodeScalars.allSatisfy { (65...90).contains($0.value) }
    }
}
