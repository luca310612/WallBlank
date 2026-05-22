import XCTest

// UI automation needs Accessibility for the xcodebuild parent (or run from Xcode). CI: scheme `ArtiaMenubar` (unit only).
final class ArtiaMenubarUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchesAndShowsHostWindow() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
    }
}
