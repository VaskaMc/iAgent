import XCTest
@testable import AgentCore

final class QuickNoteFlowTests: XCTestCase {
    private func makeTempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("iagent-tests-\(UUID().uuidString)")
            .appendingPathComponent("notes.json")
    }

    func testNotePersistenceAcrossReloadAndUndo() throws {
        let url = makeTempStoreURL()
        let taskId = UUID()
        let now = Date(timeIntervalSince1970: 1_795_256_400) // 2026-11-21

        let store1 = try FileBackedNoteStore(fileURL: url)
        let flow1 = QuickNoteFlow(noteStore: store1)

        let outcome = try flow1.executeDirectIfMatched(
            utterance: "Şunu not al: Alışveriş listesi süt ve ekmek",
            taskId: taskId,
            now: now
        )

        guard case .noteCreated(let createdNote, _) = outcome else {
            return XCTFail("Expected noteCreated, got \(outcome)")
        }

        // Reopen store to simulate app relaunch
        let store2 = try FileBackedNoteStore(fileURL: url)
        let activeNotes = try store2.allActiveNotes()
        XCTAssertEqual(activeNotes.count, 1)
        XCTAssertEqual(activeNotes[0].id, createdNote.id)
        XCTAssertEqual(activeNotes[0].content, "Alışveriş listesi süt ve ekmek")

        // Search using accent-insensitive Turkish query
        let flow2 = QuickNoteFlow(noteStore: store2)
        let searchOutcome = try flow2.executeDirectIfMatched(
            utterance: "Dün yazdığım alışveriş notunu bul",
            taskId: UUID(),
            now: now
        )
        guard case .notesFound(_, let matches, _) = searchOutcome else {
            return XCTFail("Expected notesFound")
        }
        XCTAssertEqual(matches.map(\.id), [createdNote.id])

        // Undo note creation
        _ = try store2.undoCreate(noteId: createdNote.id, now: now.addingTimeInterval(5))
        let afterUndo = try FileBackedNoteStore(fileURL: url).allActiveNotes()
        XCTAssertTrue(afterUndo.isEmpty)
    }

    func testCancelledDraftWritesNothingToDisk() throws {
        let url = makeTempStoreURL()
        let store = try FileBackedNoteStore(fileURL: url)
        let flow = QuickNoteFlow(noteStore: store)

        var draft = try XCTUnwrap(
            flow.prepareDraft(from: "Not ekle: Kaydedilmeyecek taslak", taskId: UUID())
        )
        let cancelOutcome = flow.cancelPendingNote(&draft)
        guard case .draftCancelled = cancelOutcome else {
            return XCTFail("Expected draftCancelled")
        }

        let confirmAfterCancel = try flow.confirmDraft(draft, now: Date())
        guard case .draftCancelled = confirmAfterCancel else {
            return XCTFail("Cancelled draft must not persist")
        }

        let reloaded = try FileBackedNoteStore(fileURL: url).allActiveNotes()
        XCTAssertTrue(reloaded.isEmpty)
    }
}
