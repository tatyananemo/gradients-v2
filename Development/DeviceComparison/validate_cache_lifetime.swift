// Native Mac-only GPU check for real helper reuse, three in-flight slots and resize.
import Foundation
import Metal
import CryptoKit
let source=try String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8)
let device=MTLCreateSystemDefaultDevice()!,queue=device.makeCommandQueue()!
let options=MTLCompileOptions();options.fastMathEnabled=true
let lib=try device.makeLibrary(source:source,options:options)
let constants=MTLFunctionConstantValues();var mode:UInt32=3;constants.setConstantValue(&mode,type:.uint,index:101)
let prep=try device.makeComputePipelineState(function:lib.makeFunction(name:"prototypePrepareAxes",constantValues:constants))
let background=try device.makeComputePipelineState(function:lib.makeFunction(name:"prototypeComputeBackground",constantValues:constants))
struct Pending {let command:MTLCommandBuffer,texture:MTLTexture}
func submit(_ cache:GradientPrecalculationBuffers,_ slot:Int,_ time:Float,_ dark:Bool,_ historyCount:Int)->Pending {
 var uniforms:[Float]=[Float(cache.width),Float(cache.height),0.63,0,0.72,0.62,0.32,0.68,0,0,time,0.15,1,1,1,1,1,1,0,0.62,1,0.74,2,dark ? 1:0,3,1,time,Float(historyCount)]
 var history=[Float](repeating:0,count:240)
 for i in stride(from:0,to:historyCount,by:6) {history[i]=0.15;history[i+1]=0.75;history[i+2]=0.72;history[i+3]=0.62;history[i+4]=0.05;history[i+5]=0.9}
 let u=device.makeBuffer(bytes:&uniforms,length:112,options:.storageModeShared)!,h=device.makeBuffer(bytes:&history,length:960,options:.storageModeShared)!
 let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:cache.width,height:cache.height,mipmapped:false)
 desc.usage=[.shaderRead,.shaderWrite];desc.storageMode = .shared
 let t=device.makeTexture(descriptor:desc)!,cb=queue.makeCommandBuffer()!
 precondition(cb.retainedReferences)
 let buffer=cache.encode(command:cb,pipeline:prep,uniformBuffer:u,historyBuffer:h,historyCount:historyCount,scale:1,slot:slot)!
 let e=cb.makeComputeCommandEncoder()!;var scale:Float=1
 e.setComputePipelineState(background);e.setTexture(t,index:0);e.setBuffer(u,offset:0,index:0);e.setBuffer(buffer,offset:0,index:1);e.setBytes(&scale,length:4,index:2)
 e.dispatchThreadgroups(MTLSize(width:(cache.width+7)/8,height:(cache.height+7)/8,depth:1),threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1));e.endEncoding();cb.commit()
 return Pending(command:cb,texture:t)
}
func digest(_ pending:Pending)->String {
 pending.command.waitUntilCompleted();precondition(pending.command.status == .completed,String(describing:pending.command.error))
 let t=pending.texture;var data=Data(count:t.width*t.height*8)
 data.withUnsafeMutableBytes {t.getBytes($0.baseAddress!,bytesPerRow:t.width*8,from:MTLRegionMake2D(0,0,t.width,t.height),mipmapLevel:0)}
 return SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
}
var comparisons=0
for dark in [true,false] {
 for size in [(390,844),(844,390),(391,845)] {
  var cache:GradientPrecalculationBuffers?=GradientPrecalculationBuffers(device:device,width:size.0,height:size.1)!
  let times:[Float]=[0.4,1.65,2.999];let counts=[0,12,240]
  let expected=(0..<3).map {digest(submit(cache!,$0,times[$0],dark,counts[$0]))}
  let queued=(0..<3).map {submit(cache!,$0,times[$0],dark,counts[$0])}
  // Drop the old owner and allocate replacement while old commands are in flight.
  cache=GradientPrecalculationBuffers(device:device,width:size.1,height:size.0)
  for i in 0..<3 {precondition(digest(queued[i])==expected[i]);comparisons+=1}
  let reuse=cache!
  for i in 0..<3 {
   let first=digest(submit(reuse,i,times[i],dark,0)),second=digest(submit(reuse,i,times[i],dark,0))
   precondition(first==second);comparisons+=1
  }
 }
}
let result:[String:Any]=["device":device.name,"passed":true,"comparisons":comparisons,"themes":2,"sizes":3,"slots":3,"resizeOwnerDroppedWhileInFlight":true]
try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
print("GPU cache lifetime: \(comparisons) exact reuse/in-flight comparisons passed")
