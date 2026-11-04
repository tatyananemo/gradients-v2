// Offline native-macOS comparison. Not part of SDK or an iOS application.
import Foundation
import Metal
import CoreGraphics
import Darwin

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
let base=try library("candidate936.metal"),candidate=try library("precalculated.metal"),idle=try library("idle-cache.metal")
let constants=MTLFunctionConstantValues();var mode:UInt32=3
constants.setConstantValue(&mode,type:.uint,index:101)
let background=[try device.makeComputePipelineState(function:base.makeFunction(name:"prototypeComputeBackground")!),try device.makeComputePipelineState(function:candidate.makeFunction(name:"prototypeComputeBackground",constantValues:constants))]
let prep=try device.makeComputePipelineState(function:candidate.makeFunction(name:"prototypePrepareAxes",constantValues:constants))
let idleBackground=try device.makeComputePipelineState(function:idle.makeFunction(name:"prototypeComputeBackground",constantValues:constants))
let idlePrep=try device.makeComputePipelineState(function:idle.makeFunction(name:"prototypePrepareAxes",constantValues:constants))
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
let localRenderer=LocalMaskRenderer(device:device,queue:queue)
let domainRenderer=DomainMaskRenderer(device:device,queue:queue)
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
 let count=286+10*w+8*h+2+5*w+h
 let t=Targets(back:texture(w,h,.rgba16Float,.private),distorted:texture(w,h,.rgba16Float,.private),output:texture(w,h,.bgra8Unorm,.private),floatOutput:texture(w,h,.rgba16Float,.private),read8:texture(w,h,.bgra8Unorm,.shared),read16:texture(w,h,.rgba16Float,.shared),cache:device.makeBuffer(length:count*4,options:.storageModePrivate)!)
 targets[s]=t;return t
}
func save(_ t:MTLTexture,_ file:URL,_ bytesPerPixel:Int)throws {
 var data=Data(count:t.width*t.height*bytesPerPixel)
 data.withUnsafeMutableBytes {t.getBytes($0.baseAddress!,bytesPerRow:t.width*bytesPerPixel,from:MTLRegionMake2D(0,0,t.width,t.height),mipmapLevel:0)}
 try data.write(to:file)
}
func cpuSeconds()->Double {
 var usage=rusage();getrusage(RUSAGE_SELF,&usage)
 return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6
}
func readBytes(_ t:MTLTexture)->[UInt8] {
 var data=[UInt8](repeating:0,count:t.width*t.height*4)
 t.getBytes(&data,bytesPerRow:t.width*4,from:MTLRegionMake2D(0,0,t.width,t.height),mipmapLevel:0)
 return data
}
func difference(_ a:[UInt8],_ b:[UInt8])->[String:Any] {
 var pixels=0,components=0,maxD=0,sum:UInt64=0
 for i in stride(from:0,to:a.count,by:4) {
  var any=false
  for c in 0..<4 {let delta=abs(Int(a[i+c])-Int(b[i+c]));if delta>0 {any=true;components+=1};maxD=max(maxD,delta);sum+=UInt64(delta)}
  if any {pixels+=1}
 }
 return ["pixels":pixels,"components":components,"maxDelta8":maxD,"sumDelta8":sum,"totalPixels":a.count/4]
}
var timings:[[String:Any]]=[]
var comparisons:[[String:Any]]=[]
var previousErrors:[String:[Int16]]=[:]
var temporal:[[String:Any]]=[]
for (index,frame) in cases.enumerated() {
 precondition(frame.uniforms.count==28 && Int(frame.uniforms[27])==frame.history.count && frame.history.count<=240)
 let t=forScale(frame.scale),w=t.back.width,h=t.back.height,scale=Float(frame.scale)
 let u=device.makeBuffer(bytes:frame.uniforms,length:frame.uniforms.count*4,options:.storageModeShared)!
 let hist=frame.history.isEmpty ? [Float(0)]:frame.history
 let history=device.makeBuffer(bytes:hist,length:hist.count*4,options:.storageModeShared)!
 let dark=frame.uniforms[23]>0.5
 let counter=CGRect(x:0,y:356,width:390,height:76.6666666666667)
 var referencePixels:[[UInt8]]=[]
 let selected=CommandLine.arguments.contains("domain-only") ? [0,1,4]:[0,1,2,3,4]
 for offset in selected.indices {
  let testVariant=selected[benchmarking ? (offset+index)%selected.count:offset]
  let variant=testVariant==0 ? 0:1
  let cpuStart=cpuSeconds(),wallStart=ProcessInfo.processInfo.systemUptime
  let metrics=dark ? GradientPerformanceMetrics():nil
  let maskStart=ProcessInfo.processInfo.systemUptime
  let masks:[MTLTexture]
  if !dark {masks=[clear,clear,clear]}
  else if testVariant==4 {masks=domainRenderer.render(progress:CGFloat(frame.uniforms[2]),elapsed:Double(frame.uniforms[10]),yellow:true,counter:counter,size:CGSize(width:390,height:844),scale:CGFloat(frame.scale),metrics:metrics,frame:index)}
  else if testVariant==2 {masks=localRenderer.render(progress:CGFloat(frame.uniforms[2]),elapsed:Double(frame.uniforms[10]),yellow:true,counter:counter,size:CGSize(width:390,height:844),scale:CGFloat(frame.scale),metrics:metrics,frame:index)}
  else {masks=maskRenderer.render(progress:CGFloat(frame.uniforms[2]),elapsed:Double(frame.uniforms[10]),yellow:true,counter:counter,size:CGSize(width:390,height:844),scale:CGFloat(frame.scale),metrics:metrics,frame:index)}
  let maskWall=(ProcessInfo.processInfo.systemUptime-maskStart)*1000
  guard masks.count==3 else {fatalError("mask rendering failed")}
  let cb=queue.makeCommandBuffer()!
  if variant==1 {
   let e=cb.makeComputeCommandEncoder()!;var extent=SIMD4<UInt32>(UInt32(w),UInt32(h),scale.bitPattern,UInt32(frame.history.count))
   e.setComputePipelineState(testVariant==3 ? idlePrep:prep);e.setBuffer(u,offset:0,index:0);e.setBuffer(history,offset:0,index:1);e.setBuffer(t.cache,offset:0,index:2);e.setBytes(&extent,length:16,index:3)
   let n=max(w,h,frame.history.count);e.dispatchThreadgroups(MTLSize(width:(n+63)/64,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:64,height:1,depth:1));e.endEncoding()
  }
  let e=cb.makeComputeCommandEncoder()!;var factor=scale
  e.setComputePipelineState(testVariant==3 ? idleBackground:background[variant]);e.setTexture(t.back,index:0);e.setBuffer(u,offset:0,index:0);e.setBuffer(variant==1 ? t.cache:history,offset:0,index:1);e.setBytes(&factor,length:4,index:2)
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
  let totalWall=(ProcessInfo.processInfo.systemUptime-wallStart)*1000,totalCPU=(cpuSeconds()-cpuStart)*1000
  let ms=(cb.gpuEndTime-cb.gpuStartTime)*1000
  let variantName=["reference","precalc","localMask","idleCache","maskDomain"][testVariant]
  if benchmarking {
   // CB time contains prep (candidate), background, optional distortion and
   // compositor. Dark mask timings are separately reported from SDK callbacks.
   var sample:[String:Any] = ["name":frame.name,"theme":dark ? "dark":"light","scale":frame.scale,"variant":variantName,"gpuMS":ms,"fullFrameWallMS":totalWall,"fullFrameCPUms":totalCPU,"maskWallMS":maskWall]
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
  let read=queue.makeCommandBuffer()!,blit=read.makeBlitCommandEncoder()!
  blit.copy(from:t.output,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:MTLSize(width:w,height:h,depth:1),to:t.read8,destinationSlice:0,destinationLevel:0,destinationOrigin:MTLOrigin(x:0,y:0,z:0))
  blit.endEncoding();completed(read)
  let data=readBytes(t.read8)
  if testVariant<2 {referencePixels.append(data)}
  else {
   if frame.group=="sequence" {
    let error=data.indices.map {Int16(data[$0])-Int16(referencePixels[0][$0])}
    if let previous=previousErrors[frame.uniforms[23]>0.5 ? "dark":"light"] {
     var maximum=0,changed=0
     for i in error.indices {let d=abs(Int(error[i])-Int(previous[i]));maximum=max(maximum,d);if d>0 {changed+=1}}
     temporal.append(["name":frame.name,"maxSignedErrorChange8":maximum,"changedComponents":changed])
    }
    previousErrors[frame.uniforms[23]>0.5 ? "dark":"light"]=error
   }
   if ["extra-dark-dynamic7","extra-dark-p2-t3","seq-dark-113"].contains(frame.name) {
    for (label,bytes) in [("reference",referencePixels[0]),("precalc",referencePixels[1]),("domain",data)] {
     try Data(bytes).write(to:out.appendingPathComponent(frame.name+"-"+label+".bgra8"))
    }
   }
   comparisons.append(["name":frame.name,"group":frame.group,"variant":variantName,"theme":dark ? "dark":"light","vsApproved":difference(referencePixels[0],data),"vsPrecalc":difference(referencePixels[1],data)])
  }
 }
 if index%20==0 {print("Rendered \(index+1)/\(cases.count): \(frame.name)");fflush(stdout)}
}
try JSONSerialization.data(withJSONObject:timings,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("timings.json"))
try JSONSerialization.data(withJSONObject:comparisons,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("comparisons.json"))
try JSONSerialization.data(withJSONObject:temporal,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("temporal.json"))
print("Rendered \(cases.count) variant sets using \(device.name)")
