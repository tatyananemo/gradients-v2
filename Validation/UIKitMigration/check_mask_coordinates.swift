// Coordinate-system diagnostic only. No V2 formulas are used or altered.
import Foundation
import CoreGraphics
import CoreImage
import Metal
let w=390,h=844,expected=200.0
let cs=CGColorSpace(name:CGColorSpace.sRGB)!
let ctx=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x:0,y:CGFloat(h));ctx.scaleBy(x:1,y:-1)
ctx.setFillColor(CGColor(gray:0,alpha:1));ctx.fillEllipse(in:CGRect(x:145,y:expected-50,width:100,height:100))
let device=MTLCreateSystemDefaultDevice()!,queue=device.makeCommandQueue()!
let ci=CIContext(mtlDevice:device,options:[.workingColorSpace:NSNull(),.outputColorSpace:NSNull()])
let input=CIImage(cgImage:ctx.makeImage()!).applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:38]).cropped(to:CGRect(x:0,y:0,width:w,height:h))
let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:w,height:h,mipmapped:false);desc.storageMode = .shared;desc.usage=[.shaderRead,.shaderWrite,.renderTarget]
for flip in [false,true] {
 let texture=device.makeTexture(descriptor:desc)!,command=queue.makeCommandBuffer()!
 let image=flip ? input.transformed(by:CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:CGFloat(h))):input
 ci.render(image,to:texture,commandBuffer:command,bounds:input.extent,colorSpace:cs);command.commit();command.waitUntilCompleted()
 var bits=[UInt16](repeating:0,count:w*h*4);texture.getBytes(&bits,bytesPerRow:w*8,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0)
 var weight=0.0,moment=0.0
 for y in 0..<h {for x in 0..<w {let a=Double(Float16(bitPattern:bits[(y*w+x)*4+3]));weight+=a;moment+=a*(Double(y)+0.5)}}
 print("flip=\(flip), target top-origin center=\(expected), texture alpha centroid=\(moment/weight)")
}
