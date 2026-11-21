import Foundation
import AgentCore

#if canImport(EventKit)
import EventKit
#endif

public enum CalendarAuthorizationState: String, Codable, Sendable, Equatable {
    case notDetermined
    case fullAccess
    case writeOnly
    case denied
    case restricted
}

public struct CalendarEventRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let calendarTitle: String

    public init(id: String, title: String, startDate: Date, endDate: Date, calendarTitle: String) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.calendarTitle = calendarTitle
    }
}

public enum CalendarReadOutcome: Equatable, Sendable {
    case events([CalendarEventRecord])
    case emptySchedule
    case permissionDenied
    case writeOnlyCannotReadSchedule
    case deviceLockedRequiresAuthentication
    case readError(String)
}

public enum CalendarCreateOutcome: Equatable, Sendable {
    case saved(eventId: String, title: String, startDate: Date, endDate: Date, usedWriteOnlyDefaultCalendar: Bool)
    case handedOffToEventEditor(title: String, startDate: Date, endDate: Date)
    case permissionDenied
    case failed(String)
}

public protocol CalendarBackendProtocol: Sendable {
    func authorizationState() async -> CalendarAuthorizationState
    func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEventRecord]
    func saveEvent(title: String, startDate: Date, endDate: Date, allowCalendarListing: Bool) async throws -> String
    func deleteEvent(identifier: String) async throws
}

/// Test ve simülatör için bellek içi takvim arka ucu; writeOnly modunda okuma/listeleme çağrılarını reddeder.
public final class InMemoryCalendarBackend: CalendarBackendProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public var state: CalendarAuthorizationState
    public var events: [CalendarEventRecord] = []
    public var listCalendarsAttempted = false
    public var readAttemptedInWriteOnly = false
    public var simulatedReadError: Error?

    public init(state: CalendarAuthorizationState = .fullAccess, events: [CalendarEventRecord] = []) {
        self.state = state
        self.events = events
    }

    public func authorizationState() async -> CalendarAuthorizationState {
        lock.withLock { state }
    }

    public func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEventRecord] {
        try lock.withLock {
            if state == .writeOnly {
                readAttemptedInWriteOnly = true
                throw NSError(domain: "CalendarAction", code: 403, userInfo: [NSLocalizedDescriptionKey: "Write-only izniyle okuma yapılamaz"])
            }
            if let simulatedReadError {
                throw simulatedReadError
            }
            return events.filter { $0.startDate >= start && $0.startDate <= end }
        }
    }

    public func saveEvent(title: String, startDate: Date, endDate: Date, allowCalendarListing: Bool) async throws -> String {
        lock.withLock {
            if allowCalendarListing && state == .writeOnly {
                listCalendarsAttempted = true
            }
            let id = "ev-\(UUID().uuidString.prefix(8))"
            events.append(
                CalendarEventRecord(
                    id: id,
                    title: title,
                    startDate: startDate,
                    endDate: endDate,
                    calendarTitle: state == .writeOnly ? "Varsayılan" : "Kişisel"
                )
            )
            return id
        }
    }

    public func deleteEvent(identifier: String) async throws {
        lock.withLock {
            events.removeAll { $0.id == identifier }
        }
    }
}

#if canImport(EventKit)
public final class LiveEventKitCalendarBackend: CalendarBackendProtocol, @unchecked Sendable {
    private let store = EKEventStore()
    public init() {}

    public func authorizationState() async -> CalendarAuthorizationState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    public func fetchEvents(from start: Date, to end: Date) async throws -> [CalendarEventRecord] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { ev in
            CalendarEventRecord(
                id: ev.eventIdentifier ?? UUID().uuidString,
                title: ev.title ?? "",
                startDate: ev.startDate,
                endDate: ev.endDate,
                calendarTitle: ev.calendar?.title ?? ""
            )
        }
    }

    public func saveEvent(title: String, startDate: Date, endDate: Date, allowCalendarListing: Bool) async throws -> String {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        // Yalnız yazma izninde takvimleri listelemeye veya geri okumaya çalışılmaz; varsayılan takvim kullanılır.
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier ?? UUID().uuidString
    }

    public func deleteEvent(identifier: String) async throws {
        if let existing = store.event(withIdentifier: identifier) {
            try store.remove(existing, span: .thisEvent, commit: true)
        }
    }
}
#endif

/// Takvim okuma ve yazma izinlerini kesin biçimde ayıran yürütücü.
public final class CalendarActionExecutor: @unchecked Sendable {
    private let backend: CalendarBackendProtocol

    public init(backend: CalendarBackendProtocol) {
        self.backend = backend
    }

    public func querySchedule(
        for day: Date,
        timeZone: TimeZone,
        isDeviceLocked: Bool
    ) async -> CalendarReadOutcome {
        // Kilit açılmadan özel ajanda okunmaz.
        guard !isDeviceLocked else {
            return .deviceLockedRequiresAuthentication
        }

        let auth = await backend.authorizationState()
        switch auth {
        case .denied, .restricted, .notDetermined:
            return .permissionDenied
        case .writeOnly:
            // Yalnız yazma izniyle takvim okuma girişimi yapılmaz.
            return .writeOnlyCannotReadSchedule
        case .fullAccess:
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let startOfDay = cal.startOfDay(for: day)
            guard let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else {
                return .readError("Gün aralığı hesaplanamadı.")
            }
            do {
                let events = try await backend.fetchEvents(from: startOfDay, to: endOfDay)
                return events.isEmpty ? .emptySchedule : .events(events)
            } catch {
                return .readError(error.localizedDescription)
            }
        }
    }

    public func createEvent(
        title: String,
        startDate: Date,
        durationMinutes: Int,
        preferSystemEditor: Bool = false
    ) async -> CalendarCreateOutcome {
        let endDate = startDate.addingTimeInterval(TimeInterval(durationMinutes * 60))
        if preferSystemEditor {
            return .handedOffToEventEditor(title: title, startDate: startDate, endDate: endDate)
        }

        let auth = await backend.authorizationState()
        switch auth {
        case .denied, .restricted, .notDetermined:
            return .permissionDenied
        case .writeOnly:
            do {
                // Yalnız yazma izni: takvim listesi okunmaz, varsayılan takvime tek kayıt yazılır ve geri okunmaz.
                let eventId = try await backend.saveEvent(
                    title: title,
                    startDate: startDate,
                    endDate: endDate,
                    allowCalendarListing: false
                )
                return .saved(
                    eventId: eventId,
                    title: title,
                    startDate: startDate,
                    endDate: endDate,
                    usedWriteOnlyDefaultCalendar: true
                )
            } catch {
                return .failed(error.localizedDescription)
            }
        case .fullAccess:
            do {
                let eventId = try await backend.saveEvent(
                    title: title,
                    startDate: startDate,
                    endDate: endDate,
                    allowCalendarListing: true
                )
                return .saved(
                    eventId: eventId,
                    title: title,
                    startDate: startDate,
                    endDate: endDate,
                    usedWriteOnlyDefaultCalendar: false
                )
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }
}
