import Foundation
import Metal
let d=MTLCreateSystemDefaultDevice()!,q=d.makeCommandQueue()!
let code="""
#include <metal_stdlib>
using namespace metal;
kernel void copyFloat32(device const float *input [[buffer(0)]],device float *output [[buffer(1)]],uint id [[thread_position_in_grid]]) {
 if(id<65536) output[id]=input[id];
}
"""
let o=MTLCompileOptions();o.fastMathEnabled=true
let lib=try d.makeLibrary(source:code,options:o),p=try d.makeComputePipelineState(function:lib.makeFunction(name:"copyFloat32")!)
var seed:UInt32=41
var data=(0..<65536).map { _ -> UInt32 in
 seed=seed &* 1664525 &+ 1013904223
 return (seed & 0x7f800000)==0x7f800000 ? seed ^ 0x00800000:seed
}
data[0]=1063970584;data[1]=1063970581;data[2]=3192665359;data[3]=3192665422
let input=d.makeBuffer(bytes:data,length:data.count*4,options:.storageModeShared)!
let cache=d.makeBuffer(length:data.count*4,options:.storageModePrivate)!
let output=d.makeBuffer(length:data.count*4,options:.storageModeShared)!
let cb=q.makeCommandBuffer()!
for (a,b) in [(input,cache),(cache,output)] {
 let e=cb.makeComputeCommandEncoder()!;e.setComputePipelineState(p);e.setBuffer(a,offset:0,index:0);e.setBuffer(b,offset:0,index:1)
 e.dispatchThreadgroups(MTLSize(width:1024,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:64,height:1,depth:1));e.endEncoding()
}
cb.commit();cb.waitUntilCompleted()
guard cb.status == .completed else {fatalError(String(describing:cb.error))}
let words=output.contents().bindMemory(to:UInt32.self,capacity:data.count)
let differences=data.indices.filter {data[$0] != words[$0]}
let json:[String:Any]=["device":d.name,"finiteFloat32Patterns":data.count,"differentBitPatterns":differences.count,"privateRoundTrips":1]
try JSONSerialization.data(withJSONObject:json,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
