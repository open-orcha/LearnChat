import XCTest

/// End-to-end smoke test against the real server (skipped if it isn't reachable):
/// new chat → send → streamed reply → back to the list → reopen (history persisted) → settings.
/// Screenshots go to $QCHAT_SHOTS (or /tmp/qchat-ui) so a run can be eyeballed.
final class QChatSmokeTests: XCTestCase {
    private var app: XCUIApplication!
    private let shots = URL(fileURLWithPath: ProcessInfo.processInfo.environment["QCHAT_SHOTS"] ?? "/tmp/qchat-ui", isDirectory: true)

    override func setUpWithError() throws {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launch()
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: shots.appendingPathComponent("\(name).png"))
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testChatRoundTripAndPersistence() throws {
        shot("01-chat-list-empty")
        app.buttons["New chat"].tap()

        let field = app.textFields["Message"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        shot("02-new-chat")
        field.tap()
        field.typeText("Reply with exactly one short sentence: what is the capital of France?")
        shot("03-typed")
        app.buttons["Send"].tap()

        // The reply streams in; wait for the Stop button to flip back to Send.
        let send = app.buttons["Send"]
        let stop = app.buttons["Stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "sending never started")
        // Grab a mid-stream frame if we can catch one.
        _ = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'Paris'")).firstMatch.waitForExistence(timeout: 30)
        shot("04-streaming")
        XCTAssertTrue(send.waitForExistence(timeout: 180), "reply did not finish")
        shot("05-reply")
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'Paris'")).firstMatch
        XCTAssertTrue(reply.exists, "expected a reply mentioning Paris")

        // Back to the list: the chat is there with an auto-title and preview.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'capital of France'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "chat missing from the list")
        shot("06-chat-list")

        // Reopen: history was persisted locally.
        row.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'Paris'")).firstMatch.waitForExistence(timeout: 5))
        shot("07-reopened")

        // Settings: test connection against the configured server.
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Test connection"].waitForExistence(timeout: 5))
        app.buttons["Test connection"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Connected'")).firstMatch.waitForExistence(timeout: 15))
        shot("08-settings")
    }

    /// Needs a photo in the Simulator's library (`xcrun simctl addmedia <sim> sign.jpg`).
    func testPhotoAttachmentIsDescribedOnDevice() throws {
        app.buttons["New chat"].tap()
        XCTAssertTrue(app.textFields["Message"].firstMatch.waitForExistence(timeout: 5))

        app.buttons["Attach a PDF, photo or video"].tap()
        app.buttons["Photo or video"].tap()
        // PHPicker's thumbnail cells and header are intentionally not exposed as app-owned
        // accessibility elements on recent iOS versions. Give the remote picker time to present,
        // then tap the first grid cell at a device-independent normalised coordinate.
        Thread.sleep(forTimeInterval: 2)
        shot("09-photo-picker")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.43)).tap()

        // The chip shows progress, then the on-device summary.
        let field = app.textFields["Ask about the attachment…"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'words of text' OR label CONTAINS 'nothing recognised' OR label CONTAINS ','")).firstMatch.waitForExistence(timeout: 60), "attachment never became ready")
        shot("10-attachment-ready")
        field.tap()
        field.typeText("What does the sign say?")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 180), "reply did not finish")
        // The photo and its name remain in the persisted user bubble. If Vision recognised
        // anything, also expand the derived text; an ordinary scenery photo may validly produce
        // the ready state "nothing recognised" in the Simulator.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] '.jpeg' OR label CONTAINS[c] '.jpg' OR label CONTAINS[c] '.png'")).firstMatch.exists)
        let analysis = app.buttons["What this phone saw in the photo"].firstMatch
        if analysis.exists { analysis.tap() }
        shot("11-photo-reply")
    }
}
