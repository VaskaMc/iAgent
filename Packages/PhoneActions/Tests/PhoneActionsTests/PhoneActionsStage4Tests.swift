import XCTest
import AgentCore
@testable import PhoneActions

final class PhoneActionsStage4Tests: XCTestCase {
    func testCalendarReadDistinguishesLockedDeniedWriteOnlyAndEmpty() async throws {
        let bakuTZ = TimeZone(identifier: "Asia/Baku")!
        let nov21 = ISO8601DateFormatter().date(from: "2026-11-21T12:00:00+04:00")!

        // 1. Locked device blocks read
        let fullBackend = InMemoryCalendarBackend(state: .fullAccess)
        let executor = CalendarActionExecutor(backend: fullBackend)
        let lockedResult = await executor.querySchedule(for: nov21, timeZone: bakuTZ, isDeviceLocked: true)
        XCTAssertEqual(lockedResult, .deviceLockedRequiresAuthentication)

        // 2. Empty schedule when unlocked and fullAccess
        let emptyResult = await executor.querySchedule(for: nov21, timeZone: bakuTZ, isDeviceLocked: false)
        XCTAssertEqual(emptyResult, .emptySchedule)

        // 3. Denied permission is NOT reported as empty schedule
        fullBackend.state = .denied
        let deniedResult = await executor.querySchedule(for: nov21, timeZone: bakuTZ, isDeviceLocked: false)
        XCTAssertEqual(deniedResult, .permissionDenied)

        // 4. Write-only permission refuses read and saves directly to default calendar without listing
        fullBackend.state = .writeOnly
        let writeOnlyRead = await executor.querySchedule(for: nov21, timeZone: bakuTZ, isDeviceLocked: false)
        XCTAssertEqual(writeOnlyRead, .writeOnlyCannotReadSchedule)
        XCTAssertFalse(fullBackend.readAttemptedInWriteOnly)

        let writeResult = await executor.createEvent(
            title: "Cuma Çalışma",
            startDate: nov21.addingTimeInterval(3600),
            durationMinutes: 30
        )
        guard case .saved(_, _, _, _, let usedWriteOnly) = writeResult else {
            return XCTFail("Expected saved in write-only mode")
        }
        XCTAssertTrue(usedWriteOnly)
        XCTAssertFalse(fullBackend.listCalendarsAttempted)
    }

    func testReminderAlarmAndRelativeDateResolution() async throws {
        let bakuTZ = TimeZone(identifier: "Asia/Baku")!
        let nov21 = ISO8601DateFormatter().date(from: "2026-11-21T12:00:00+04:00")!

        // "yarın 10'da" -> 2026-11-22T10:00:00+04:00
        let meetingResult = DateAndTimeResolver.resolve(
            expression: "yarın 10'da",
            referenceDate: nov21,
            timeZone: bakuTZ
        )
        guard case .resolved(let meetingDate, let meetingISO) = meetingResult else {
            return XCTFail("Expected resolved date for yarın 10'da")
        }
        XCTAssertEqual(meetingISO, "2026-11-22T10:00:00+04:00")

        // "yarım saat önce" -> 2026-11-22T09:30:00+04:00
        let reminderResult = DateAndTimeResolver.resolve(
            expression: "yarım saat önce",
            referenceDate: nov21,
            timeZone: bakuTZ,
            relativeToBaseStart: meetingDate
        )
        guard case .resolved(let reminderDate, let reminderISO) = reminderResult else {
            return XCTFail("Expected resolved date for yarım saat önce")
        }
        XCTAssertEqual(reminderISO, "2026-11-22T09:30:00+04:00")

        // Save reminder and verify EKAlarm date matches dueDate
        let remBackend = InMemoryRemindersBackend(state: .fullAccess)
        let remExecutor = RemindersActionExecutor(backend: remBackend)
        let saveOutcome = await remExecutor.createReminder(
            title: "Sunumu aç",
            dueDate: reminderDate,
            timeZone: bakuTZ
        )
        guard case .saved(let record) = saveOutcome else {
            return XCTFail("Expected saved reminder")
        }
        XCTAssertEqual(record.alarmAbsoluteDate, reminderDate)
        XCTAssertEqual(record.timeZoneIdentifier, "Asia/Baku")

        // Location reminder in v1 offers time or shortcut
        let locOutcome = await remExecutor.createReminder(
            title: "Süt al",
            dueDate: reminderDate,
            timeZone: bakuTZ,
            locationRequested: true
        )
        guard case .locationNotSupportedOfferTimeOrShortcut = locOutcome else {
            return XCTFail("Expected location guidance")
        }

        // Ambiguous "cuma akşamı" asks for explicit date/time
        let ambiguous = DateAndTimeResolver.resolve(
            expression: "cuma akşamı toplantı",
            referenceDate: nov21,
            timeZone: bakuTZ
        )
        guard case .ambiguous = ambiguous else {
            return XCTFail("Expected ambiguous")
        }
    }
}
