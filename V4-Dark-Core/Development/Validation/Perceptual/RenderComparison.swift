// Offline native-macOS comparison. Not part of SDK or an iOS application.
import Foundation
import Metal
import CoreGraphics

struct Frame:Decodable {
    let name:String,group:String,uniforms:[Float],history:[Float]
    let scale:Int,distortion:Float
}
let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let cases=try JSONDecoder().decode([Frame].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])))
let out=URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true)
let benchmarking=CommandLine.arguments.count>4 && CommandLine.arguments[4]=="benchmark"
try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {fatalError("Metal unavailable")}
let options=MTLCompileOptions();options.fastMathEnabled=true
func library(_ name:String)throws->MTLLibrary {try device.makeLibrary(source:String(contentsOf:root.appendingPathComponent(name),encoding:.utf8),options:options)}
let base=try library("candidate936.metal"),candidate=try library("precalculated.metal")
let constants=MTLFunctionConstantValues();var mode:UInt32=3
constants.setConstantValue(&mode,type:.uint,index:101)
let background=[try device.makeComputePipelineState(function:base.makeFunction(name:"prototypeComputeBackground")!),try device.makeComputePipelineState(function:candidate.makeFunction(name:"prototypeComputeBackground",constantValues:constants))]
let prep=try device.makeComputePipelineState(function:candidate.makeFunction(name:"prototypePrepareAxes",constantValues:constants))
let fallbackConstants=MTLFunctionConstantValues();var fallbackMode:UInt32=0
fallbackConstants.setConstantValue(&fallbackMode,type:.uint,index:101)
func pipeline(_ lib:MTLLibrary,_ name:String,_ format:MTLPixelFormat,_ fallback:Bool=false)throws->MTLRenderPipelineState {
 let d=MTLRenderPipelineDescriptor();d.vertexFunction=lib.makeFunction(name:"prototypeVertex")
 d.fragmentFunction = fallback ? try lib.makeFunction(name:name,constantValues:fallbackConstants):lib.makeFunction(name:name)
 d.colorAttachments[0].pixelFormat=format
 return try device.makeRenderPipelineState(descriptor:d)
}
let distortion=[try pipeline(base,"prototypeDistortion",.rgba16Float),try pipeline(candidate,"prototypeDistortion",.rgba16Float)]
let composite8=[try pipeline(base,"prototypeComposite",.bgra8Unorm),try pipeline(candidate,"prototypeComposite",.bgra8Unorm,true)]
let composite16=[try pipeline(base,"prototypeComposite",.rgba16Float),try pipeline(candidate,"prototypeComposite",.rgba16Float,true)]
let maskRenderer=GradientMaskRenderer(device:device,queue:queue)
let clearDesc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:1,height:1,mipmapped:false);clearDesc.usage=[.shaderRead];clearDesc.storageMode = .shared
let clear=device.makeTexture(descriptor:clearDesc)!;var zero:UInt32=0
clear.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&zero,bytesPerRow:4)
func texture(_ width:Int,_ height:Int,_ format:MTLPixelFormat,_ storage:MTLStorageMode)->MTLTexture {
 let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:width,height:height,mipmapped:false)
 d.storageMode=storage;d.usage=[.shaderRead,.shaderWrite,.renderTarget]
 guard let t=device.makeTexture(descriptor:d) else {fatalError("texture allocation")};return t
}
func completed(_ cb:MTLCommandBuffer) {
 cb.commit();cb.waitUntilCompleted()
 guard cb.status == .completed else {fatalError("GPU command failed: \(String(describing:cb.error))")}
}
func draw(_ cb:MTLCommandBuffer,_ target:MTLTexture,_ state:MTLRenderPipelineState,_ bind:(MTLRenderCommandEncoder)->Void) {
 let d=MTLRenderPassDescriptor();d.colorAttachments[0].texture=target;d.colorAttachments[0].loadAction = .dontCare;d.colorAttachments[0].storeAction = .store
 guard let e=cb.makeRenderCommandEncoder(descriptor:d) else {fatalError("render encoder")}
 e.setRenderPipelineState(state);bind(e);e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);e.endEncoding()
}
struct Targets {let back:MTLTexture,distorted:MTLTexture,output:MTLTexture,floatOutput:MTLTexture,read8:MTLTexture,read16:MTLTexture,cache:MTLBuffer}
var targets:[Int:Targets]=[:]
func forScale(_ s:Int)->Targets {
 if let t=targets[s] {return t}
 let w=390*s,h=844*s
 let count=286+10*w+8*h
 let t=Targets(back:texture(w,h,.rgba16Float,.private),distorted:texture(w,h,.rgba16Float,.private),output:texture(w,h,.bgra8Unorm,.private),floatOutput:texture(w,h,.rgba16Float,.private),read8:texture(w,h,.bgra8Unorm,.shared),read16:texture(w,h,.rgba16Float,.shared),cache:device.makeBuffer(length:count*4,options:.storageModePrivate)!)
 targets[s]=t;return t
}
func save(_ t:MTLTexture,_ file:URL,_ bytesPerPixel:Int)throws {
 var data=Data(count:t.width*t.height*bytesPerPixel)
 data.withUnsafeMutableBytes {t.getBytes($0.baseAddress!,bytesPerRow:t.width*bytesPerPixel,from:MTLRegionMake2D(0,0,t.width,t.height),mipmapLevel:0)}
 try data.write(to:file)
}
var timings:[[String:Any]]=[]
for (index,frame) in cases.enumerated() {
 precondition(frame.uniforms.count==28 && Int(frame.uniforms[27])==frame.history.count && frame.history.count<=240)
 let t=forScale(frame.scale),w=t.back.width,h=t.back.height,scale=Float(frame.scale)
 let u=device.makeBuffer(bytes:frame.uniforms,length:frame.uniforms.count*4,options:.storageModeShared)!
 let hist=frame.history.isEmpty ? [Float(0)]:frame.history
 let history=device.makeBuffer(bytes:hist,length:hist.count*4,options:.storageModeShared)!
 let dark=frame.uniforms[23]>0.5
 let counter=CGRect(x:0,y:356,width:390,height:76.6666666666667)
 let sharedMasks = !benchmarking && dark ? maskRenderer.render(progress:CGFloat(frame.uniforms[2]),elapsed:Double(frame.uniforms[10]),yellow:true,counter:counter,size:CGSize(width:390,height:844),scale:CGFloat(frame.scale)):[clear,clear,clear]
 for offset in 0..<2 {
  let variant=benchmarking ? (offset+index)%2:offset
  let metrics=benchmarking && dark ? GradientPerformanceMetrics():nil
  let masks=metrics == nil ? sharedMasks:maskRenderer.render(progress:CGFloat(frame.uniforms[2]),elapsed:Double(frame.uniforms[10]),yellow:true,counter:counter,size:CGSize(width:390,height:844),scale:CGFloat(frame.scale),metrics:metrics,frame:index)
  guard masks.count==3 else {fatalError("mask rendering failed")}
  let cb=queue.makeCommandBuffer()!
  if variant==1 {
   let e=cb.makeComputeCommandEncoder()!;var extent=SIMD4<UInt32>(UInt32(w),UInt32(h),scale.bitPattern,UInt32(frame.history.count))
   e.setComputePipelineState(prep);e.setBuffer(u,offset:0,index:0);e.setBuffer(history,offset:0,index:1);e.setBuffer(t.cache,offset:0,index:2);e.setBytes(&extent,length:16,index:3)
   let n=max(w,h,frame.history.count);e.dispatchThreadgroups(MTLSize(width:(n+63)/64,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:64,height:1,depth:1));e.endEncoding()
  }
  let e=cb.makeComputeCommandEncoder()!;var factor=scale
  e.setComputePipelineState(background[variant]);e.setTexture(t.back,index:0);e.setBuffer(u,offset:0,index:0);e.setBuffer(variant==1 ? t.cache:history,offset:0,index:1);e.setBytes(&factor,length:4,index:2)
  e.dispatchThreadgroups(MTLSize(width:(w+7)/8,height:(h+7)/8,depth:1),threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1));e.endEncoding()
  let input:MTLTexture
  if frame.distortion>0.002 {
   draw(cb,t.distorted,distortion[variant]) {enc in var p=SIMD4<Float>(frame.uniforms[0],frame.uniforms[1],frame.distortion,scale);enc.setFragmentTexture(t.back,index:0);enc.setFragmentBuffer(u,offset:0,index:0);enc.setFragmentBytes(&p,length:16,index:1)}
   input=t.distorted
  } else {input=t.back}
  func bind(_ enc:MTLRenderCommandEncoder) {
   var p=SIMD4<Float>(scale,1,dark ? 1:0,0);enc.setFragmentTexture(input,index:0)
   for i in 0..<3 {enc.setFragmentTexture(masks[i],index:i+1)}
   enc.setFragmentBuffer(u,offset:0,index:0);enc.setFragmentBytes(&p,length:16,index:1)
  }
  draw(cb,t.output,composite8[variant],bind);completed(cb)
  let ms=(cb.gpuEndTime-cb.gpuStartTime)*1000
  if benchmarking {
   // CB time contains prep (candidate), background, optional distortion and
   // compositor. Dark mask timings are separately reported from SDK callbacks.
   var sample:[String:Any] = ["name":frame.name,"theme":dark ? "dark":"light","scale":frame.scale,"variant":variant==0 ? "reference":"precalc","gpuMS":ms]
   if let metrics {
    for _ in 0..<100 {
     let report=metrics.report()
     if (0..<3).allSatisfy({(report["maskGPU\($0)MS"] as? [String:Double])?["count"]==1}) {
      sample["maskGPUms"]=(0..<3).reduce(0.0) {$0+((report["maskGPU\($1)MS"] as! [String:Double])["mean"]!)}
      break
     }
     Thread.sleep(forTimeInterval:0.001)
    }
   }
   timings.append(sample)
   continue
  }
  if frame.group != "sequence" {timings.append(["name":frame.name,"theme":dark ? "dark":"light","scale":frame.scale,"variant":variant==0 ? "reference":"precalc","gpuMS":ms])}
  let read=queue.makeCommandBuffer()!
  draw(read,t.floatOutput,composite16[variant],bind)
  let blit=read.makeBlitCommandEncoder()!
  for (from,to) in [(t.output,t.read8),(t.floatOutput,t.read16)] {
   blit.copy(from:from,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:MTLSize(width:w,height:h,depth:1),to:to,destinationSlice:0,destinationLevel:0,destinationOrigin:MTLOrigin(x:0,y:0,z:0))
  }
  blit.endEncoding();completed(read)
  let name=frame.name+(variant==0 ? "-before":"-after")
  try save(t.read8,out.appendingPathComponent(name+".bgra8"),4)
  if frame.group != "sequence" {try save(t.read16,out.appendingPathComponent(name+".rgba16f"),8)}
 }
 if index%20==0 {print("Rendered \(index+1)/\(cases.count): \(frame.name)");fflush(stdout)}
}
try JSONSerialization.data(withJSONObject:timings,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("timings.json"))
print("Rendered \(cases.count) paired frames using \(device.name)")
