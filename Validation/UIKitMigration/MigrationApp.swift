// Isolated validation host. This file is not in the Gradients V2 app target.
import SwiftUI
import UIKit

struct MigrationRequest: Codable {
    var id:String
    var mode:String = "swiftui"
    var dark:Bool
    var yellow:Bool
    var progress:Double
    var kind:String
    var phase:Double = 1.65
}
final class MigrationFrame {
    let request:MigrationRequest
    let replay=MigrationReplay()
    var time:TimeInterval=1000
    var activation:Double=0
    var dark:Bool {request.dark}
    var yellow:Bool {request.yellow}
    init(_ request:MigrationRequest) {
        self.request=request
        replay.reset(now:1000,animated:false)
        replay.progress=CGFloat(request.progress)
        time=1000+request.progress*10+request.phase
        replay.idleWaveStartTime=1000+request.progress*10
        if request.kind == "main" {replay.waterTouchIsActive=true}
        if ["swipe","hold","release","reset"].contains(request.kind) {
            let p=CGPoint(x:45,y:690)
            for i in 0...36 {
                let t=1006+Double(i)/60
                let q=CGPoint(x:45+CGFloat(i)*8,y:690-CGFloat(i)*12)
                replay.changed(GestureValue(location:q,startLocation:p),at:t)
            }
            time=1006.6+request.phase
            if request.kind == "release" {replay.ended(at:1006.6)}
            if request.kind == "reset" {replay.reset(now:1006.6,animated:false)}
        }
    }
}
enum MigrationEnvironment {
    static var frame=MigrationFrame(MigrationRequest(id:"initial",dark:false,yellow:false,progress:0,kind:"main"))
    static var captionFrame=CGRect.zero
    static var counterFrame=CGRect.zero
    static var uniforms:[Float]=[]
    static var history:[Float]=[]
    static var distortion:Float=0
}

@main final class MigrationApp:UIResponder,UIApplicationDelegate {
    func application(_ application:UIApplication,configurationForConnecting session:UISceneSession,options:UIScene.ConnectionOptions)->UISceneConfiguration {
        let configuration=UISceneConfiguration(name:"Migration",sessionRole:session.role)
        configuration.delegateClass=MigrationSceneDelegate.self
        return configuration
    }
}
final class MigrationSceneDelegate:UIResponder,UIWindowSceneDelegate {
    var window:UIWindow?
    func scene(_ scene:UIScene,willConnectTo session:UISceneSession,options:UIScene.ConnectionOptions) {
        guard let scene=scene as? UIWindowScene else{return}
        let window=UIWindow(windowScene:scene)
        window.rootViewController=MigrationController()
        window.makeKeyAndVisible();self.window=window
    }
}
final class ReferenceHost:UIHostingController<AnyView> {
    override var prefersStatusBarHidden:Bool {true}
    override var prefersHomeIndicatorAutoHidden:Bool {true}
}
final class MigrationController:UIViewController {
    var host:UIViewController?
    var timer:Timer?
    var processing=false
    var lastID=""
    // System Home Indicator fades after a cold scene launch; this affects capture readiness only.
    let captureWarmupDeadline=ProcessInfo.processInfo.systemUptime+3.5
    let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
    override var prefersStatusBarHidden:Bool {true}
    override var prefersHomeIndicatorAutoHidden:Bool {true}
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = .black
        timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true){[weak self] _ in self?.poll()}
    }
    func install(_ controller:UIViewController) {
        if let host {host.willMove(toParent:nil);host.view.removeFromSuperview();host.removeFromParent()}
        addChild(controller);controller.view.frame=view.bounds;view.addSubview(controller.view)
        controller.didMove(toParent:self);host=controller
        controller.view.setNeedsLayout();controller.view.layoutIfNeeded()
    }
    func reference() {
        install(ReferenceHost(rootView:AnyView(GradientInstallView().ignoresSafeArea(.all).persistentSystemOverlays(.hidden))))
    }
    func poll() {
        guard !processing,let data=try? Data(contentsOf:directory.appendingPathComponent("request.json")),
              let request=try? JSONDecoder().decode(MigrationRequest.self,from:data),request.id != lastID else{return}
        processing=true;lastID=request.id
        Task { @MainActor in
            do {try await render(request)} catch {
                try? JSONSerialization.data(withJSONObject:["id":request.id,"error":String(describing:error)]).write(to:directory.appendingPathComponent("ready.json"),options:.atomic)
            }
            processing=false
        }
    }
    @MainActor func render(_ request:MigrationRequest) async throws {
        if request.mode.hasPrefix("behavior-") {
            try await renderBehavior(request)
            return
        }
        BehaviorEnvironment.active=false
        MigrationEnvironment.frame=MigrationFrame(request)
        MigrationEnvironment.captionFrame = .zero;MigrationEnvironment.counterFrame = .zero
        MigrationEnvironment.uniforms=[];MigrationEnvironment.history=[]
        reference()
        try await Task.sleep(nanoseconds:350_000_000)
        let u=MigrationEnvironment.uniforms,h=MigrationEnvironment.history
        guard u.count==28,u[2]==Float(MigrationEnvironment.frame.replay.interpolatedProgress(at:MigrationEnvironment.frame.time)) else {throw NSError(domain:"Migration.Uniforms",code:1)}
        let caption=MigrationEnvironment.captionFrame,counter=MigrationEnvironment.counterFrame
        // The actual probe, CPU equations and thresholds are reused. Only its clock
        // is injected; fixed-state captures settle through 90 original samples.
        let probe=V2CaptionProbe()
        for _ in 0..<90 {
            probe.migrationTime += 1.0/60
            await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
                probe.migrationCompletion={continuation.resume()}
                probe.sample(uniforms:u,history:h,frame:caption,key:request.dark.description+request.yellow.description,dark:request.dark,yellow:request.yellow)
            }
        }
        MigrationEnvironment.frame.activation=probe.activation
        if request.mode.hasPrefix("swiftui") {reference()}
        else {
            // Enabled by the separately reviewed prototype commit.
            #if UIKIT_PROTOTYPE
            install(try PrototypeController(uniforms:u,history:h,caption:caption,counter:counter))
            #else
            throw NSError(domain:"Migration.PrototypeNotBuilt",code:2)
            #endif
        }
        try await Task.sleep(nanoseconds:500_000_000)
        var metadata:[String:Any] = ["id":request.id,"mode":request.mode,"uniforms":u,"history":h,
            "caption":rect(caption),"counter":rect(counter),"activation":probe.activation,
            "distortion":MigrationEnvironment.distortion,"scale":UIScreen.main.scale,
            "size":[view.bounds.width,view.bounds.height],"progress":MigrationEnvironment.frame.replay.progress,
            "time":MigrationEnvironment.frame.time,"os":UIDevice.current.systemVersion]
        #if UIKIT_PROTOTYPE
        if let prototype=host as? PrototypeController {
            for _ in 0..<500 where !prototype.finished {try await Task.sleep(nanoseconds:10_000_000)}
            guard prototype.finished else{throw NSError(domain:"Migration.DrawableNotCompleted",code:3)}
            metadata["prototype"]=prototype.diagnostics
        }
        #endif
        let remaining=captureWarmupDeadline-ProcessInfo.processInfo.systemUptime
        if remaining>0 {try await Task.sleep(nanoseconds:UInt64(remaining*1_000_000_000))}
        try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("ready.json"),options:.atomic)
    }
    func rect(_ r:CGRect)->[CGFloat] {[r.minX,r.minY,r.width,r.height]}
}

struct MigrationVisibility:ViewModifier {
    let ui:Bool
    @ViewBuilder func body(content:Content)->some View {
        if MigrationEnvironment.frame.request.mode.hasSuffix("-background") || (ui && MigrationEnvironment.frame.request.mode.hasSuffix("-caption")) {content.hidden()}else{content}
    }
}
