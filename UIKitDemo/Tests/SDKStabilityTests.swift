import XCTest
import UIKit
import MetalKit
import CoreImage
@testable import GradientsKit

final class SDKStabilityTests:XCTestCase {
    @MainActor private func host(_ theme:GradientTheme = .blueDark,_ progress:CGFloat=0.3) throws -> (UIWindow,UIViewController,GradientViewController) {
        let window=UIWindow(frame:UIScreen.main.bounds)
        let host=UIViewController();window.rootViewController=host;window.makeKeyAndVisible()
        let component=try GradientViewController(theme:theme,initialProgress:progress)
        host.addChild(component);component.view.frame=host.view.bounds
        host.view.addSubview(component.view);component.didMove(toParent:host)
        return (window,host,component)
    }
    @MainActor private func frames(_ controller:GradientViewController,_ count:Int=4) async throws {
        let start=controller.framesSubmitted,deadline=ProcessInfo.processInfo.systemUptime+8
        while controller.framesSubmitted<start+count && ProcessInfo.processInfo.systemUptime<deadline {
            try await Task.sleep(nanoseconds:20_000_000)
        }
        XCTAssertGreaterThanOrEqual(controller.framesSubmitted,start+count)
        XCTAssertTrue(controller.gpuErrors.isEmpty,controller.gpuErrors.joined(separator:"\n"))
    }
    @MainActor private func detach(_ controller:GradientViewController) {
        controller.willMove(toParent:nil);controller.view.removeFromSuperview();controller.removeFromParent()
        controller.pauseRendering()
    }
    @MainActor func testIndependentInstancesOwnStateAndMutableGPUResources() async throws {
        let (window,parent,a)=try host(.blueDark,0.3)
        let b=try GradientViewController(theme:.yellowDark,initialProgress:0.8)
        parent.addChild(b);b.view.frame=parent.view.bounds;parent.view.addSubview(b.view);b.didMove(toParent:parent)
        defer {detach(a);detach(b);window.isHidden=true}
        try await frames(a);try await frames(b)
        print("STABILITY owned GPU allocated bytes=\(a.gpu.device.currentAllocatedSize); default device identity=\(MTLCreateSystemDefaultDevice() === a.gpu.device)")
        XCTAssertFalse(a.session === b.session)
        for i in 0..<3 {
            XCTAssertFalse(a.uniformSlots[i] === b.uniformSlots[i])
            XCTAssertFalse(a.historySlots[i] === b.historySlots[i])
            XCTAssertFalse(a.masks[i] === b.masks[i])
        }
        XCTAssertFalse(a.backing === b.backing);XCTAssertFalse(a.distorted === b.distorted)
        let time=Date().timeIntervalSinceReferenceDate
        a.session.dragChanged(to:CGPoint(x:20,y:500),at:time,size:a.view.bounds.size)
        a.session.dragChanged(to:CGPoint(x:370,y:200),at:time+0.02,size:a.view.bounds.size)
        XCTAssertTrue(b.session.interactionTrail.isEmpty);XCTAssertFalse(b.session.waterTouchIsActive)
        a.theme = .yellowLight;a.reset(animated:false)
        XCTAssertEqual(a.session.targetProgress,0);XCTAssertEqual(b.session.targetProgress,0.8)
        XCTAssertEqual(b.theme,.yellowDark)
        a.pauseRendering()
        try await Task.sleep(nanoseconds:100_000_000)
        let paused=a.framesSubmitted
        try await frames(b)
        XCTAssertEqual(a.framesSubmitted,paused)
    }
    @MainActor func testRapidThemeChangesDuringInputRemainRenderable() async throws {
        let (window,_,controller)=try host(.blueDark)
        defer {detach(controller);window.isHidden=true}
        try await frames(controller)
        for i in 0..<32 {
            controller.theme=GradientTheme.allCases[i%4]
            controller.session.dragChanged(to:CGPoint(x:i%2==0 ? 20:370,y:400),at:Date().timeIntervalSinceReferenceDate,size:controller.view.bounds.size)
            controller.tick()
        }
        try await frames(controller,6)
        XCTAssertEqual(controller.theme,.yellowLight)
        XCTAssertEqual(controller.uniforms[23],0);XCTAssertEqual(controller.uniforms[24],3)
        XCTAssertTrue(controller.session.waterTouchIsActive)
        XCTAssertTrue(controller.gpuErrors.isEmpty)
    }

    @MainActor func testRepeatedConstructionReleasesControllerViewAndMaskOwner() async throws {
        for theme in GradientTheme.allCases {for _ in 0..<3 {
            weak var controller:GradientViewController?
            weak var metal:UIView?
            weak var masks:AnyObject?
            try autoreleasepool {
                let (window,_,instance)=try host(theme)
                controller=instance;metal=instance.viewMetal;masks=instance.maskRenderer
                detach(instance);window.rootViewController=nil;window.isHidden=true
            }
            let deadline=ProcessInfo.processInfo.systemUptime+4
            while (controller != nil || metal != nil || masks != nil) && ProcessInfo.processInfo.systemUptime<deadline {
                try await Task.sleep(nanoseconds:20_000_000)
            }
            XCTAssertNil(controller);XCTAssertNil(metal);XCTAssertNil(masks)
        }}
    }
    @MainActor func testResizeAndScaleKeepResourcesAndLayoutConsistent() async throws {
        let (window,_,controller)=try host(.blueDark,0.8)
        defer {detach(controller);window.isHidden=true}
        for size in [CGSize(width:320,height:568),CGSize(width:375,height:667),CGSize(width:390,height:844),CGSize(width:430,height:932),CGSize(width:390.5,height:844.5)] {
            controller.view.frame=CGRect(origin:.zero,size:size);controller.view.setNeedsLayout();controller.view.layoutIfNeeded()
            try await frames(controller)
            let extent=controller.viewMetal.drawableSize
            XCTAssertEqual(controller.backing.width,Int(extent.width));XCTAssertEqual(controller.backing.height,Int(extent.height))
            for mask in controller.masks {XCTAssertEqual(mask.width,Int(extent.width));XCTAssertEqual(mask.height,Int(extent.height))}
            XCTAssertEqual(controller.uniforms[0],Float(size.width));XCTAssertEqual(controller.uniforms[1],Float(size.height))
            XCTAssertGreaterThanOrEqual(controller.caption.minY,0);XCTAssertLessThanOrEqual(controller.caption.maxY,size.height)
            XCTAssertGreaterThanOrEqual(controller.counter.minY,0);XCTAssertLessThanOrEqual(controller.counter.maxY,size.height)
            for button in controller.controlButtons {XCTAssertTrue(controller.view.bounds.contains(button.frame))}
        }
    }
    @MainActor func testBoundsChangeImmediatelyBeforeTickSynchronizesViewport() async throws {
        let (window,_,controller)=try host(.yellowDark)
        defer {detach(controller);window.isHidden=true}
        try await frames(controller)
        controller.view.bounds=CGRect(x:0,y:0,width:390.5,height:844.5)
        controller.tick()
        let size=controller.view.bounds.size,scale=window.screen.scale
        print("VIEWPORT bounds=\(size), metalFrame=\(controller.viewMetal.frame), drawable=\(controller.viewMetal.drawableSize), backing=\(controller.backing.width)x\(controller.backing.height), mask=\(controller.masks[0].width)x\(controller.masks[0].height)")
        XCTAssertEqual(controller.viewMetal.drawableSize,CGSize(width:ceil(size.width*scale),height:ceil(size.height*scale)))
        XCTAssertEqual(controller.backing.width,controller.masks[0].width)
        XCTAssertEqual(controller.backing.height,controller.masks[0].height)
        XCTAssertEqual(controller.uniforms[0],Float(size.width));XCTAssertEqual(controller.uniforms[1],Float(size.height))
    }

    @MainActor func testDetachReattachManualPauseAndHiddenAncestor() async throws {
        let (window,parent,controller)=try host(.yellowDark)
        defer {detach(controller);window.isHidden=true}
        try await frames(controller)
        parent.view.isHidden=true
        try await Task.sleep(nanoseconds:100_000_000)
        let hidden=controller.performanceSamples
        try await Task.sleep(nanoseconds:150_000_000)
        XCTAssertEqual(controller.performanceSamples,hidden)
        parent.view.isHidden=false;try await frames(controller)
        controller.pauseRendering();controller.beginAppearanceTransition(false,animated:false);controller.endAppearanceTransition()
        controller.beginAppearanceTransition(true,animated:false);controller.endAppearanceTransition()
        let paused=controller.performanceSamples
        try await Task.sleep(nanoseconds:150_000_000)
        XCTAssertEqual(controller.performanceSamples,paused,"Reappearance ignored explicit pause")
        controller.resumeRendering();try await frames(controller)
        controller.view.removeFromSuperview()
        try await Task.sleep(nanoseconds:100_000_000)
        let detached=controller.performanceSamples
        try await Task.sleep(nanoseconds:150_000_000)
        XCTAssertEqual(controller.performanceSamples,detached)
        parent.view.addSubview(controller.view)
        controller.beginAppearanceTransition(true,animated:false);controller.endAppearanceTransition()
        try await frames(controller)
    }
    @MainActor func testCounterResetAndThemeChangesAtCompletion() async throws {
        let (window,_,controller)=try host(.blueLight,1)
        defer {detach(controller);window.isHidden=true}
        for theme in GradientTheme.allCases {
            controller.theme=theme;try await frames(controller)
            XCTAssertEqual(controller.counterLabel?.text,"100%")
            XCTAssertEqual(controller.session.targetProgress,1)
        }
        var simulatedTime=Date().timeIntervalSinceReferenceDate
        controller.clock={simulatedTime}
        for phase in [0.0,0.05,0.4,1.5] {
            let now=simulatedTime
            controller.session.dragChanged(to:CGPoint(x:30,y:600),at:now,size:controller.view.bounds.size)
            controller.session.dragChanged(to:CGPoint(x:360,y:150),at:now+0.02,size:controller.view.bounds.size)
            if phase>0 {controller.session.dragEnded(at:now+0.02)}
            simulatedTime=now+0.02+phase
            controller.reset(animated:true)
            XCTAssertEqual(controller.session.targetProgress,0)
            XCTAssertTrue(controller.session.interactionTrail.isEmpty)
            XCTAssertFalse(controller.session.waterTouchIsActive)
            controller.reset(animated:false)
            XCTAssertEqual(controller.counterLabel?.text,"0%")
            simulatedTime+=2
        }
    }
    @MainActor func testFixedTypographyRemainsAccessibleUnderLargeTextTraits() throws {
        let (window,parent,controller)=try host(.yellowLight)
        defer {detach(controller);window.isHidden=true}
        parent.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory:.accessibilityExtraExtraExtraLarge),forChild:controller)
        controller.view.layoutIfNeeded()
        // Approved design is fixed-size; adapting it needs a separate product decision.
        XCTAssertEqual(controller.captionLabel?.font.pointSize,17)
        XCTAssertEqual(controller.counterLabel?.font.pointSize,64)
        // Native accessibility snapshots are verified separately by the four-theme UI test.
        XCTAssertEqual(controller.controlButtons.map(\.accessibilityLabel),["Сбросить","Настройки"])
        XCTAssertEqual(controller.captionLabel?.attributedText?.string,"Устанавливаем защищенное соединение. Водите пальцем в разных частях экрана")
    }
    @MainActor func testStandaloneCoreImageUploadSanitizerControl() throws {
        guard ProcessInfo.processInfo.environment["GRADIENTS_TEST_HOST_EMPTY"]=="1" else {
            throw XCTSkip("Dedicated sanitizer control needs an empty UIKit test host")
        }
        XCTAssertNil(GradientViewController.context,"The control must not instantiate GradientsKit")
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),queue=try XCTUnwrap(device.makeCommandQueue())
        DispatchQueue.concurrentPerform(iterations:3) {worker in
            let colorSpace=CGColorSpaceCreateDeviceRGB()
            guard let bitmap=CGContext(data:nil,width:1170,height:540,bitsPerComponent:8,bytesPerRow:0,space:colorSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {XCTFail("Bitmap unavailable");return}
            let context=CIContext(mtlDevice:device,options:[.workingColorSpace:NSNull(),.outputColorSpace:NSNull(),.cacheIntermediates:false])
            let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:1170,height:2532,mipmapped:false)
            desc.storageMode = .private;desc.usage=[.shaderRead,.shaderWrite,.renderTarget]
            guard let texture=device.makeTexture(descriptor:desc) else {XCTFail("Texture unavailable");return}
            for i in 0..<100 {autoreleasepool {
                bitmap.setFillColor(red:CGFloat(i%10)/10,green:CGFloat(worker)/3,blue:0.3,alpha:1)
                bitmap.fill(CGRect(x:0,y:0,width:1170,height:540))
                guard let image=bitmap.makeImage(),let command=queue.makeCommandBuffer() else {XCTFail("Upload unavailable");return}
                let source=CIImage(cgImage:image).applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:30])
                context.render(source,to:texture,commandBuffer:command,bounds:CGRect(x:0,y:0,width:1170,height:2532),colorSpace:colorSpace)
                // Offline diagnostic control only: no SDK renderer/formulas are called.
                command.commit();command.waitUntilCompleted();XCTAssertEqual(command.status,.completed)
            }}
        }
    }

    func testConcurrentMetricsCollectionPreservesCounts() {
        let metrics=GradientPerformanceMetrics()
        DispatchQueue.concurrentPerform(iterations:8) {worker in
            for i in 0..<300 {
                let time=100+Double(worker*300+i)/60
                metrics.add("concurrent",1)
                metrics.gpu(frame:worker*300+i,expected:1,kind:"gpu",start:time,end:time+0.001)
                metrics.presented(at:time,input:time-0.001)
                if i%20==0 {_=metrics.report()}
            }
        }
        let report=metrics.report()
        XCTAssertEqual((report["concurrent"] as? [String:Double])?["count"],2400)
        XCTAssertEqual((report["gpuWorkMS"] as? [String:Double])?["count"],2400)
        #if targetEnvironment(simulator)
        XCTAssertEqual(report["completionFrames"] as? Int,2400)
        #else
        XCTAssertEqual(report["presentationFrames"] as? Int,2400)
        #endif
    }

    func testProgressIsTimeBasedAt30_60_120HzAndRateRemainsBounded() {
        let sessions=[GradientSession(at:0),GradientSession(at:0),GradientSession(at:0)]
        let size=CGSize(width:390,height:844),renderDivisors=[4,2,1]
        for i in 0...7200 {
            let time=Double(i)/120
            for (index,session) in sessions.enumerated() {
                if i%2==0 {
                    session.dragChanged(to:CGPoint(x:i%4==0 ? 0:389,y:i%4==0 ? 0:843),at:time,size:size)
                    XCTAssertLessThanOrEqual(session.targetProgress,min(1,0.013+0.0585*time)+1e-10)
                    XCTAssertLessThanOrEqual(session.interactionTrail.count,40)
                }
                if i%renderDivisors[index]==0 {
                    let frame=session.frame(at:time,size:size,dark:index==0,yellow:index==1)
                    XCTAssertTrue(frame.uniforms.allSatisfy(\.isFinite));XCTAssertLessThanOrEqual(frame.history.count,240)
                }
            }
        }
        XCTAssertTrue(sessions.allSatisfy {$0.targetProgress==1})
        for session in sessions {
            session.dragEnded(at:60)
            XCTAssertTrue(session.frame(at:65,size:size,dark:true,yellow:true).history.isEmpty)
            session.reset(at:66);XCTAssertEqual(session.targetProgress,0)
        }
    }
}
