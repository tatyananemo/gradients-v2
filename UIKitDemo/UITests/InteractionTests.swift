import XCTest

final class InteractionTests:XCTestCase {
    func testAllThemesSwipeHoldReleaseAndReset() {
        let app=XCUIApplication()
        app.launchEnvironment["GRADIENTS_DIAGNOSTICS"]="1"
        for dark in [false,true] {for yellow in [false,true] {
            app.launchEnvironment["GRADIENTS_THEME"]=dark ? "dark":"light"
            app.launchEnvironment["GRADIENTS_COLOR"]=yellow ? "yellow":"blue"
            app.launch()
            XCTAssertTrue(app.buttons["Сбросить"].waitForExistence(timeout:20))
            let start=app.coordinate(withNormalizedOffset:CGVector(dx:0.2,dy:0.8))
            let end=app.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.25))
            start.press(forDuration:0.1,thenDragTo:end)
            end.press(forDuration:0.1,thenDragTo:start)
            let percentage=app.staticTexts.matching(NSPredicate(format:"label ENDSWITH %@","%")).firstMatch
            XCTAssertTrue(percentage.waitForExistence(timeout:3))
            let before=Int(percentage.label.replacingOccurrences(of:"%",with:"")) ?? -1
            XCTAssertGreaterThan(before,2)
            start.press(forDuration:1)
            let after=Int(percentage.label.replacingOccurrences(of:"%",with:"")) ?? -1
            XCTAssertLessThanOrEqual(after-before,2)
            app.buttons["Сбросить"].tap()
            XCTAssertTrue(app.staticTexts["0%"].waitForExistence(timeout:3))
            XCTAssertFalse(app.otherElements.matching(identifier:"UIHostingController").firstMatch.exists)
            app.terminate()
        }}
    }
    func testSettingsSwitchesBothThemesAndColors() {
        let app=XCUIApplication();app.launch()
        app.buttons["Настройки"].tap()
        XCTAssertTrue(app.segmentedControls["theme"].waitForExistence(timeout:5))
        app.segmentedControls["theme"].buttons["Тёмная"].tap()
        app.buttons["yellow"].tap();app.buttons["blue"].tap()
        app.segmentedControls["theme"].buttons["Светлая"].tap()
        app.swipeDown()
        XCTAssertTrue(app.buttons["Сбросить"].waitForExistence(timeout:5))
    }
}
