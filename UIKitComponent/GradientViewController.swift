// UIKit renderer based on the visually approved feasibility prototype.
// The original SwiftUI application and its shader modules remain independent.
import UIKit
import MetalKit
import CoreImage
import CoreText

public final class GradientViewController:UIViewController,MTKViewDelegate {
    static var context:GradientGPU?
    let gpu:GradientGPU
    var uniforms:[Float],history:[Float]
    let caption:CGRect,counter:CGRect
    var f:GradientRenderFrame
    public let session:GradientSession
    public var dark:Bool
    public var yellow:Bool
    public var onSettings:(()->Void)?
    public var onFrame:((GradientRenderFrame)->Void)?
    var displayLink:CADisplayLink?
    var clock:()->TimeInterval = { Date().timeIntervalSinceReferenceDate }
    var externallyDriven=false
    var counterLabel:GradientPercentageLabel?
    var resetPresentation:GradientResetPresentation?
    var maskCPUTime:Double=0
    var cpuFrameTime:Double=0
    var gpuTime:Double=0
    var performanceSamples=0
    var captionLabel:UILabel?
    var counterWrapper:UIView?
    var captionGradient:CAGradientLayer?
    var buttonImages:[UIImageView]=[]
    var captionProbe:SessionCaptionProbe?
    var inFlight=false
    private(set) var moveCallbacks=0
    private(set) var inputCallbacks=0
    var framesSubmitted=0
    var framesSkipped=0
    var gpuErrors:[String]=[]
    var viewMetal:MTKView!
    var backing:MTLTexture!,distorted:MTLTexture!
    var masks:[MTLTexture]=[]
    var uniformBuffer:MTLBuffer!,historyBuffer:MTLBuffer!
    var diagnostics:[String:Any]=[:]
    var rendered=false
    var finished=false
    var backgroundOnly:Bool {false}
    var captionOnly:Bool {false}
    public init(session:GradientSession, dark:Bool, yellow:Bool,
                size:CGSize=CGSize(width:390,height:844)) throws {
        if Self.context == nil {Self.context=try GradientGPU()}
        self.gpu=Self.context!;self.session=session;self.dark=dark;self.yellow=yellow
        let frame=session.frame(at:Date().timeIntervalSinceReferenceDate,size:size,dark:dark,yellow:yellow)
        f=frame;uniforms=frame.uniforms;history=frame.history
        // These are the accepted V2 full-screen layout constants. SDK layout generalization is a later milestone.
        caption=CGRect(x:0,y:size.height-82-63.3333333333333,width:size.width,height:63.3333333333333)
        counter=CGRect(x:0,y:356,width:size.width,height:76.6666666666667)
        super.init(nibName:nil,bundle:nil)
    }
    public required init?(coder:NSCoder){fatalError("Use init(session:dark:yellow:size:)")}
    public override var prefersStatusBarHidden:Bool {true}
    public override var prefersHomeIndicatorAutoHidden:Bool {true}
    public override func viewDidLoad() {
        super.viewDidLoad()
        let scale=UIScreen.main.scale,size=UIScreen.main.bounds.size
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
        uniformBuffer=gpu.device.makeBuffer(length:28*4,options:.storageModeShared)
        historyBuffer=gpu.device.makeBuffer(length:240*4,options:.storageModeShared)
        masks=[gpu.clear,gpu.clear,gpu.clear]
        if !backgroundOnly {addCaption(size)}
        if !backgroundOnly && !captionOnly {addCounter();addButtons(size)}
        captionProbe=SessionCaptionProbe()
        let input=GradientInputRecognizer(target:self,action:#selector(inputChanged(_:)))
        input.cancelsTouchesInView=false;view.addGestureRecognizer(input)
        metal.delegate=self
        diagnostics=["background":"unchanged v2ComposeBackground via compute adapter","pixelFormat":"bgra8Unorm; rgba16Float intermediates","colorspace":"sRGB","maskImplementation":"CG radial/ellipse -> CoreImage Gaussian -> original exclusion -> normal/multiply/screen","maskPrecision":"8-bit CG source, 16-bit float intermediate","blurRadiusMapping":"same numeric radius * screen scale * breath; equivalence unproven","caption":"Dark backing before masks in Metal compositor; Light native CAGradientLayer, original stops","UI":"UIKit fonts/materials based on visually accepted feasibility prototype"]
    }
    public override func viewDidAppear(_ animated:Bool){
        super.viewDidAppear(animated)
        if !externallyDriven {
            let link=CADisplayLink(target:GradientDisplayTarget(self),selector:#selector(GradientDisplayTarget.tick))
            link.preferredFrameRateRange=CAFrameRateRange(minimum:30,maximum:60,preferred:60)
            link.add(to:.main,forMode:.common);displayLink=link
        }
        tick()
    }
    public override func viewDidDisappear(_ animated:Bool) {super.viewDidDisappear(animated);displayLink?.invalidate();displayLink=nil}
    deinit {displayLink?.invalidate()}
    @objc private func inputChanged(_ input:GradientInputRecognizer) {
        guard !externallyDriven else{return}
        let time=clock()
        inputCallbacks+=1
        if input.state == .changed {moveCallbacks+=1}
        switch input.state {
        case .began,.changed:resetPresentation=nil;session.dragChanged(to:input.point,at:time,size:view.bounds.size)
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
        counterLabel?.setPercentage(0,animated:animated)
    }
    var presentationCounter:CGFloat {resetPresentation?.values(at:f.time).counter ?? f.progress}
    var presentationMask:CGFloat {resetPresentation?.values(at:f.time).mask ?? session.interpolatedProgress(at:f.time)}
    @objc func settingsPressed() { onSettings?() }
    func tick() {
        guard !externallyDriven else{return}
        let frame=session.frame(at:clock(),size:view.bounds.size,dark:dark,yellow:yellow)
        present(frame)
        onFrame?(frame)
    }
    func present(_ frame:GradientRenderFrame, activation:Double?=nil) {
        // One in-flight submission: CPU must not overwrite uniforms/history read by the GPU.
        guard !inFlight else {framesSkipped+=1;return}
        let cpuStart=ProcessInfo.processInfo.systemUptime
        f=frame;uniforms=frame.uniforms;history=frame.history
        if resetPresentation?.values(at:f.time).finished == true {resetPresentation=nil}
        uniforms.withUnsafeBytes {memcpy(uniformBuffer.contents(),$0.baseAddress!,$0.count)}
        if !history.isEmpty {history.withUnsafeBytes {memcpy(historyBuffer.contents(),$0.baseAddress!,$0.count)}}
        let maskStart=ProcessInfo.processInfo.systemUptime
        if f.dark {masks=(0..<3).map {makeMask($0,size:view.bounds.size,scale:UIScreen.main.scale)}}
        else {masks=[gpu.clear,gpu.clear,gpu.clear]}
        maskCPUTime+=(ProcessInfo.processInfo.systemUptime-maskStart)*1000
        if !externallyDriven {captionProbe?.sample(uniforms:uniforms,history:history,frame:caption,key:"\(dark):\(yellow)",dark:dark,yellow:yellow)}
        updateUI(activation:activation ?? captionProbe?.activation ?? 0)
        rendered=false;finished=false;viewMetal.draw()
        cpuFrameTime+=(ProcessInfo.processInfo.systemUptime-cpuStart)*1000;performanceSamples+=1
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
        captionLabel?.textColor=f.dark ? UIColor(red:0.86,green:0.91,blue:0.98,alpha:1):UIColor(white:0.2,alpha:1)
        if let captionLabel,let old=captionLabel.attributedText {
            let text=NSMutableAttributedString(attributedString:old)
            text.addAttribute(.foregroundColor,value:captionLabel.textColor!,range:NSRange(location:0,length:text.length));captionLabel.attributedText=text
        }
        let tint=f.yellow ? UIColor(red:1,green:1,blue:0.3,alpha:1):UIColor.white
        CATransaction.begin();CATransaction.setDisableActions(true)
        captionGradient?.colors=(0...16).map {i in let v=Double(i)/16;return tint.withAlphaComponent(0.3*(1-pow(1-v,3))*activation).cgColor}
        captionGradient?.isHidden=f.dark
        CATransaction.commit()
        for (i,image) in buttonImages.enumerated() {
            image.tintColor=i==1 ? ((uniforms[2]>0.42 || f.dark) ? UIColor.white.withAlphaComponent(0.94):UIColor.gray.withAlphaComponent(0.88)):(f.dark ? UIColor.white.withAlphaComponent(0.78):UIColor.gray)
        }
    }
    public func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize){}
    public func draw(in view:MTKView) {
        guard !rendered,!inFlight,let drawable=view.currentDrawable,let command=gpu.queue.makeCommandBuffer() else{return}
        inFlight=true;framesSubmitted+=1
        let scale=Float(UIScreen.main.scale)
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
        command.addCompletedHandler { [weak self] command in DispatchQueue.main.async {
            self?.finished=command.status == .completed;self?.inFlight=false
            self?.gpuTime+=max(0,command.gpuEndTime-command.gpuStartTime)*1000
            if command.status != .completed {self?.gpuErrors.append(String(describing:command.error))}
        }}
        command.present(drawable);command.commit();rendered=true
    }
    func makeMask(_ index:Int,size:CGSize,scale:CGFloat)->MTLTexture {
        let p=presentationMask,elapsed=f.time-session.startTime
        let flow=0.62+p*0.30,breath=1+CGFloat(sin(elapsed*1.18+Double(p*5)))*0.025
        let dx=CGFloat(sin(elapsed*0.34+0.7))*10,dy=CGFloat(cos(elapsed*0.27+1.3))*5
        let w:[CGFloat]=[252+p*20,204+p*14,226+p*18],h:[CGFloat]=[118+p*8,92+p*6,78+p*5]
        let sx:[CGFloat]=[1.04+CGFloat(sin(elapsed*0.22))*0.055,0.98+CGFloat(cos(elapsed*0.25+2.2))*0.05,1.06+CGFloat(cos(elapsed*0.18+0.4))*0.06]
        let sy:[CGFloat]=[0.94+CGFloat(cos(elapsed*0.19+0.8))*0.045,1.02+CGFloat(sin(elapsed*0.21+1.8))*0.05,0.82+CGFloat(sin(elapsed*0.24+2.7))*0.04]
        let ox:[CGFloat]=[dx,-dx*0.62,dx*0.34],oy:[CGFloat]=[dy,dy*0.48,-4+dy*0.34]
        let tint=f.yellow ? UIColor(red:0.105,green:0.060,blue:0.008,alpha:1):UIColor(red:0.008,green:0.036,blue:0.115,alpha:1)
        let cs=CGColorSpace(name:CGColorSpace.sRGB)!
        let ctx=CGContext(data:nil,width:Int(size.width*scale),height:Int(size.height*scale),bitsPerComponent:8,bytesPerRow:0,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x:0,y:size.height*scale);ctx.scaleBy(x:scale,y:-scale)
        ctx.translateBy(x:counter.midX,y:counter.midY-18);ctx.scaleBy(x:breath,y:breath)
        ctx.translateBy(x:ox[index],y:oy[index]);ctx.scaleBy(x:sx[index],y:sy[index])
        let ellipse=CGRect(x:-w[index]/2,y:-h[index]/2,width:w[index],height:h[index])
        ctx.addEllipse(in:ellipse);ctx.clip()
        if index==2 {ctx.setFillColor(tint.withAlphaComponent(0.22).cgColor);ctx.fill(ellipse)}
        else {
            let colors:[CGColor] = index==0 ? [UIColor.black.withAlphaComponent(0.86).cgColor,UIColor.black.withAlphaComponent(0.72+flow*0.10).cgColor,tint.withAlphaComponent(0.34+p*0.12).cgColor,UIColor.clear.cgColor]:[tint.withAlphaComponent(0.46).cgColor,UIColor.black.withAlphaComponent(0.46).cgColor,UIColor.clear.cgColor]
            let gradient=CGGradient(colorsSpace:cs,colors:colors as CFArray,locations:nil)!
            ctx.drawRadialGradient(gradient,startCenter:.zero,startRadius:index==0 ? 12:2,endCenter:.zero,endRadius:index==0 ? 136:106,options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
        }
        let ci=CIImage(cgImage:ctx.makeImage()!)
        let radius:CGFloat=[38,30,42][index]
        let blurred=ci.applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius*scale*breath]).cropped(to:ci.extent)
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:Int(size.width*scale),height:Int(size.height*scale),mipmapped:false)
        desc.usage=[.shaderRead,.shaderWrite,.renderTarget];desc.storageMode = .private
        let texture=gpu.device.makeTexture(descriptor:desc)!
        let command=gpu.queue.makeCommandBuffer()!
        // CGContext/CI use a bottom-origin image; Metal's sampled row zero is top.
        // check_mask_coordinates.swift verifies 200 -> 644 before this flip.
        let oriented=blurred.transformed(by:CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:ci.extent.height))
        gpu.ci.render(oriented,to:texture,commandBuffer:command,bounds:ci.extent,colorSpace:cs)
        command.commit()
        return texture
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
        box.layer.addSublayer(gradient);box.isUserInteractionEnabled=false;view.addSubview(box);captionGradient=gradient;gradient.isHidden=f.dark
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
            blur.contentView.addSubview(image);view.addSubview(blur);buttonImages.append(image)
            let button=UIButton(frame:blur.frame);button.accessibilityLabel=gear ? "Настройки":"Сбросить"
            button.addTarget(self,action:gear ? #selector(settingsPressed):#selector(resetPressed),for:.touchUpInside)
            view.addSubview(button)
        }
    }
}
final class GradientGPU {
    let device:MTLDevice,queue:MTLCommandQueue,ci:CIContext
    let background:MTLComputePipelineState
    let distortion:MTLRenderPipelineState,composite:MTLRenderPipelineState
    let clear:MTLTexture
    init() throws {
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else{throw NSError(domain:"Migration.MetalUnavailable",code:1)}
        self.device=device;self.queue=queue
        ci=CIContext(mtlDevice:device,options:[.workingColorSpace:NSNull(),.outputColorSpace:NSNull()])
        let url=Bundle.main.url(forResource:"PrototypeShader",withExtension:"txt")!
        let source=try String(contentsOf:url).replacingOccurrences(of:"[[ stitchable ]]",with:"")
        let options=MTLCompileOptions();options.fastMathEnabled=true
        let library=try device.makeLibrary(source:source,options:options)
        func pipeline(_ name:String,_ format:MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d=MTLRenderPipelineDescriptor();d.vertexFunction=library.makeFunction(name:"prototypeVertex");d.fragmentFunction=library.makeFunction(name:name)
            d.colorAttachments[0].pixelFormat=format
            return try device.makeRenderPipelineState(descriptor:d)
        }
        background=try device.makeComputePipelineState(function:library.makeFunction(name:"prototypeComputeBackground")!)
        distortion=try pipeline("prototypeDistortion",.rgba16Float)
        composite=try pipeline("prototypeComposite",.bgra8Unorm)
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:1,height:1,mipmapped:false)
        d.usage = .shaderRead;d.storageMode = .shared
        clear=device.makeTexture(descriptor:d)!
        var zero:UInt32=0;clear.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&zero,bytesPerRow:4)
    }
}

private final class GradientDisplayTarget:NSObject {
    weak var owner:GradientViewController?
    init(_ owner:GradientViewController){self.owner=owner}
    @objc func tick(){owner?.tick()}
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
