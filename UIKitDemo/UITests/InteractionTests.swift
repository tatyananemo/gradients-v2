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
    func testInstructionIsExposedInAllThemes() {
        let app=XCUIApplication()
        for dark in [false,true] {for yellow in [false,true] {
            app.launchEnvironment["GRADIENTS_THEME"]=dark ? "dark":"light"
            app.launchEnvironment["GRADIENTS_COLOR"]=yellow ? "yellow":"blue"
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
        for dark in [false,true] {for yellow in [false,true] {
            app.launchEnvironment["GRADIENTS_THEME"]=dark ? "dark":"light"
            app.launchEnvironment["GRADIENTS_COLOR"]=yellow ? "yellow":"blue"
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
