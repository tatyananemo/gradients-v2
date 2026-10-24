import Foundation
import CoreGraphics
import CoreImage
import Metal

/// Each worker owns its bitmap and CIContext. The three mathematically independent
/// masks can prepare in parallel without sharing mutable CGContext/CI state.
final class GradientMaskRenderer {
    private let workers:[Surface]
    init(device:MTLDevice,queue:MTLCommandQueue,cacheIntermediates:Bool=false) {
        workers=(0..<3).map {_ in Surface(device:device,queue:queue,cacheIntermediates:cacheIntermediates)}
    }
    func render(progress:CGFloat,elapsed:Double,yellow:Bool,counter:CGRect,size:CGSize,scale:CGFloat,metrics:GradientPerformanceMetrics?=nil,frame:Int=0)->[MTLTexture] {
        DispatchQueue.concurrentPerform(iterations:3) { index in
            _=self.workers[index].render(index,progress:progress,elapsed:elapsed,yellow:yellow,counter:counter,size:size,scale:scale,metrics:metrics,frame:frame)
        }
        return workers.map {$0.output!}
    }
    private final class Surface {
        let device:MTLDevice,queue:MTLCommandQueue,ci:CIContext
        var context:CGContext?
        var output:MTLTexture?
        init(device:MTLDevice,queue:MTLCommandQueue,cacheIntermediates:Bool) {
            self.device=device;self.queue=queue
            // Every frame changes the source, transform and blur radius. Retaining
            // rendered intermediates adds IOSurface cache/XPC work without reuse.
            // The override exists only for exact before/after validation.
            ci=CIContext(mtlDevice:device,options:[.workingColorSpace:NSNull(),.outputColorSpace:NSNull(),.cacheIntermediates:cacheIntermediates])
        }
    func render(_ index:Int,progress p:CGFloat,elapsed:Double,yellow:Bool,counter:CGRect,size:CGSize,scale:CGFloat,metrics:GradientPerformanceMetrics?,frame:Int)->MTLTexture {
        let start=ProcessInfo.processInfo.systemUptime
        let flow=0.62+p*0.30,breath=1+CGFloat(sin(elapsed*1.18+Double(p*5)))*0.025
        let dx=CGFloat(sin(elapsed*0.34+0.7))*10,dy=CGFloat(cos(elapsed*0.27+1.3))*5
        let w:[CGFloat]=[252+p*20,204+p*14,226+p*18],h:[CGFloat]=[118+p*8,92+p*6,78+p*5]
        let sx:[CGFloat]=[1.04+CGFloat(sin(elapsed*0.22))*0.055,0.98+CGFloat(cos(elapsed*0.25+2.2))*0.05,1.06+CGFloat(cos(elapsed*0.18+0.4))*0.06]
        let sy:[CGFloat]=[0.94+CGFloat(cos(elapsed*0.19+0.8))*0.045,1.02+CGFloat(sin(elapsed*0.21+1.8))*0.05,0.82+CGFloat(sin(elapsed*0.24+2.7))*0.04]
        let ox:[CGFloat]=[dx,-dx*0.62,dx*0.34],oy:[CGFloat]=[dy,dy*0.48,-4+dy*0.34]
        let tint:[CGFloat]=yellow ? [0.105,0.060,0.008]:[0.008,0.036,0.115]
        let cs=CGColorSpace(name:CGColorSpace.sRGB)!
        func color(_ rgb:[CGFloat],_ alpha:CGFloat)->CGColor {CGColor(colorSpace:cs,components:rgb+[alpha])!}
        let black:[CGFloat]=[0,0,0]
        let fullWidth=Int(size.width*scale),fullHeight=Int(size.height*scale)
        // The clipped ellipse is identically transparent outside this slice.
        // Keep integer pixel origins and the original transform/CG rasterization.
        let rows=min(fullHeight,Int(ceil(180*scale)))
        let center=(counter.midY-18+oy[index]*breath)*scale
        let top=min(max(Int(floor(center-CGFloat(rows)/2)),0),fullHeight-rows)
        let bottom=top+rows
        let ctx:CGContext
        if let cached=context,cached.width==fullWidth,cached.height==rows {ctx=cached}
        else {
            ctx=CGContext(data:nil,width:fullWidth,height:rows,bitsPerComponent:8,bytesPerRow:0,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context=ctx
        }
        ctx.clear(CGRect(x:0,y:0,width:fullWidth,height:rows));ctx.saveGState()
        ctx.translateBy(x:0,y:CGFloat(bottom));ctx.scaleBy(x:scale,y:-scale)
        ctx.translateBy(x:counter.midX,y:counter.midY-18);ctx.scaleBy(x:breath,y:breath)
        ctx.translateBy(x:ox[index],y:oy[index]);ctx.scaleBy(x:sx[index],y:sy[index])
        let ellipse=CGRect(x:-w[index]/2,y:-h[index]/2,width:w[index],height:h[index])
        ctx.addEllipse(in:ellipse);ctx.clip()
        if index==2 {ctx.setFillColor(color(tint,0.22));ctx.fill(ellipse)}
        else {
            let colors:[CGColor] = index==0 ? [color(black,0.86),color(black,0.72+flow*0.10),color(tint,0.34+p*0.12),color(black,0)]:[color(tint,0.46),color(black,0.46),color(black,0)]
            let gradient=CGGradient(colorsSpace:cs,colors:colors as CFArray,locations:nil)!
            ctx.drawRadialGradient(gradient,startCenter:.zero,startRadius:index==0 ? 12:2,endCenter:.zero,endRadius:index==0 ? 136:106,options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
        }
        ctx.restoreGState()
        let rasterEnd=ProcessInfo.processInfo.systemUptime
        metrics?.add("maskRasterCPU\(index)MS",(rasterEnd-start)*1000)
        let fullExtent=CGRect(x:0,y:0,width:fullWidth,height:fullHeight)
        let ci=CIImage(cgImage:ctx.makeImage()!).transformed(by:CGAffineTransform(translationX:0,y:CGFloat(fullHeight-bottom)))
            .composited(over:CIImage(color:.clear).cropped(to:fullExtent))
        let radius:CGFloat=[38,30,42][index]
        let blurred=ci.applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius*scale*breath]).cropped(to:fullExtent)
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:Int(size.width*scale),height:Int(size.height*scale),mipmapped:false)
        desc.usage=[.shaderRead,.shaderWrite,.renderTarget];desc.storageMode = .private
        let texture:MTLTexture
        if let cached=output,cached.width==fullWidth,cached.height==fullHeight {texture=cached}
        else {texture=device.makeTexture(descriptor:desc)!;output=texture}
        let command=queue.makeCommandBuffer()!
        // CGContext/CI use a bottom-origin image; Metal's sampled row zero is top.
        // check_mask_coordinates.swift verifies 200 -> 644 before this flip.
        let oriented=blurred.transformed(by:CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:fullExtent.height))
        let encodeStart=ProcessInfo.processInfo.systemUptime
        metrics?.add("maskGraphCPU\(index)MS",(encodeStart-rasterEnd)*1000)
        self.ci.render(oriented,to:texture,commandBuffer:command,bounds:fullExtent,colorSpace:cs)
        metrics?.add("maskEncodeCPU\(index)MS",(ProcessInfo.processInfo.systemUptime-encodeStart)*1000)
        if let metrics {command.addCompletedHandler {c in metrics.gpu(frame:frame,expected:4,kind:"maskGPU\(index)MS",start:c.gpuStartTime,end:c.gpuEndTime)}}
        command.commit()
        return texture
    }
    }
}
