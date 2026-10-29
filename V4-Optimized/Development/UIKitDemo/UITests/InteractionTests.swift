import XCTest

final class InteractionTests:XCTestCase {
    func testAllThemesSwipeHoldReleaseAndReset() {
        let app=XCUIApplication()
        app.launchEnvironment["GRADIENTS_DIAGNOSTICS"]="1"
        for dark in [false,true] {for yellow in [true] {
            app.launchEnvironment["GRADIENTS_THEME"]=dark ? "dark":"light"
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
    func testInstructionIsExposedInAllThemes() {
        let app=XCUIApplication()
        for dark in [false,true] {for yellow in [true] {
            app.launchEnvironment["GRADIENTS_THEME"]=dark ? "dark":"light"
            app.launch()
            XCTAssertTrue(app.staticTexts["Устанавливаем защищенное соединение. Водите пальцем в разных частях экрана"].waitForExistence(timeout:3))
            app.terminate()
        }}
    }

    func testStressSwipesBackgroundResumeAndMultitouchForAllThemes() {
        let app=XCUIApplication()
        func value()->Int {
            let text=app.staticTexts.matching(NSPredicate(format:"label ENDSWITH %@","%")).firstMatch.label
            return Int(text.replacingOccurrences(of:"%",with:"")) ?? -1
        }
        for dark in [false,true] {for yellow in [true] {
            app.launchEnvironment["GRADIENTS_THEME"]=dark ? "dark":"light"
            app.launchEnvironment["GRADIENTS_PROGRESS"]="0"
            app.launch()
            XCTAssertTrue(app.buttons["Сбросить"].waitForExistence(timeout:10))
            let start=app.coordinate(withNormalizedOffset:CGVector(dx:0.04,dy:0.92))
            let end=app.coordinate(withNormalizedOffset:CGVector(dx:0.96,dy:0.16))
            let length=hypot(app.frame.width*0.92,app.frame.height*0.76)
            // One real continuous 30-second drag, independent of display refresh rate.
            start.press(forDuration:0.02,thenDragTo:end,withVelocity:XCUIGestureVelocity(rawValue:length/30),thenHoldForDuration:0.2)
            XCTAssertGreaterThan(value(),5)
            let corners=[CGVector(dx:0.02,dy:0.16),CGVector(dx:0.98,dy:0.16),CGVector(dx:0.98,dy:0.94),CGVector(dx:0.02,dy:0.94)]
            for i in corners.indices {
                let a=app.coordinate(withNormalizedOffset:corners[i]),b=app.coordinate(withNormalizedOffset:corners[(i+1)%4])
                a.press(forDuration:0.01,thenDragTo:b,withVelocity:.fast,thenHoldForDuration:0)
                b.press(forDuration:0.01,thenDragTo:a,withVelocity:.fast,thenHoldForDuration:0)
            }
            app.pinch(withScale:1.15,velocity:1)
            let center=app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
            let before=value();center.press(forDuration:1)
            XCTAssertLessThanOrEqual(value()-before,2,"Stationary hold advanced progress")
            let released=value()
            Thread.sleep(forTimeInterval:1.5)
            XCTAssertEqual(value(),released,"Release/idle advanced progress")
            XCUIDevice.shared.press(.home);Thread.sleep(forTimeInterval:1)
            app.activate()
            XCTAssertTrue(app.buttons["Сбросить"].waitForExistence(timeout:10))
            XCTAssertEqual(value(),released,"Background/resume changed progress")
            let a=app.coordinate(withNormalizedOffset:CGVector(dx:0.45,dy:0.55))
            let b=app.coordinate(withNormalizedOffset:CGVector(dx:0.55,dy:0.45))
            for _ in 0..<45 where value()<100 {
                a.press(forDuration:0.01,thenDragTo:b,withVelocity:.fast,thenHoldForDuration:0)
            }
            XCTAssertEqual(value(),100,"Swipes did not reach 100%")
            end.press(forDuration:0.01,thenDragTo:start,withVelocity:.fast,thenHoldForDuration:0)
            XCTAssertEqual(value(),100)
            for _ in 0..<3 {
                app.buttons["Сбросить"].tap()
                XCTAssertTrue(app.staticTexts["0%"].waitForExistence(timeout:3))
            }
            print("STABILITY UI passed dark=\(dark), yellow=\(yellow): long/fast/reverse/edge/multitouch/hold/release/background/100/reset")
            app.terminate()
        }}
    }

    func testSystemBackgroundCancelsAnActiveNativeGesture() {
        let app=XCUIApplication()
        app.launchEnvironment["GRADIENTS_DIAGNOSTICS"]="1"
        app.launchEnvironment["GRADIENTS_TEST_INTERRUPT_AFTER"]="5"
        app.launchEnvironment["GRADIENTS_PROGRESS"]="0"
        app.launchEnvironment["GRADIENTS_THEME"]="dark"
        app.launch()
        XCTAssertTrue(app.buttons["Сбросить"].waitForExistence(timeout:10))
        let start=app.coordinate(withNormalizedOffset:CGVector(dx:0.2,dy:0.85))
        let end=app.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.2))
        let length=hypot(app.frame.width*0.6,app.frame.height*0.65)
        let options=XCTExpectedFailure.Options();options.isStrict=false
        // Only injection failure is permitted here: the OS deliberately cancels
        // an in-progress touch by opening this app's Settings page. All functional
        // assertions below remain ordinary mandatory assertions.
        XCTExpectFailure("OS background transition can cancel the XCTest event stream",options:options) {
            start.press(forDuration:0.02,thenDragTo:end,withVelocity:XCUIGestureVelocity(rawValue:length/12),thenHoldForDuration:0)
        }
        XCTAssertEqual(app.state,.runningBackground,"The app crashed or never entered background")
        app.activate()
        XCTAssertTrue(app.buttons["Сбросить"].waitForExistence(timeout:10))
        let percentage=app.staticTexts.matching(NSPredicate(format:"label ENDSWITH %@","%")).firstMatch
        let after=Int(percentage.label.replacingOccurrences(of:"%",with:"")) ?? -1
        XCTAssertGreaterThan(after,0)
        Thread.sleep(forTimeInterval:1.5)
        XCTAssertEqual(Int(percentage.label.replacingOccurrences(of:"%",with:"")),after,"Interrupted touch remained active")
        start.press(forDuration:0.05,thenDragTo:end)
        XCTAssertGreaterThan(Int(percentage.label.replacingOccurrences(of:"%",with:"")) ?? -1,after)
        app.terminate()
    }

    func testOnlyYellowThemesAndDarkLightPreference() {
        let app=XCUIApplication();app.launch()
        app.buttons["Настройки"].tap()
        let theme=app.segmentedControls["theme"]
        XCTAssertTrue(theme.waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["blue"].exists)
        XCTAssertFalse(app.buttons["yellow"].exists)
        XCTAssertFalse(app.staticTexts["Цвет градиента"].exists)
        theme.buttons["Светлая"].tap()
        XCTAssertTrue(theme.buttons["Светлая"].isSelected)
        app.terminate();app.launch()
        app.buttons["Настройки"].tap()
        XCTAssertTrue(theme.waitForExistence(timeout:5))
        XCTAssertTrue(theme.buttons["Светлая"].isSelected)
        theme.buttons["Тёмная"].tap()
        app.terminate();app.launch()
        app.buttons["Настройки"].tap()
        XCTAssertTrue(theme.waitForExistence(timeout:5))
        XCTAssertTrue(theme.buttons["Тёмная"].isSelected)
        app.terminate()
    }

    func testSettingsSwitchesDarkAndLight() {
        let app=XCUIApplication();app.launch()
        app.buttons["Настройки"].tap()
        XCTAssertTrue(app.segmentedControls["theme"].waitForExistence(timeout:5))
        app.segmentedControls["theme"].buttons["Тёмная"].tap()
        app.segmentedControls["theme"].buttons["Светлая"].tap()
        app.segmentedControls["theme"].buttons["Тёмная"].tap()
        app.swipeDown()
        XCTAssertTrue(app.buttons["Сбросить"].waitForExistence(timeout:5))
    }
}
