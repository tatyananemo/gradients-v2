// UIKit renderer based on the visually approved feasibility prototype.
// The original SwiftUI application and its shader modules remain independent.
import UIKit
import MetalKit
import CoreText

public final class GradientViewController:UIViewController,MTKViewDelegate {
    static var context:GradientGPU?
    let gpu:GradientGPU
    var uniforms:[Float],history:[Float]
    var caption:CGRect,counter:CGRect
    var f:GradientRenderFrame
    public let session:GradientSession
    public var dark:Bool
    let yellow=true
    public var onSettings:(()->Void)?
    public var onFrame:((GradientRenderFrame)->Void)?
    var displayLink:CADisplayLink?
    private var hasAppeared=false
    private var explicitlyPaused=false
    private var applicationInactive=false
    private var sceneInactive=false
    private var inputRecognizer:GradientInputRecognizer?
    var clock:()->TimeInterval = { Date().timeIntervalSinceReferenceDate }
    var externallyDriven=false
    var counterLabel:GradientPercentageLabel?
    var resetPresentation:GradientResetPresentation?
    var maskCPUTime:Double=0
    var cpuFrameTime:Double=0
    var gpuTime:Double=0
    var performanceSamples=0
    var performanceMetrics:GradientPerformanceMetrics?
    private var performanceFrame=0
    /// Enables bounded timing samples only for explicit profiling runs.
    public func beginPerformanceMeasurement() {performanceMetrics=GradientPerformanceMetrics()}
    public func recordPerformanceInput() {performanceMetrics?.input(at:ProcessInfo.processInfo.systemUptime)}
    public var performanceReport:[String:Any] {performanceMetrics?.report() ?? [:]}
    var captionLabel:UILabel?
    var counterWrapper:UIView?
    var captionGradient:CAGradientLayer?
    var buttonImages:[UIImageView]=[]
    var controlButtons:[UIButton]=[]
    var controlBackgrounds:[UIVisualEffectView]=[]
    var captionBox:UIView?
    private var currentSize=CGSize.zero
    private var renderingScale:CGFloat {view.window?.screen.scale ?? UIScreen.main.scale}
    var captionProbe:SessionCaptionProbe?
    var inFlight:Bool {availableSlots.contains(false)}
    var availableSlots=[true,true,true]
    var activeSlot=0
    var uniformSlots:[MTLBuffer]=[]
    var historySlots:[MTLBuffer]=[]
    var lastCaptionStyle:String?
    var lastCaptionActivation:Double = -1
    private(set) var moveCallbacks=0
    private(set) var inputCallbacks=0
    var framesSubmitted=0
    var framesSkipped=0
    var gpuErrors:[String]=[]
    var viewMetal:MTKView!
    var backing:MTLTexture!,distorted:MTLTexture!
    var masks:[MTLTexture]=[]
    var maskRenderer:GradientMaskRenderer!
    var uniformBuffer:MTLBuffer!,historyBuffer:MTLBuffer!
    var diagnostics:[String:Any]=[:]
    var rendered=false
    var finished=false
    var backgroundOnly:Bool {false}
    var captionOnly:Bool {false}
    public init(session:GradientSession, dark:Bool,
                size:CGSize=CGSize(width:390,height:844)) throws {
        if Self.context == nil {Self.context=try GradientGPU()}
        self.gpu=Self.context!;self.session=session;self.dark=dark
        let frame=session.frame(at:Date().timeIntervalSinceReferenceDate,size:size,dark:dark,yellow:yellow)
        f=frame;uniforms=frame.uniforms;history=frame.history
        // These are the accepted V2 full-screen layout constants. SDK layout generalization is a later milestone.
        caption=CGRect(x:0,y:size.height-82-63.3333333333333,width:size.width,height:63.3333333333333)
        counter=CGRect(x:0,y:356,width:size.width,height:76.6666666666667)
        super.init(nibName:nil,bundle:nil)
    }
    public required init?(coder:NSCoder){fatalError("Use init(session:dark:size:)")}
    public override var prefersStatusBarHidden:Bool {true}
    public override var prefersHomeIndicatorAutoHidden:Bool {true}
    public override func viewDidLoad() {
        super.viewDidLoad()
        let scale=renderingScale,size=UIScreen.main.bounds.size
        view.backgroundColor = .black
        let metal=MTKView(frame:CGRect(origin:.zero,size:size),device:gpu.device)
        metal.colorPixelFormat = .bgra8Unorm
        (metal.layer as! CAMetalLayer).colorspace=CGColorSpace(name:CGColorSpace.sRGB)
        metal.framebufferOnly=true;metal.isPaused=true;metal.enableSetNeedsDisplay=false
        metal.contentScaleFactor=scale;metal.autoResizeDrawable=false
        metal.drawableSize=CGSize(width:size.width*scale,height:size.height*scale)
        view.addSubview(metal);viewMetal=metal
        func texture()->MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:Int(size.width*scale),height:Int(size.height*scale),mipmapped:false)
            d.usage=[.shaderRead,.shaderWrite,.renderTarget];d.storageMode = .private
            return gpu.device.makeTexture(descriptor:d)!
        }
        backing=texture();distorted=texture()
        uniformSlots=(0..<3).map {_ in gpu.device.makeBuffer(length:28*4,options:.storageModeShared)!}
        historySlots=(0..<3).map {_ in gpu.device.makeBuffer(length:240*4,options:.storageModeShared)!}
        uniformBuffer=uniformSlots[0];historyBuffer=historySlots[0]
        maskRenderer=GradientMaskRenderer(device:gpu.device,queue:gpu.queue)
        masks=[gpu.clear,gpu.clear,gpu.clear]
        if !backgroundOnly {addCaption(size)}
        if !backgroundOnly && !captionOnly {addCounter();addButtons(size)}
        captionProbe=SessionCaptionProbe(gpu:gpu)
        let input=GradientInputRecognizer(target:self,action:#selector(inputChanged(_:)))
        input.cancelsTouchesInView=false;view.addGestureRecognizer(input);inputRecognizer=input
        metal.delegate=self
        let notifications=NotificationCenter.default
        notifications.addObserver(self,selector:#selector(applicationWillResignActive),name:UIApplication.willResignActiveNotification,object:nil)
        notifications.addObserver(self,selector:#selector(applicationDidBecomeActive),name:UIApplication.didBecomeActiveNotification,object:nil)
        notifications.addObserver(self,selector:#selector(sceneWillDeactivate(_:)),name:UIScene.willDeactivateNotification,object:nil)
        notifications.addObserver(self,selector:#selector(sceneDidActivate(_:)),name:UIScene.didActivateNotification,object:nil)
        diagnostics=["background":"unchanged v2ComposeBackground via compute adapter","pixelFormat":"bgra8Unorm; rgba16Float intermediates","colorspace":"sRGB","maskImplementation":"CG radial/ellipse -> CoreImage Gaussian -> original exclusion -> normal/multiply/screen","maskPrecision":"8-bit CG source, 16-bit float intermediate","blurRadiusMapping":"same numeric radius * screen scale * breath; equivalence unproven","caption":"Dark backing before masks in Metal compositor; Light native CAGradientLayer, original stops","UI":"UIKit fonts/materials based on visually accepted feasibility prototype"]
    }
    public override func viewDidAppear(_ animated:Bool){
        super.viewDidAppear(animated);hasAppeared=true
        applicationInactive=UIApplication.shared.applicationState == .background
        sceneInactive=view.window?.windowScene.map {$0.activationState != .foregroundActive} ?? false
        updateDisplayLink();tick()
    }
    private func updateDisplayLink() {
        guard hasAppeared,!externallyDriven else{return}
        if displayLink == nil {
            let link=CADisplayLink(target:GradientDisplayTarget(self),selector:#selector(GradientDisplayTarget.tick(_:)))
            link.preferredFrameRateRange=CAFrameRateRange(minimum:30,maximum:60,preferred:60)
            link.add(to:.main,forMode:.common);displayLink=link
        }
        displayLink?.isPaused=explicitlyPaused || applicationInactive || sceneInactive
    }
    private var hasRenderableBounds:Bool {
        let size=view.bounds.size
        return size.width.isFinite && size.height.isFinite && size.width*renderingScale>=1 && size.height*renderingScale>=1
    }
    private var canRender:Bool {
        guard hasAppeared,!explicitlyPaused,!applicationInactive,!sceneInactive,
              let window=view.window,!window.isHidden,hasRenderableBounds else{return false}
        if let scene=window.windowScene,scene.activationState != .foregroundActive {return false}
        if UIApplication.shared.applicationState == .background {return false}
        var ancestor:UIView?=view
        while let current=ancestor {
            if current.isHidden || current.alpha==0 {return false}
            ancestor=current.superview
        }
        return view.convert(view.bounds,to:window).intersects(window.bounds)
    }
    private func endInterruptedInput() {
        if let input=inputRecognizer,input.state == .began || input.state == .changed {
            input.isEnabled=false;input.isEnabled=true
        }
        if session.waterTouchIsActive {session.dragEnded(at:clock())}
    }
    @objc private func applicationWillResignActive() {
        applicationInactive=true;endInterruptedInput();updateDisplayLink()
    }
    @objc private func applicationDidBecomeActive() {applicationInactive=false;updateDisplayLink()}
    @objc private func sceneWillDeactivate(_ notice:Notification) {
        guard let scene=notice.object as? UIScene,scene === viewIfLoaded?.window?.windowScene else{return}
        sceneInactive=true;endInterruptedInput();updateDisplayLink()
    }
    @objc private func sceneDidActivate(_ notice:Notification) {
        guard let scene=notice.object as? UIScene,scene === viewIfLoaded?.window?.windowScene else{return}
        sceneInactive=false;updateDisplayLink()
    }
    public var engineDescription:String {"UIKit + Metal / GradientsKit / \(String(describing:type(of:self)))"}
    public var renderStatistics:[String:Double] {
        ["submitted":Double(framesSubmitted),"skipped":Double(framesSkipped),"samples":Double(performanceSamples),
         "maskPreparationMS":maskCPUTime,"cpuPreparationMS":cpuFrameTime,"gpuMS":gpuTime]
    }
    public func pauseRendering() {explicitlyPaused=true;endInterruptedInput();updateDisplayLink()}
    public func resumeRendering() {explicitlyPaused=false;updateDisplayLink()}
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews();synchronizeDrawableLayout()
    }
    private func synchronizeDrawableLayout() {
        guard let metal=viewMetal,hasRenderableBounds else{return}
        let size=view.bounds.size
        let pixelSize=CGSize(width:ceil(size.width*renderingScale),height:ceil(size.height*renderingScale))
        guard currentSize != size || metal.contentScaleFactor != renderingScale || metal.drawableSize != pixelSize else{return}
        currentSize=size
        let textHeight:CGFloat
        if abs(size.width-390)<0.01 {textHeight=63.3333333333333}
        else {
            let measured=captionLabel?.sizeThatFits(CGSize(width:max(size.width-68,1),height:.greatestFiniteMagnitude)).height ?? 64
            textHeight=ceil(measured*renderingScale)/renderingScale
        }
        caption=CGRect(x:0,y:size.height-82-textHeight,width:size.width,height:textHeight)
        let center=(size.height+90-(82+textHeight))/2
        counter=CGRect(x:0,y:center-76.6666666666667/2,width:size.width,height:76.6666666666667)
        metal.frame=view.bounds;metal.contentScaleFactor=renderingScale
        metal.drawableSize=CGSize(width:ceil(size.width*renderingScale),height:ceil(size.height*renderingScale))
        func texture()->MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:Int(metal.drawableSize.width),height:Int(metal.drawableSize.height),mipmapped:false)
            d.usage=[.shaderRead,.shaderWrite,.renderTarget];d.storageMode = .private
            return gpu.device.makeTexture(descriptor:d)!
        }
        // Layout can change without changing the texture descriptor, including
        // the first layout after viewDidLoad has already allocated this extent.
        if backing.width != Int(pixelSize.width) || backing.height != Int(pixelSize.height) {
            backing=texture();distorted=texture()
        }
        captionLabel?.frame=CGRect(x:34,y:caption.minY,width:max(1,size.width-68),height:caption.height)
        counterLabel?.frame=counter;counterWrapper?.frame=view.bounds
        captionBox?.frame=CGRect(x:0,y:size.height*0.7,width:size.width,height:size.height*0.3)
        CATransaction.begin();CATransaction.setDisableActions(true);captionGradient?.frame=captionBox?.bounds ?? .zero;CATransaction.commit()
        for (i,button) in controlButtons.enumerated() {
            let width:CGFloat=i==0 ? 32:34
            let rect=CGRect(x:i==0 ? 24:size.width-24-width,y:56+(34-width)/2,width:width,height:width)
            button.frame=rect;controlBackgrounds[i].frame=rect
        }
    }
    public override func viewDidDisappear(_ animated:Bool) {
        super.viewDidDisappear(animated);hasAppeared=false;endInterruptedInput()
        displayLink?.invalidate();displayLink=nil
    }
    deinit {displayLink?.invalidate();NotificationCenter.default.removeObserver(self)}
    @objc private func inputChanged(_ input:GradientInputRecognizer) {
        guard !externallyDriven else{return}
        let time=clock()
        recordPerformanceInput()
        inputCallbacks+=1
        if input.state == .changed {moveCallbacks+=1}
        switch input.state {
        case .began,.changed:
            guard canRender else{endInterruptedInput();return}
            resetPresentation=nil;session.dragChanged(to:input.point,at:time,size:view.bounds.size)
        case .ended,.cancelled:session.dragEnded(at:time)
        default:break
        }
    }
    @objc func resetPressed() { reset(animated:true) }
    public func reset(animated:Bool=true) {
        let now=clock()
        resetPresentation=animated ? GradientResetPresentation(started:now,counter:session.targetProgress,
            mask:session.interpolatedProgress(at:now)):nil
        session.reset(at:now)
        if animated {counterLabel?.setPercentage(0,animated:true)}
        else {counterLabel?.setPercentageImmediately(0)}
    }
    var presentationCounter:CGFloat {resetPresentation?.values(at:f.time).counter ?? f.progress}
    var presentationMask:CGFloat {resetPresentation?.values(at:f.time).mask ?? session.interpolatedProgress(at:f.time)}
    @objc func settingsPressed() { onSettings?() }
    func tick() {
        guard !externallyDriven else{return}
        guard canRender else{endInterruptedInput();return}
        // Bounds may change before UIKit's next layout pass. All textures,
        // masks and frame arguments must observe one authoritative viewport.
        view.layoutIfNeeded();synchronizeDrawableLayout()
        let frame=session.frame(at:clock(),size:view.bounds.size,dark:dark,yellow:yellow)
        present(frame)
        onFrame?(frame)
    }
    func present(_ frame:GradientRenderFrame, activation:Double?=nil) {
        guard hasRenderableBounds else{return}
        synchronizeDrawableLayout()
        // Each in-flight frame owns its shared CPU inputs. No semaphore wait on main.
        guard let slot=availableSlots.firstIndex(of:true) else {framesSkipped+=1;return}
        activeSlot=slot;availableSlots[slot]=false
        uniformBuffer=uniformSlots[slot];historyBuffer=historySlots[slot]
        performanceFrame+=1
        let cpuStart=ProcessInfo.processInfo.systemUptime
        f=frame;uniforms=frame.uniforms;history=frame.history
        if resetPresentation?.values(at:f.time).finished == true {resetPresentation=nil}
        uniforms.withUnsafeBytes {memcpy(uniformBuffer.contents(),$0.baseAddress!,$0.count)}
        if !history.isEmpty {history.withUnsafeBytes {memcpy(historyBuffer.contents(),$0.baseAddress!,$0.count)}}
        let maskStart=ProcessInfo.processInfo.systemUptime
        if f.dark {masks=maskRenderer.render(progress:presentationMask,elapsed:f.time-session.startTime,yellow:f.yellow,counter:counter,size:view.bounds.size,scale:renderingScale,metrics:performanceMetrics,frame:performanceFrame)}
        else {masks=[gpu.clear,gpu.clear,gpu.clear]}
        let maskMS=(ProcessInfo.processInfo.systemUptime-maskStart)*1000
        maskCPUTime+=maskMS;performanceMetrics?.add("maskPreparationMS",maskMS)
        if !externallyDriven {captionProbe?.sample(uniforms:uniforms,history:history,frame:caption,key:"\(dark):\(yellow)",dark:dark,yellow:yellow,metrics:performanceMetrics)}
        updateUI(activation:activation ?? captionProbe?.activation ?? 0)
        rendered=false;finished=false;viewMetal.draw()
        let cpuMS=(ProcessInfo.processInfo.systemUptime-cpuStart)*1000
        cpuFrameTime+=cpuMS;performanceSamples+=1;performanceMetrics?.add("cpuFrameMS",cpuMS)
    }
    func updateUI(activation:Double) {
        let p=presentationCounter
        counterLabel?.setPercentage(Int(round(f.progress*100)))
        counterLabel?.textColor=f.dark ? UIColor(red:0.92,green:0.95,blue:1,alpha:1):UIColor(red:0.18-p*0.02,green:0.18-p*0.02,blue:0.20,alpha:1)
        counterLabel?.layer.shadowColor=(f.dark ? UIColor.black:UIColor.cyan).cgColor
        counterLabel?.layer.shadowOpacity=Float(f.dark ? 0.34:0.04+p*0.16)
        counterLabel?.layer.shadowRadius=f.dark ? 16:2+p*9
        counterWrapper?.layer.shadowColor=(f.dark ? UIColor.black:UIColor.white).cgColor
        counterWrapper?.layer.shadowOpacity=f.dark ? 0.18:Float(resetPresentation.map {let v=$0.values(at:f.time);return 0.04+($0.counter>0.55 ? 0.12:0)*(v.counter/max($0.counter,0.0001))} ?? (p>0.55 ? 0.16:0.04))
        counterWrapper?.layer.shadowRadius=f.dark ? 8:(resetPresentation.map {let v=$0.values(at:f.time);return 1+($0.counter>0.55 ? 4:0)*(v.counter/max($0.counter,0.0001))} ?? (p>0.55 ? 5:1))
        let style="\(f.dark):\(f.yellow)"
        if lastCaptionStyle != style {
            captionLabel?.textColor=f.dark ? UIColor(red:0.86,green:0.91,blue:0.98,alpha:1):UIColor(white:0.2,alpha:1)
            if let captionLabel,let old=captionLabel.attributedText {
                let text=NSMutableAttributedString(attributedString:old)
                text.addAttribute(.foregroundColor,value:captionLabel.textColor!,range:NSRange(location:0,length:text.length))
                captionLabel.attributedText=text
            }
        }
        if lastCaptionStyle != style || lastCaptionActivation != activation {
            let tint=f.yellow ? UIColor(red:1,green:1,blue:0.3,alpha:1):UIColor.white
            CATransaction.begin();CATransaction.setDisableActions(true)
            captionGradient?.colors=(0...16).map {i in let v=Double(i)/16;return tint.withAlphaComponent(0.3*(1-pow(1-v,3))*activation).cgColor}
            captionGradient?.isHidden=f.dark
            CATransaction.commit()
            lastCaptionActivation=activation
        }
        lastCaptionStyle=style
        for (i,image) in buttonImages.enumerated() {
            if i==1 {image.superview?.superview?.layer.borderColor=UIColor.white.withAlphaComponent(f.dark ? 0.24:0.38).cgColor}
            image.tintColor=i==1 ? ((uniforms[2]>0.42 || f.dark) ? UIColor.white.withAlphaComponent(0.94):UIColor.gray.withAlphaComponent(0.88)):(f.dark ? UIColor.white.withAlphaComponent(0.78):UIColor.gray)
        }
    }
    public func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize){}
    public func draw(in view:MTKView) {
        guard !rendered else{return}
        let completedSlot=activeSlot
        let drawableStart=ProcessInfo.processInfo.systemUptime
        guard let drawable=view.currentDrawable,let command=gpu.queue.makeCommandBuffer() else {availableSlots[completedSlot]=true;return}
        performanceMetrics?.add("drawableAcquisitionMS",(ProcessInfo.processInfo.systemUptime-drawableStart)*1000)
        framesSubmitted+=1
        let metrics=performanceMetrics,frameID=performanceFrame,expected=f.dark ? 4:1
        let inputTime=metrics?.consumeInput() ?? 0
        #if !targetEnvironment(simulator)
        if let metrics {drawable.addPresentedHandler {shown in metrics.presented(at:shown.presentedTime,input:inputTime)}}
        #endif
        let scale=Float(renderingScale)
        func encode(_ texture:MTLTexture,_ pipeline:MTLRenderPipelineState,_ bind:(MTLRenderCommandEncoder)->Void) {
            let desc=MTLRenderPassDescriptor();desc.colorAttachments[0].texture=texture
            desc.colorAttachments[0].loadAction = .dontCare;desc.colorAttachments[0].storeAction = .store
            let enc=command.makeRenderCommandEncoder(descriptor:desc)!
            enc.setRenderPipelineState(pipeline);bind(enc)
            enc.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);enc.endEncoding()
        }
        let encoder=command.makeComputeCommandEncoder()!
        var backgroundScale=scale
        encoder.setComputePipelineState(gpu.background);encoder.setTexture(backing,index:0)
        encoder.setBuffer(uniformBuffer,offset:0,index:0);encoder.setBuffer(historyBuffer,offset:0,index:1)
        encoder.setBytes(&backgroundScale,length:4,index:2)
        encoder.dispatchThreads(MTLSize(width:backing.width,height:backing.height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1));encoder.endEncoding()
        let strength=f.distortion
        var input=backing!
        if strength>0.002 {
            encode(distorted,gpu.distortion) {enc in
                var p=SIMD4<Float>(uniforms[0],uniforms[1],strength,scale)
                enc.setFragmentTexture(backing,index:0);enc.setFragmentBuffer(uniformBuffer,offset:0,index:0)
                enc.setFragmentBytes(&p,length:16,index:1)
            }
            input=distorted
        }
        encode(drawable.texture,gpu.composite) {enc in
            var p=SIMD4<Float>(scale,(backgroundOnly || captionOnly) ? 0:1,(f.dark && !backgroundOnly) ? 1:0,0)
            enc.setFragmentTexture(input,index:0)
            for i in 0..<3 {enc.setFragmentTexture(masks[i],index:i+1)}
            enc.setFragmentBuffer(uniformBuffer,offset:0,index:0);enc.setFragmentBytes(&p,length:16,index:1)
        }
        let committedAt=metrics == nil ? 0:ProcessInfo.processInfo.systemUptime
        if let metrics {
            command.addScheduledHandler {_ in metrics.add("scheduledCallbackDelayMS",(ProcessInfo.processInfo.systemUptime-committedAt)*1000)}
        }
        command.addCompletedHandler { [weak self] command in
            let callbackTime=metrics == nil ? 0:ProcessInfo.processInfo.systemUptime
            if let metrics,command.gpuEndTime>0,callbackTime>=command.gpuEndTime {
                metrics.add("gpuEndToCallbackMS",(callbackTime-command.gpuEndTime)*1000)
            }
            metrics?.gpu(frame:frameID,expected:expected,kind:"compositionGPUMS",start:command.gpuStartTime,end:command.gpuEndTime)
            #if targetEnvironment(simulator)
            metrics?.presented(at:ProcessInfo.processInfo.systemUptime,input:inputTime)
            #endif
            DispatchQueue.main.async {
            if let metrics {metrics.add("completionToMainMS",(ProcessInfo.processInfo.systemUptime-callbackTime)*1000)}
            self?.finished=command.status == .completed;self?.availableSlots[completedSlot]=true
            self?.gpuTime+=max(0,command.gpuEndTime-command.gpuStartTime)*1000
            if command.status != .completed {self?.gpuErrors.append(String(describing:command.error));metrics?.add("compositionCommandErrors",1)}
        }}
        command.present(drawable);command.commit();rendered=true
    }
    func addCaption(_ size:CGSize) {
        let box=UIView(frame:CGRect(x:0,y:size.height*0.7,width:size.width,height:size.height*0.3))
        let gradient=CAGradientLayer();gradient.frame=box.bounds;gradient.startPoint=CGPoint(x:0.5,y:0);gradient.endPoint=CGPoint(x:0.5,y:1)
        if f.dark {gradient.colors=[UIColor.black.withAlphaComponent(0).cgColor,UIColor.black.withAlphaComponent(0.3).cgColor]}
        else {
            let tint=f.yellow ? UIColor(red:1,green:1,blue:0.3,alpha:1):UIColor.white
            gradient.colors=(0...16).map {i in let v=Double(i)/16;return tint.withAlphaComponent(0.3*(1-pow(1-v,3))*0).cgColor}
            gradient.locations=(0...16).map {NSNumber(value:Double($0)/16)}
        }
        box.layer.addSublayer(gradient);box.isUserInteractionEnabled=false;view.addSubview(box);captionBox=box;captionGradient=gradient;gradient.isHidden=f.dark
        if captionOnly {return}
        let text=UILabel(frame:CGRect(x:34,y:caption.minY,width:size.width-68,height:caption.height))
        text.numberOfLines=0;text.textAlignment = .center
        text.font = .systemFont(ofSize:17,weight:.medium)
        text.textColor=f.dark ? UIColor(red:0.86,green:0.91,blue:0.98,alpha:1):UIColor(white:0.2,alpha:1)
        let style=NSMutableParagraphStyle();style.alignment = .center;style.lineSpacing=1.2
        text.attributedText=NSAttributedString(string:"Устанавливаем защищенное соединение. Водите пальцем в разных частях экрана",attributes:[.font:text.font!,.foregroundColor:text.textColor!,.paragraphStyle:style])
        view.addSubview(text);captionLabel=text
    }
    func addCounter() {
        let p=f.progress
        let label=GradientPercentageLabel(frame:counter)
        let base=UIFont.systemFont(ofSize:64,weight:.bold).fontDescriptor.withDesign(.rounded)!
        let font=base.addingAttributes([.featureSettings:[[UIFontDescriptor.FeatureKey.type:kNumberSpacingType,UIFontDescriptor.FeatureKey.selector:kMonospacedNumbersSelector]]])
        label.font=UIFont(descriptor:font,size:64);label.textAlignment = .center
        label.text="\(Int(round(p*100)))%"
        label.textColor=f.dark ? UIColor(red:0.92,green:0.95,blue:1,alpha:1):UIColor(red:0.18-p*0.02,green:0.18-p*0.02,blue:0.20,alpha:1)
        label.layer.shadowColor=(f.dark ? UIColor.black:UIColor.cyan).cgColor
        label.layer.shadowOpacity=Float(f.dark ? 0.34:0.04+p*0.16)
        label.layer.shadowRadius=f.dark ? 16:2+p*9;label.layer.shadowOffset = .zero
        let wrap=UIView(frame:view.bounds)
        wrap.layer.shadowColor=(f.dark ? UIColor.black:UIColor.white).cgColor
        wrap.layer.shadowOpacity=f.dark ? 0.18:(p>0.55 ? 0.16:0.04)
        wrap.layer.shadowRadius=f.dark ? 8:(p>0.55 ? 5:1);wrap.layer.shadowOffset = .zero
        wrap.isUserInteractionEnabled=false;wrap.addSubview(label);view.addSubview(wrap);counterLabel=label;counterWrapper=wrap
    }
    func addButtons(_ size:CGSize) {
        let p=session.interpolatedProgress(at:f.time)
        for (gear,width,x) in [(false,CGFloat(32),CGFloat(24)),(true,CGFloat(34),size.width-24-34)] {
            let blur=UIVisualEffectView(effect:UIBlurEffect(style:.systemUltraThinMaterial))
            // Match the reference: appTheme does not override the root system color scheme.
            blur.frame=CGRect(x:x,y:56+(34-width)/2,width:width,height:width)
            blur.layer.cornerRadius=width/2;blur.clipsToBounds=true
            if gear {blur.layer.borderWidth=1;blur.layer.borderColor=UIColor.white.withAlphaComponent(f.dark ? 0.24:0.38).cgColor}
            let image=UIImageView(image:UIImage(systemName:gear ? "gearshape.fill":"xmark",withConfiguration:UIImage.SymbolConfiguration(pointSize:gear ? 14:13,weight:.semibold)))
            image.contentMode = .center;image.frame=blur.bounds
            image.tintColor=gear ? ((p>0.42 || f.dark) ? UIColor.white.withAlphaComponent(0.94):(f.dark ? UIColor.white.withAlphaComponent(0.92):UIColor.gray.withAlphaComponent(0.88))):(f.dark ? UIColor.white.withAlphaComponent(0.78):UIColor.gray)
            blur.contentView.addSubview(image);view.addSubview(blur);buttonImages.append(image);controlBackgrounds.append(blur)
            let button=UIButton(frame:blur.frame);button.accessibilityLabel=gear ? "Настройки":"Сбросить"
            button.addTarget(self,action:gear ? #selector(settingsPressed):#selector(resetPressed),for:.touchUpInside)
            view.addSubview(button);controlButtons.append(button)
        }
    }
}
private final class GradientDisplayTarget:NSObject {
    weak var owner:GradientViewController?
    init(_ owner:GradientViewController){self.owner=owner}
    @objc func tick(_ link:CADisplayLink){owner?.performanceMetrics?.displayLink(at:link.timestamp);owner?.tick()}
}
/// Zero minimum-distance continuous input; taps never replace swipes.
private final class GradientInputRecognizer:UIGestureRecognizer {
    var point=CGPoint.zero
    private var trackedTouch:UITouch?
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent) {
        guard trackedTouch == nil,let touch=touches.first,let view else{return}
        let p=touch.location(in:view)
        // Top controls belong to the host UI, not the gradient gesture.
        if view.hitTest(p,with:event) is UIControl {state = .failed;return}
        trackedTouch=touch;point=p;state = .began
    }
    override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent) {
        guard let touch=trackedTouch,touches.contains(touch),let view else{return}
        point=touch.location(in:view);state = .changed
    }
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent) {
        guard let touch=trackedTouch,touches.contains(touch) else{return}
        state = .ended;trackedTouch=nil
    }
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent) {
        guard let touch=trackedTouch,touches.contains(touch) else{return}
        state = .cancelled;trackedTouch=nil
    }
    override func reset(){super.reset();trackedTouch=nil}
}
