import UIKit
import Metal
import MetalKit
import Darwin
import GradientsKit

@main final class AppDelegate:UIResponder,UIApplicationDelegate {
    func application(_ application:UIApplication,configurationForConnecting session:UISceneSession,options:UIScene.ConnectionOptions)->UISceneConfiguration {
        let configuration=UISceneConfiguration(name:"UIKit",sessionRole:session.role)
        configuration.delegateClass=SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate:UIResponder,UIWindowSceneDelegate {
    var window:UIWindow?
    func scene(_ scene:UIScene,willConnectTo session:UISceneSession,options:UIScene.ConnectionOptions) {
        guard let scene=scene as? UIWindowScene else{return}
        let window=UIWindow(windowScene:scene)
        if ProcessInfo.processInfo.environment["GRADIENTS_TEST_HOST_EMPTY"]=="1" {
            // Isolated sanitizer controls must not have a second renderer behind them.
            window.rootViewController=UIViewController()
        } else {do {window.rootViewController=try DemoController(environment:ProcessInfo.processInfo.environment)}
        catch {
            let controller=UIViewController();controller.view.backgroundColor = .systemBackground
            let label=UILabel(frame:window.bounds.insetBy(dx:24,dy:100));label.numberOfLines=0
            label.text="Не удалось запустить Metal: \(error)";controller.view.addSubview(label);window.rootViewController=controller
            NSLog("GradientsUIKit startup failed: %@",String(describing:error))
        }
        }
        window.makeKeyAndVisible();self.window=window
    }
    func sceneWillResignActive(_ scene:UIScene) {(window?.rootViewController as? DemoController)?.gradient.pauseRendering()}
    func sceneDidBecomeActive(_ scene:UIScene) {(window?.rootViewController as? DemoController)?.gradient.resumeRendering()}
}

final class DemoController:UIViewController,UIAdaptivePresentationControllerDelegate {
    let gradient:GradientViewController
    override var prefersStatusBarHidden:Bool {true}
    override var prefersHomeIndicatorAutoHidden:Bool {true}
    init(environment:[String:String]) throws {
        let dark=environment["GRADIENTS_THEME"].map {$0=="dark"} ?? (UserDefaults.standard.string(forKey:"theme")=="dark")
        let yellow=environment["GRADIENTS_COLOR"]=="yellow"
        let progress=Double(environment["GRADIENTS_PROGRESS"] ?? "0") ?? 0
        let session=GradientSession(at:Date().timeIntervalSinceReferenceDate,initialProgress:CGFloat(progress))
        gradient=try GradientViewController(session:session,dark:dark,yellow:yellow)
        super.init(nibName:nil,bundle:nil)
        gradient.onSettings={ [weak self] in self?.showSettings() }
        if environment["GRADIENTS_DIAGNOSTICS"]=="1" {
            var last=0.0
            let benchmark=environment["GRADIENTS_BENCHMARK"]=="1"
            let duration=min(max(Double(environment["GRADIENTS_BENCHMARK_DURATION"] ?? "20") ?? 20,20),90)
            let idleOnly=environment["GRADIENTS_BENCHMARK_IDLE_ONLY"]=="1"
            var memorySamples:[[String:Double]]=[]
            var lastMemorySample = -1.0
            let launched=ProcessInfo.processInfo.systemUptime
            var measuring=false,ended=false
            var startingStats:[String:Double]=[:]
            var phase="warmup"
            let url=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("renderer-state.json")
            gradient.onFrame={ [weak gradient] frame in
                guard let gradient else{return}
                if benchmark {
                    let elapsed=ProcessInfo.processInfo.systemUptime-launched
                    if elapsed-lastMemorySample>=0.5 {
                        var sample=diagnosticMemory(device:(gradient.view.subviews.first as? MTKView)?.device);sample["elapsedSeconds"]=elapsed
                        memorySamples.append(sample);lastMemorySample=elapsed
                    }
                    if elapsed>=3 && !measuring {gradient.beginPerformanceMeasurement();startingStats=gradient.renderStatistics;measuring=true}
                    if elapsed>=3 && elapsed<duration+3 {
                        let t=elapsed-3
                        let next=idleOnly ? "idle":t<3 ? "idle":t<duration-11 ? "swipe":t<duration-8 ? "hold":t<duration-4 ? "release":"idle-after-release"
                        if next=="swipe" {
                            gradient.recordPerformanceInput()
                            gradient.session.dragChanged(to:CGPoint(x:195+sin(t*3.1)*145,y:440+cos(t*2.3)*220),at:frame.time,size:gradient.view.bounds.size)
                        } else if phase=="hold" && next=="release" {gradient.session.dragEnded(at:frame.time)}
                        phase=next
                    } else if elapsed>=duration+3 && !ended {
                        ended=true;gradient.pauseRendering()
                        let expected=max(0,Int(gradient.renderStatistics["submitted",default:0]-startingStats["submitted",default:0]))
                        let drainDeadline=ProcessInfo.processInfo.systemUptime+2
                        func exportWhenDrained() {
                            var report=gradient.performanceReport
                            let completed=(report["completionFrames"] ?? report["presentationFrames"]) as? Int ?? 0
                            let pending=max(0,expected-completed)
                            if pending>0 && ProcessInfo.processInfo.systemUptime<drainDeadline {
                                DispatchQueue.main.asyncAfter(deadline:.now()+0.05,execute:exportWhenDrained);return
                            }
                            report["pendingAtExport"]=pending
                            report["measurementSubmitted"]=expected
                            report["memorySamples"]=memorySamples
                            report["benchmarkDurationSeconds"]=duration
                            report["idleOnly"]=idleOnly
                            report["renderer"]=gradient.renderStatistics.mapValues{$0}.reduce(into:[String:Double]()){d,pair in d[pair.key]=pair.value-(startingStats[pair.key] ?? 0)}
                            let destination=url.deletingLastPathComponent().appendingPathComponent("performance.json")
                            try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:destination,options:.atomic)
                        }
                        DispatchQueue.main.asyncAfter(deadline:.now()+0.05,execute:exportWhenDrained)
                    }
                }
                guard frame.time-last>=0.25 else{return};last=frame.time
                let data:[String:Any]=["engine":gradient.engineDescription,"progress":frame.progress,"rendered":frame.uniforms[2],
                    "theme":frame.dark ? "dark":"light","color":frame.yellow ? "yellow":"blue",
                    "viewport":[frame.uniforms[0],frame.uniforms[1]],"displayScale":gradient.view.window?.screen.scale ?? UIScreen.main.scale,
                    "historyCount":frame.history.count,"distortion":frame.distortion,"statistics":gradient.renderStatistics,"phase":phase]
                try? JSONSerialization.data(withJSONObject:data).write(to:url,options:.atomic)
            }
        }
        NSLog("GradientsUIKit: %@",gradient.engineDescription)
    }
    required init?(coder:NSCoder){fatalError("Use init()")}
    override func viewDidLoad() {
        super.viewDidLoad();addChild(gradient);gradient.view.frame=view.bounds
        gradient.view.autoresizingMask=[.flexibleWidth,.flexibleHeight];view.addSubview(gradient.view);gradient.didMove(toParent:self)
    }
    func showSettings() {
        guard presentedViewController==nil else{return}
        gradient.session.setSettingsVisible(true,at:Date().timeIntervalSinceReferenceDate)
        let panel=SettingsController(gradient:gradient)
        panel.onThemeChanged={dark in UserDefaults.standard.set(dark ? "dark":"light",forKey:"theme")}
        panel.sheetPresentationController?.detents=[.custom(identifier:.init("v2")){_ in 300}]
        panel.sheetPresentationController?.prefersGrabberVisible=false
        panel.presentationController?.delegate=self
        present(panel,animated:true)
    }
    func presentationControllerDidDismiss(_ presentationController:UIPresentationController) {
        gradient.session.setSettingsVisible(false,at:Date().timeIntervalSinceReferenceDate)
    }
}

final class SettingsController:UIViewController {
    weak var gradient:GradientViewController?
    var onThemeChanged:((Bool)->Void)?
    var swatches:[UIButton]=[]
    init(gradient:GradientViewController){self.gradient=gradient;super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder){fatalError("Use init(gradient:)")}
    override func viewDidLoad() {
        super.viewDidLoad();updateTheme()
        let content=UIStackView();content.axis = .vertical;content.alignment = .fill;content.spacing=18
        content.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(content)
        NSLayoutConstraint.activate([content.topAnchor.constraint(equalTo:view.topAnchor,constant:34),
            content.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:22),content.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-22)])
        let title=UILabel();title.text="Настройки"
        title.font=UIFont(descriptor:UIFont.systemFont(ofSize:24,weight:.bold).fontDescriptor.withDesign(.rounded)!,size:24)
        content.addArrangedSubview(title)
        func section(_ title:String)->UIStackView {
            let group=UIStackView();group.axis = .vertical;group.spacing=8
            let label=UILabel();label.font = .systemFont(ofSize:13,weight:.medium);label.text=title
            group.addArrangedSubview(label);content.addArrangedSubview(group);return group
        }
        let theme=UISegmentedControl(items:["Светлая","Тёмная"])
        theme.accessibilityIdentifier="theme";theme.accessibilityLabel="Тема"
        theme.selectedSegmentIndex=gradient?.dark == true ? 1:0
        theme.heightAnchor.constraint(equalToConstant:32).isActive=true
        theme.addAction(UIAction { [weak self] action in
            guard let self,let value=action.sender as? UISegmentedControl else{return}
            self.gradient?.dark=value.selectedSegmentIndex==1;self.onThemeChanged?(value.selectedSegmentIndex==1);self.updateTheme()
        },for:.valueChanged);section("Тема").addArrangedSubview(theme)
        let colors=UIStackView();colors.axis = .horizontal;colors.distribution = .fillEqually;colors.spacing=9
        section("Цвет градиента").addArrangedSubview(colors)
        for (index,name) in ["Синий","Жёлтый"].enumerated() {
            let button=UIButton();button.heightAnchor.constraint(equalToConstant:45).isActive=true
            button.accessibilityLabel=name;button.accessibilityIdentifier=index==0 ? "blue":"yellow"
            let circle=UIView();circle.translatesAutoresizingMaskIntoConstraints=false;circle.isUserInteractionEnabled=false
            circle.backgroundColor=index==0 ? UIColor(red:0.26,green:0.55,blue:0.98,alpha:1):UIColor(red:1,green:0.7,blue:0,alpha:1)
            circle.layer.cornerRadius=14;circle.layer.shadowColor=circle.backgroundColor?.cgColor;circle.layer.shadowOpacity=0.3;circle.layer.shadowRadius=8;circle.layer.shadowOffset=CGSize(width:0,height:3)
            let label=UILabel();label.translatesAutoresizingMaskIntoConstraints=false;label.font = .systemFont(ofSize:10,weight:.semibold)
            label.textAlignment = .center;label.textColor = .secondaryLabel;label.text=name
            button.addSubview(circle);button.addSubview(label)
            NSLayoutConstraint.activate([circle.widthAnchor.constraint(equalToConstant:28),circle.heightAnchor.constraint(equalToConstant:28),
                circle.topAnchor.constraint(equalTo:button.topAnchor),circle.centerXAnchor.constraint(equalTo:button.centerXAnchor),
                label.topAnchor.constraint(equalTo:circle.bottomAnchor,constant:5),label.centerXAnchor.constraint(equalTo:button.centerXAnchor)])
            button.addAction(UIAction { [weak self] _ in self?.gradient?.yellow=index==1;self?.updateSwatches() },for:.touchUpInside)
            swatches.append(button);colors.addArrangedSubview(button)
        }
        updateSwatches()
    }
    func updateTheme() {
        let dark=gradient?.dark == true
        overrideUserInterfaceStyle=dark ? .dark:.light
        view.backgroundColor=dark ? UIColor(red:0.04,green:0.05,blue:0.08,alpha:1):.white
    }
    func updateSwatches() {
        for (i,button) in swatches.enumerated() {
            let selected=gradient?.yellow == (i==1);button.accessibilityValue=selected ? "Выбрано":""
            button.subviews.first?.layer.borderColor=UIColor.white.withAlphaComponent(selected ? 0.95:0.28).cgColor
            button.subviews.first?.layer.borderWidth=selected ? 3:1
        }
    }
}

// Opt-in demo diagnostics only; never used by GradientsKit or ordinary launches.
private func diagnosticMemory(device:MTLDevice?)->[String:Double] {
    var info=task_vm_info_data_t()
    var count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
    let status=withUnsafeMutablePointer(to:&info) {pointer in
        pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
            task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)
        }
    }
    var result:[String:Double]=["machStatus":Double(status)]
    if status == KERN_SUCCESS {
        result["residentBytes"]=Double(info.resident_size)
        result["footprintBytes"]=Double(info.phys_footprint)
    }
    if let device {result["deviceAllocatedBytes"]=Double(device.currentAllocatedSize)}
    let thread=mach_thread_self()
    defer {mach_port_deallocate(mach_task_self_,thread)}
    var cpu=thread_basic_info_data_t()
    var threadCount=mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size/MemoryLayout<integer_t>.size)
    let cpuStatus=withUnsafeMutablePointer(to:&cpu) {pointer in
        pointer.withMemoryRebound(to:integer_t.self,capacity:Int(threadCount)) {
            thread_info(thread,thread_flavor_t(THREAD_BASIC_INFO),$0,&threadCount)
        }
    }
    if cpuStatus == KERN_SUCCESS {
        result["mainThreadCPUSeconds"]=Double(cpu.user_time.seconds+cpu.system_time.seconds)+Double(cpu.user_time.microseconds+cpu.system_time.microseconds)/1_000_000
    }
    return result
}
