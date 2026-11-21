import XCTest
import AgentCore
@testable import PhoneActions

final class PhoneActionsStage6Tests: XCTestCase {
    func testShortcutLifecycleSuccessCancelRenamedAndUnverifiedTimeout() async throws {
        let opener = MockShortcutURLOpener()
        let binding = ShortcutBinding(
            userLabel: "Çalışma Modu",
            shortcutName: "CalismaModumuBaslat",
            acceptedInput: .text
        )
        let bridge = ShortcutsBridgeExecutor(opener: opener, initialBindings: [binding])
        let now = Date(timeIntervalSince1970: 1_795_256_400)

        // 1. Success via single-use callback token
        let plan1 = try bridge.prepareLaunch(
            label: "Çalışma Modu",
            input: "start",
            taskId: UUID(),
            revisionNumber: 1,
            stepId: "sc1"
        )
        _ = await bridge.launch(plan1, now: now)
        let successURL = URL(string: "iagent://shortcut-callback?status=success&token=\(plan1.callbackToken)&result=OK")!
        let receipt1 = try bridge.handleCallbackURL(successURL, now: now)
        XCTAssertEqual(receipt1.outcome, .succeeded)

        // Replay of same token must fail
        XCTAssertThrowsError(try bridge.handleCallbackURL(successURL, now: now))

        // 2. Cancel callback
        let plan2 = try bridge.prepareLaunch(label: "Çalışma Modu", input: nil, taskId: UUID(), revisionNumber: 1, stepId: "sc2")
        let cancelURL = URL(string: "iagent://shortcut-callback?status=cancel&token=\(plan2.callbackToken)")!
        let receipt2 = try bridge.handleCallbackURL(cancelURL, now: now)
        XCTAssertEqual(receipt2.outcome, .cancelled)

        // 3. Deleted or renamed shortcut error
        let plan3 = try bridge.prepareLaunch(label: "Çalışma Modu", input: nil, taskId: UUID(), revisionNumber: 1, stepId: "sc3")
        let errorURL = URL(string: "iagent://shortcut-callback?status=error&token=\(plan3.callbackToken)&errorMessage=Kestirme%20silinmis")!
        let receipt3 = try bridge.handleCallbackURL(errorURL, now: now)
        XCTAssertEqual(receipt3.outcome, .failed)
        XCTAssertEqual(bridge.binding(forLabel: "Çalışma Modu")?.lastTestStatus, .missingOrRenamed)

        // 4. Missing callback does NOT fabricate success
        let plan4 = try bridge.prepareLaunch(label: "Çalışma Modu", input: nil, taskId: UUID(), revisionNumber: 1, stepId: "sc4")
        let receipt4 = try bridge.finalizeTimedOutToken(plan4.callbackToken, now: now)
        XCTAssertEqual(receipt4.outcome, .uncertain)

        // 5. Secrets blocked from shortcut bridge
        XCTAssertThrowsError(
            try bridge.prepareLaunch(label: "Çalışma Modu", input: "Authorization Bearer sk-secret", taskId: UUID(), revisionNumber: 1, stepId: "sc5")
        )
    }

    func testShareInboxUTF8SizeLimitAndConsumption() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-inbox-\(UUID().uuidString)")
        let manager = SharedInboxManager(inboxDirectory: dir)
        let now = Date()

        // Oversized payload > 64 KB rejected
        let huge = String(repeating: "A", count: SharedInboxManager.maxUTF8Bytes + 10)
        XCTAssertThrowsError(try manager.enqueueText(huge, sourceAppHint: "Safari", now: now))

        // Valid payload persisted and consumed
        let item = try manager.enqueueText("Toplantı özeti belgesi.", sourceAppHint: "Notes", now: now)
        let pending = try manager.pendingItems()
        XCTAssertEqual(pending.map(\.id), [item.id])

        try manager.markConsumed(id: item.id)
        XCTAssertTrue(try manager.pendingItems().isEmpty)
    }
}
