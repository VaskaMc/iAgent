import XCTest
import AgentCore
@testable import PhoneActions

final class PhoneActionsStage5Tests: XCTestCase {
    func testTwoDenizContactsTriggerDisambiguationAndCancelReceiptIsHonest() async throws {
        let directory = InMemoryContactDirectory(
            authorized: true,
            contacts: [
                ContactCandidate(id: "c1", displayName: "Deniz Yılmaz", phoneNumbers: ["+994501111111"]),
                ContactCandidate(id: "c2", displayName: "Deniz Kaya", phoneNumbers: ["+994502222222"])
            ]
        )
        let resolver = ContactResolver(directory: directory)
        let resolution = await resolver.resolve(query: "Deniz", channel: .phoneOrSMS)

        guard case .disambiguationRequired(let query, let candidates) = resolution else {
            return XCTFail("Expected disambiguation for two Deniz entries")
        }
        XCTAssertEqual(query, "Deniz")
        XCTAssertEqual(candidates.count, 2)

        // Cancel in SMS composer produces .cancelled receipt
        let presenter = MockSystemCommunicationPresenter()
        presenter.nextSMSResult = .cancelled
        let commExecutor = CommunicationActionExecutor(presenter: presenter)
        let receipt = await commExecutor.composeSMS(
            taskId: UUID(),
            revisionNumber: 1,
            stepId: "c",
            recipientHandle: "+994501111111",
            body: "Yarın 10.00 için toplantıyı takvimime ekledim.",
            now: Date()
        )
        XCTAssertEqual(receipt.outcome, .cancelled)
        XCTAssertFalse(receipt.spokenVerbTR.contains("teslim"))

        // Missing WhatsApp does not fabricate success
        let shareResult = await commExecutor.shareToApp(text: "Merhaba", preferredAppScheme: "whatsapp")
        guard case .targetAppNotInstalledOfferStandardShare(let appName, _) = shareResult else {
            return XCTFail("Expected targetAppNotInstalledOfferStandardShare")
        }
        XCTAssertEqual(appName, "whatsapp")
        XCTAssertFalse(presenter.sharePresented)

        // Phone call hands off number to system dial confirmation
        let callResult = await commExecutor.handoffPhoneCall(phoneNumber: "+994501111111")
        XCTAssertEqual(callResult, .callConfirmationPresented(phoneNumber: "+994501111111"))
        XCTAssertTrue(presenter.dialOpened)
    }

    func testMapsDirectionsWithoutLocationPermission() async throws {
        let bakuStation = MapDestinationCandidate(
            id: "baku-1",
            name: "Bakü Garı",
            subtitle: "28 May, Bakü",
            latitude: 40.3797,
            longitude: 49.8486
        )
        let backend = InMemoryMapsBackend(placesByQuery: ["Bakü Garı": [bakuStation]])
        let executor = MapsActionExecutor(backend: backend)

        let outcome = await executor.openDirections(query: "Bakü Garı", transportMode: .transit)
        XCTAssertEqual(outcome, .handedOffToMaps(destination: bakuStation, mode: .transit))
        XCTAssertFalse(backend.locationPermissionRequested)
    }
}
