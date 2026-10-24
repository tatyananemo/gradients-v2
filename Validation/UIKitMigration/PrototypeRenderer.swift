// Feasibility prototype only; not linked into the V2 application target.
import UIKit
import MetalKit
import CoreImage
import CoreText

final class PrototypeController:UIViewController,MTKViewDelegate {
    static var context:PrototypeGPU?
    let gpu:PrototypeGPU
    let uniforms:[Float],history:[Float]
    let caption:CGRect,counter:CGRect
    let f:MigrationFrame
    var viewMetal:MTKView!
    var backing:MTLTexture!,distorted:MTLTexture!
    var masks:[MTLTexture]=[]
    var uniformBuffer:MTLBuffer!,historyBuffer:MTLBuffer!
    var diagnostics:[String:Any]=[:]
    var rendered=false
    var finished=false
    var backgroundOnly:Bool {f.request.mode.hasSuffix("-background")}
    var captionOnly:Bool {f.request.mode.hasSuffix("-caption")}
    init(uniforms:[Float],history:[Float],caption:CGRect,counter:CGRect) throws {
        if Self.context == nil {Self.context=try PrototypeGPU()}
        self.gpu=Self.context!;self.uniforms=uniforms;self.history=history
        self.caption=caption;self.counter=counter;self.f=MigrationEnvironment.frame
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder){fatalError("test host only")}
    override var prefersStatusBarHidden:Bool {true}
    override var prefersHomeIndicatorAutoHidden:Bool {true}
    override func viewDidLoad() {
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
        uniformBuffer=gpu.device.makeBuffer(bytes:uniforms,length:uniforms.count*4,options:.storageModeShared)
        let padded=history.isEmpty ? [Float](repeating:0,count:1):history
        historyBuffer=gpu.device.makeBuffer(bytes:padded,length:padded.count*4,options:.storageModeShared)
        masks = f.dark && !backgroundOnly && !captionOnly ? (0..<3).map { makeMask($0,size:size,scale:scale) }:[gpu.clear,gpu.clear,gpu.clear]
        if !backgroundOnly {addCaption(size)}
        if !backgroundOnly && !captionOnly {addCounter();addButtons(size)}
        metal.delegate=self
        diagnostics=["background":"unchanged v2ComposeBackground via compute adapter","pixelFormat":"bgra8Unorm; rgba16Float intermediates","colorspace":"sRGB","maskImplementation":"CG radial/ellipse -> CoreImage Gaussian -> original exclusion -> normal/multiply/screen","maskPrecision":"8-bit CG source, 16-bit float intermediate","blurRadiusMapping":"same numeric radius * screen scale * breath; equivalence unproven","caption":"Dark backing before masks in Metal compositor; Light native CAGradientLayer, original stops","UI":"UIKit font/material approximation; not accepted as equivalent"]
    }
    override func viewDidAppear(_ animated:Bool){super.viewDidAppear(animated);viewMetal.draw()}
    func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize){}
    func draw(in view:MTKView) {
        guard !rendered,let drawable=view.currentDrawable,let command=gpu.queue.makeCommandBuffer() else{return}
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
        let strength=MigrationEnvironment.distortion
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
        command.addCompletedHandler { [weak self] command in DispatchQueue.main.async {self?.finished=command.status == .completed} }
        command.present(drawable);command.commit();rendered=true
    }
    func makeMask(_ index:Int,size:CGSize,scale:CGFloat)->MTLTexture {
        let p=f.replay.interpolatedProgress(at:f.time),elapsed=f.time-f.replay.startTime
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
            gradient.colors=(0...16).map {i in let v=Double(i)/16;return tint.withAlphaComponent(0.3*(1-pow(1-v,3))*f.activation).cgColor}
            gradient.locations=(0...16).map {NSNumber(value:Double($0)/16)}
        }
        if !f.dark {box.layer.addSublayer(gradient);box.isUserInteractionEnabled=false;view.addSubview(box)}
        if captionOnly {return}
        let text=UILabel(frame:CGRect(x:34,y:caption.minY,width:size.width-68,height:caption.height))
        text.numberOfLines=0;text.textAlignment = .center
        text.font = .systemFont(ofSize:17,weight:.medium)
        text.textColor=f.dark ? UIColor(red:0.86,green:0.91,blue:0.98,alpha:1):UIColor(white:0.2,alpha:1)
        let style=NSMutableParagraphStyle();style.alignment = .center;style.lineSpacing=1.2
        text.attributedText=NSAttributedString(string:"Устанавливаем защищенное соединение. Водите пальцем в разных частях экрана",attributes:[.font:text.font!,.foregroundColor:text.textColor!,.paragraphStyle:style])
        view.addSubview(text)
    }
    func addCounter() {
        let p=f.replay.progress
        let label=UILabel(frame:counter)
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
        wrap.addSubview(label);view.addSubview(wrap)
    }
    func addButtons(_ size:CGSize) {
        let p=f.replay.interpolatedProgress(at:f.time)
        for (gear,width,x) in [(false,CGFloat(32),CGFloat(24)),(true,CGFloat(34),size.width-24-34)] {
            let blur=UIVisualEffectView(effect:UIBlurEffect(style:.systemUltraThinMaterial))
            // Match the reference: appTheme does not override the root system color scheme.
            blur.frame=CGRect(x:x,y:56+(34-width)/2,width:width,height:width)
            blur.layer.cornerRadius=width/2;blur.clipsToBounds=true
            if gear {blur.layer.borderWidth=1;blur.layer.borderColor=UIColor.white.withAlphaComponent(f.dark ? 0.24:0.38).cgColor}
            let image=UIImageView(image:UIImage(systemName:gear ? "gearshape.fill":"xmark",withConfiguration:UIImage.SymbolConfiguration(pointSize:gear ? 14:13,weight:.semibold)))
            image.contentMode = .center;image.frame=blur.bounds
            image.tintColor=gear ? ((p>0.42 || f.dark) ? UIColor.white.withAlphaComponent(0.94):(f.dark ? UIColor.white.withAlphaComponent(0.92):UIColor.gray.withAlphaComponent(0.88))):(f.dark ? UIColor.white.withAlphaComponent(0.78):UIColor.gray)
            blur.contentView.addSubview(image);view.addSubview(blur)
        }
    }
}
final class PrototypeGPU {
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
