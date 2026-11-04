// Native macOS comparison of the unchanged caption-probe kernel. No UIKit app.
import Foundation
import Metal
struct Frame:Decodable {let name:String,group:String,uniforms:[Float],history:[Float]}
struct CaptionState {var risk=0.0,activation=0.0,needed=false}
let baseURL=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let cases=try JSONDecoder().decode([Frame].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])))
let device=MTLCreateSystemDefaultDevice()!,queue=device.makeCommandQueue()!
let opts=MTLCompileOptions();opts.fastMathEnabled=true
let fallback=MTLFunctionConstantValues();var mode:UInt32=0
fallback.setConstantValue(&mode,type:.uint,index:101)
let pipelines=try ["candidate936.metal","precalculated.metal"].enumerated().map {index,name -> MTLComputePipelineState in
 let lib=try device.makeLibrary(source:String(contentsOf:baseURL.appendingPathComponent(name),encoding:.utf8),options:opts)
 let fn = index == 0 ? lib.makeFunction(name:"v2CaptionProbe")! : try lib.makeFunction(name:"v2CaptionProbe",constantValues:fallback)
 return try device.makeComputePipelineState(function:fn)
}
func ease(_ x:Double,_ a:Double,_ b:Double)->Double {let t=min(max((x-a)/(b-a),0),1);return t*t*(3-2*t)}
func risk(_ x:[SIMD4<Float>],dark:Bool)->Double {
 let l=x.map{Double($0.x)}.sorted(),wave=x.map{Double($0.y)}.sorted(),delta=x.map{Double($0.z)}.sorted()
 let low=l[36],high=l[324],W=wave[324],D=delta[324],sat=x.reduce(0){$0+Double($1.w)}/360
 if dark {return max(ease(W,0.015,0.15),ease(D,0.02,0.12))*ease(high,0.22,0.50)}
 let textLight=pow((0.20+0.055)/1.055,2.4),contrast=(low+0.05)/(textLight+0.05)
 return max(1-ease(contrast,4.8,5.8),ease(high,0.58,0.74)*ease(sat,0.20,0.35))
}
func advance(_ s:inout CaptionState,_ r:Double,dark:Bool) {
 let dt=1.0/60
 s.risk+=(r-s.risk)*(1-exp(-dt/0.025))
 if s.risk>0.42 {s.needed=true} else if s.risk<0.22 {s.needed=false}
 let target=s.needed ? 1.0:0.0,tau=s.needed ? (dark ? 0.065:0.075):(dark ? 0.16:0.25)
 s.activation+=(target-s.activation)*(1-exp(-dt/tau))
 if !s.needed && s.activation<0.001{s.activation=0};if s.needed && s.activation>0.999{s.activation=1}
}
var states=[String:CaptionState](),results:[[String:Any]]=[]
for frame in cases {
 var input=frame.uniforms+[Float(34),Float(698.6666666666667),Float(356),Float(762)]
 let u=device.makeBuffer(bytes:&input,length:input.count*4,options:.storageModeShared)!
 let history=device.makeBuffer(length:512*4,options:.storageModeShared)!
 if !frame.history.isEmpty {frame.history.withUnsafeBytes {memcpy(history.contents(),$0.baseAddress!,$0.count)}}
 input.withUnsafeBytes {memcpy(history.contents().advanced(by:256*4),$0.baseAddress!,$0.count)}
 let outputs=(0..<2).map {_ in device.makeBuffer(length:360*16,options:.storageModeShared)!}
 let cb=queue.makeCommandBuffer()!
 for i in 0..<2 {
  let e=cb.makeComputeCommandEncoder()!;e.setComputePipelineState(pipelines[i]);e.setBuffer(u,offset:0,index:0);e.setBuffer(history,offset:0,index:1);e.setBuffer(outputs[i],offset:0,index:2)
  e.dispatchThreadgroups(MTLSize(width:12,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:32,height:1,depth:1));e.endEncoding()
 }
 cb.commit();cb.waitUntilCompleted();guard cb.status == .completed else {fatalError(String(describing:cb.error))}
 let first=Array(UnsafeBufferPointer(start:outputs[0].contents().assumingMemoryBound(to:SIMD4<Float>.self),count:360))
 let second=Array(UnsafeBufferPointer(start:outputs[1].contents().assumingMemoryBound(to:SIMD4<Float>.self),count:360))
 var changed=0,maxDifference:Float=0
 for (a,b) in zip(first,second) {for j in 0..<4 {if a[j].bitPattern != b[j].bitPattern {changed+=1};maxDifference=max(maxDifference,abs(a[j]-b[j]))}}
 let dark=frame.uniforms[23]>0.5,r0=risk(first,dark:dark),r1=risk(second,dark:dark)
 var entry:[String:Any]=["name":frame.name,"group":frame.group,"theme":dark ? "dark":"light","differentComponents":changed,"maxDifference":maxDifference,"riskBefore":r0,"riskAfter":r1]
 if frame.group=="sequence" {
  let prefix=dark ? "dark":"light",k0=prefix+"0",k1=prefix+"1";var s0=states[k0] ?? CaptionState(),s1=states[k1] ?? CaptionState()
  advance(&s0,r0,dark:dark);advance(&s1,r1,dark:dark);states[k0]=s0;states[k1]=s1
  entry["activationBefore"]=s0.activation;entry["activationAfter"]=s1.activation;entry["neededBefore"]=s0.needed;entry["neededAfter"]=s1.needed
 }
 results.append(entry)
}
try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[3]))
print("Compared \(results.count) caption probe frames on \(device.name)")
