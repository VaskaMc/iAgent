import Foundation
import AgentCore

#if canImport(EventKit)
import EventKit
#endif

public enum RemindersAuthorizationState: String, Codable, Sendable, Equatable {
    case notDetermined
    case fullAccess
    case denied
    case restricted
}

public struct ReminderRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let dueDate: Date
    public let alarmAbsoluteDate: Date
    public let timeZoneIdentifier: String

    public init(
        id: String,
        title: String,
        dueDate: Date,
        alarmAbsoluteDate: Date,
        timeZoneIdentifier: String
    ) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.alarmAbsoluteDate = alarmAbsoluteDate
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public enum ReminderCreateOutcome: Equatable, Sendable {
    case saved(ReminderRecord)
    case locationNotSupportedOfferTimeOrShortcut(String)
    case permissionDenied
    case failed(String)
}

public protocol RemindersBackendProtocol: Sendable {
    func authorizationState() async -> RemindersAuthorizationState
    func saveReminder(title: String, dueDate: Date, timeZone: TimeZone) async throws -> ReminderRecord
}

public final class InMemoryRemindersBackend: RemindersBackendProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public var state: RemindersAuthorizationState
    public var savedReminders: [ReminderRecord] = []

    public init(state: RemindersAuthorizationState = .fullAccess) {
        self.state = state
    }

    public func authorizationState() async -> RemindersAuthorizationState {
        lock.withLock { state }
    }

    public func saveReminder(title: String, dueDate: Date, timeZone: TimeZone) async throws -> ReminderRecord {
        lock.withLock {
            let record = ReminderRecord(
                id: "rem-\(UUID().uuidString.prefix(8))",
                title: title,
                dueDate: dueDate,
                alarmAbsoluteDate: dueDate,
                timeZoneIdentifier: timeZone.identifier
            )
            savedReminders.append(record)
            return record
        }
    }
}

#if canImport(EventKit)
public final class LiveEventKitRemindersBackend: RemindersBackendProtocol, @unchecked Sendable {
    private let store = EKEventStore()
    public init() {}

    public func authorizationState() async -> RemindersAuthorizationState {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .notDetermined: return .notDetermined
        case .fullAccess: return .fullAccess
        case .denied, .writeOnly: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    public func saveReminder(title: String, dueDate: Date, timeZone: TimeZone) async throws -> ReminderRecord {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = store.defaultCalendarForNewReminders()

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let components = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: dueDate)
        reminder.startDateComponents = components
        reminder.dueDateComponents = components
        // İstenen saate tam EKAlarm eklenir.
        reminder.addAlarm(EKAlarm(absoluteDate: dueDate))

        try store.save(reminder, commit: true)
        return ReminderRecord(
            id: reminder.calendarItemIdentifier,
            title: title,
            dueDate: dueDate,
            alarmAbsoluteDate: dueDate,
            timeZoneIdentifier: timeZone.identifier
        )
    }
}
#endif

/// Ayrı Anımsatıcılar izniyle zaman bazlı anımsatıcı ve EKAlarm oluşturan yürütücü.
public final class RemindersActionExecutor: @unchecked Sendable {
    private let backend: RemindersBackendProtocol

    public init(backend: RemindersBackendProtocol) {
        self.backend = backend
    }

    public func createReminder(
        title: String,
        dueDate: Date,
        timeZone: TimeZone,
        locationRequested: Bool = false
    ) async -> ReminderCreateOutcome {
        if locationRequested {
            return .locationNotSupportedOfferTimeOrShortcut(
                "İlk sürümde konuma bağlı anımsatıcı doğrudan oluşturulmuyor; bir saat seçebilir veya kurulu Kestirmeni çalıştırabilirsin."
            )
        }

        let auth = await backend.authorizationState()
        guard auth == .fullAccess else {
            return .permissionDenied
        }

        do {
            let record = try await backend.saveReminder(title: title, dueDate: dueDate, timeZone: timeZone)
            return .saved(record)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
