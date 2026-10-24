import XCTest
import UIKit
@testable import GradientsKit

final class ComponentTests:XCTestCase {
    @MainActor func testFrameworkOwnsMetalAndHasNoHostingController() throws {
        let controller=try GradientViewController(session:GradientSession(at:Date().timeIntervalSinceReferenceDate),dark:true,yellow:true)
        controller.loadViewIfNeeded()
        XCTAssertTrue(controller.engineDescription.contains("UIKit + Metal"))
        XCTAssertFalse(String(reflecting:type(of:controller)).contains("Hosting"))
        XCTAssertNotNil(controller.view.subviews.first(where: {String(describing:type(of:$0))=="MTKView"}))
        XCTAssertEqual(controller.gpu.library.label,"GradientsKit/default.metallib")
        XCTAssertTrue(Bundle(for:GradientViewController.self).bundleURL.pathExtension=="framework")
    }
    @MainActor func testCounterTransactionAndResetDuration() {
        let label=GradientPercentageLabel(frame:CGRect(x:0,y:0,width:390,height:77))
        label.font = .systemFont(ofSize:64,weight:.bold)
        label.setPercentage(60)
        XCTAssertEqual(label.text,"60%")
        label.setPercentage(80)
        XCTAssertEqual(label.text,"80%")
        let presentation=GradientResetPresentation(started:0,counter:0.8,mask:0.7)
        XCTAssertEqual(GradientResetPresentation.duration,0.35)
        XCTAssertEqual(presentation.values(at:0.175).counter,0.4,accuracy:0.000001)
        XCTAssertTrue(presentation.values(at:0.35).finished)
    }
    @MainActor func testNumericRollUsesResetTransactionAndSettles() async throws {
        let window=UIWindow(frame:CGRect(x:0,y:0,width:390,height:844))
        let host=UIViewController();window.rootViewController=host;window.isHidden=false
        defer {window.isHidden=true}
        let label=GradientPercentageLabel(frame:CGRect(x:0,y:350,width:390,height:77))
        label.font = .systemFont(ofSize:64,weight:.bold);host.view.addSubview(label)
        label.setPercentage(80)
        XCTAssertFalse(label.isTransitioning)
        label.setPercentage(0,animated:true)
        XCTAssertTrue(label.isTransitioning)
        XCTAssertEqual(label.transitionDuration,0.35)
        XCTAssertEqual(label.accessibilityLabel,"0%")
        try await Task.sleep(nanoseconds:500_000_000)
        XCTAssertFalse(label.isTransitioning)
        XCTAssertEqual(label.text,"0%")
    }
    @MainActor func testAllThemesReachCompletionAndReset() {
        for dark in [false,true] {for yellow in [false,true] {
            let session=GradientSession(at:0)
            for i in 0..<2400 {
                let time=Double(i)/60
                session.dragChanged(to:CGPoint(x:i%2==0 ? 20:370,y:300),at:time,size:CGSize(width:390,height:844))
            }
            XCTAssertEqual(session.targetProgress,1)
            session.dragEnded(at:40)
            let frame=session.frame(at:41.2,size:CGSize(width:390,height:844),dark:dark,yellow:yellow)
            XCTAssertEqual(frame.progress,1);XCTAssertEqual(frame.distortion,0)
            session.reset(at:42)
            XCTAssertEqual(session.targetProgress,0)
            XCTAssertTrue(session.frame(at:42,size:CGSize(width:390,height:844),dark:dark,yellow:yellow).history.isEmpty)
        }}
    }
}
