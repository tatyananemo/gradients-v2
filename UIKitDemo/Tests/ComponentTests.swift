import XCTest
import UIKit
import Metal
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
    @MainActor func testDarkMaskCachePolicyPreservesEveryPixelInSimulator() throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),queue=try XCTUnwrap(device.makeCommandQueue())
        let before=GradientMaskRenderer(device:device,queue:queue,cacheIntermediates:true)
        let after=GradientMaskRenderer(device:device,queue:queue)
        let source="""
        #include <metal_stdlib>
        using namespace metal;
        kernel void compare(texture2d<float,access::read> a [[texture(0)]],texture2d<float,access::read> b [[texture(1)]],device atomic_uint *changed [[buffer(0)]],uint2 id [[thread_position_in_grid]]) {
         if(id.x>=a.get_width()||id.y>=a.get_height())return;
         float4 x=a.read(id),y=b.read(id);
         if(any(x!=y))atomic_fetch_add_explicit(changed,1,memory_order_relaxed);
        }
        """
        let library=try device.makeLibrary(source:source,options:nil)
        let pipeline=try device.makeComputePipelineState(function:try XCTUnwrap(library.makeFunction(name:"compare")))
        for yellow in [false,true] {for progress in [0.3,0.6,0.8] {
            try autoreleasepool {
                let counter=CGRect(x:0,y:356,width:390,height:76.6666666666667),size=CGSize(width:390,height:844)
                let a=before.render(progress:progress,elapsed:3.75,yellow:yellow,counter:counter,size:size,scale:3)
                let b=after.render(progress:progress,elapsed:3.75,yellow:yellow,counter:counter,size:size,scale:3)
                let result=try XCTUnwrap(device.makeBuffer(length:4,options:.storageModeShared))
                result.contents().storeBytes(of:UInt32(0),as:UInt32.self)
                let command=try XCTUnwrap(queue.makeCommandBuffer())
                for i in 0..<3 {
                    let encoder=try XCTUnwrap(command.makeComputeCommandEncoder())
                    encoder.setComputePipelineState(pipeline);encoder.setTexture(a[i],index:0);encoder.setTexture(b[i],index:1);encoder.setBuffer(result,offset:0,index:0)
                    encoder.dispatchThreads(MTLSize(width:1170,height:2532,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1));encoder.endEncoding()
                }
                // Readback waits are confined to this offline regression test.
                command.commit();command.waitUntilCompleted()
                XCTAssertEqual(command.status,.completed)
                XCTAssertEqual(result.contents().load(as:UInt32.self),0,"Different Dark mask pixels, yellow=\(yellow), progress=\(progress)")
            }
        }}
    }

    @MainActor func testLiveThemeChangesReusePrivateMasksWithoutGPUFailures() async throws {
        let window=UIWindow(frame:CGRect(x:0,y:0,width:390,height:844))
        let session=GradientSession(at:Date().timeIntervalSinceReferenceDate,initialProgress:0.6)
        let controller=try GradientViewController(session:session,dark:true,yellow:false)
        window.rootViewController=controller;window.makeKeyAndVisible()
        defer {controller.pauseRendering();window.isHidden=true}
        for _ in 0..<2 {for dark in [true,false] {for yellow in [false,true] {
            controller.dark=dark;controller.yellow=yellow
            let submitted=controller.framesSubmitted
            let deadline=ProcessInfo.processInfo.systemUptime+8
            repeat {
                try await Task.sleep(nanoseconds:50_000_000)
            } while controller.framesSubmitted<submitted+12 && ProcessInfo.processInfo.systemUptime<deadline
            XCTAssertGreaterThanOrEqual(controller.framesSubmitted,submitted+12,"Renderer stopped: dark=\(dark), yellow=\(yellow)")
            XCTAssertTrue(controller.gpuErrors.isEmpty,controller.gpuErrors.joined(separator:"\n"))
            if dark {
                XCTAssertEqual(controller.masks.count,3)
                for texture in controller.masks {
                    XCTAssertEqual(texture.storageMode,.private)
                    XCTAssertEqual(texture.pixelFormat,.rgba16Float)
                    XCTAssertEqual(texture.width,Int(controller.viewMetal.drawableSize.width))
                    XCTAssertEqual(texture.height,Int(controller.viewMetal.drawableSize.height))
                }
            }
        }}}
        controller.pauseRendering()
        let deadline=ProcessInfo.processInfo.systemUptime+8
        while controller.inFlight && ProcessInfo.processInfo.systemUptime<deadline {
            try await Task.sleep(nanoseconds:20_000_000)
        }
        XCTAssertFalse(controller.inFlight,"GPU commands did not complete")
        XCTAssertTrue(controller.gpuErrors.isEmpty,controller.gpuErrors.joined(separator:"\n"))
    }

    @MainActor func testCaptionProbeInvalidatesPreviousThemeWhileBusy() async throws {
        let gpu=try GradientGPU(),probe=SessionCaptionProbe(gpu:gpu)
        let frame=GradientSession(at:0,initialProgress:0.6).frame(at:1,size:CGSize(width:390,height:844),dark:false,yellow:false)
        let caption=CGRect(x:0,y:699,width:390,height:63)
        probe.sample(uniforms:frame.uniforms,history:[],frame:caption,key:"blue",dark:false,yellow:false)
        // Completion is dispatched to main, so the second call observes busy=true.
        probe.sample(uniforms:frame.uniforms,history:[],frame:caption,key:"yellow",dark:false,yellow:true)
        XCTAssertEqual(probe.key,"yellow","In-flight results must not keep the old theme current")
        try await Task.sleep(nanoseconds:200_000_000)
        XCTAssertEqual(probe.activation,0,"An obsolete theme result changed the new theme's backing")
    }

    func testPerformanceMetricsCountSustainedDeadlineDeficit() {
        let metrics=GradientPerformanceMetrics()
        for i in 0..<6 {
            let time=100+Double(i)*0.02
            metrics.presented(at:time,input:0);metrics.displayLink(at:time)
        }
        let report=metrics.report()
        XCTAssertEqual((report["displayLinkFPS"] as? Double) ?? 0,50,accuracy:0.0001)
        XCTAssertEqual(report["missedDisplayLinkTicks"] as? Int,1)
        #if targetEnvironment(simulator)
        XCTAssertEqual(report["completionDeficitAt60Hz"] as? Int,1)
        XCTAssertNil(report["missedVSyncsEstimate"])
        #endif
    }

}
