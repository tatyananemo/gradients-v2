import XCTest

final class InteractionTests:XCTestCase {
    func testContinuousSwipeHoldReleaseReset() {
        let app=XCUIApplication(bundleIdentifier:"com.local.gradients.v2.migrationprobe")
        app.activate()
        XCTAssertTrue(app.buttons["Сбросить"].waitForExistence(timeout:20))
        app.buttons["Сбросить"].tap()
        let start=app.coordinate(withNormalizedOffset:CGVector(dx:0.2,dy:0.80))
        let end=app.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.25))
        start.press(forDuration:0.1,thenDragTo:end)
        end.press(forDuration:0.1,thenDragTo:start)
        let percentage=app.staticTexts.matching(NSPredicate(format:"label ENDSWITH %@", "%")).firstMatch
        XCTAssertTrue(percentage.waitForExistence(timeout:5))
        let before=Int(percentage.label.replacingOccurrences(of:"%",with:"")) ?? -1
        XCTAssertGreaterThan(before,2,"Two swipes must include movement credit, not just initial-touch credit")
        start.press(forDuration:1.0)
        let after=Int(percentage.label.replacingOccurrences(of:"%",with:"")) ?? -1
        XCTAssertLessThanOrEqual(after-before,2,"Stationary hold must not continuously advance progress")
        app.buttons["Сбросить"].tap()
        XCTAssertTrue(app.staticTexts["0%"].waitForExistence(timeout:5))
    }
}
