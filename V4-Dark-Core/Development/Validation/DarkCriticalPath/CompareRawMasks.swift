// Native Mac differential test, no oracle mutation or iOS launch.
import Foundation
import Metal
import CoreGraphics
let out=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
let device=MTLCreateSystemDefaultDevice()!,queue=device.makeCommandQueue()!
let baseline=GradientMaskRenderer(device:device,queue:queue)
let candidate=DomainMaskRenderer(device:device,queue:queue)
let source="""
#include <metal_stdlib>
using namespace metal;
kernel void difference(texture2d<float,access::read> a [[texture(0)]],texture2d<float,access::read> b [[texture(1)]],device float4 *groups [[buffer(0)]],uint2 p [[thread_position_in_grid]],uint local [[thread_index_in_threadgroup]],uint2 group [[threadgroup_position_in_grid]],uint2 extent [[threadgroups_per_grid]]) {
 threadgroup float4 sums[256];
 float4 result=0;
 if(p.x<a.get_width() && p.y<a.get_height()) {
  float4 x=a.read(p),y=b.read(p),delta=abs(x-y);
  for(uint c=0;c<4;c++) {result.x+=(x[c]!=y[c]);result.y=max(result.y,delta[c]);result.z+=delta[c];}
  result.w=any(x!=y);
 }
 sums[local]=result;threadgroup_barrier(mem_flags::mem_threadgroup);
 for(uint span=128;span>0;span/=2) {
  if(local<span) {float4 rhs=sums[local+span];sums[local].x+=rhs.x;sums[local].y=max(sums[local].y,rhs.y);sums[local].z+=rhs.z;sums[local].w+=rhs.w;}
  threadgroup_barrier(mem_flags::mem_threadgroup);
 }
 if(local==0) groups[group.y*extent.x+group.x]=sums[0];
}
"""
let lib=try device.makeLibrary(source:source,options:nil)
let pipe=try device.makeComputePipelineState(function:lib.makeFunction(name:"difference")!)
var cases:[(CGFloat,Double,Bool,CGFloat)]=[]
for yellow in [false,true] {for p:CGFloat in [0,0.3,0.6,0.8,1] {for t in [0.0,3.75] {cases.append((p,t,yellow,3))}}}
for i in 0..<36 {let p:[CGFloat]=[0,0.3,0.6,0.8,1];cases.append((p[i%5],Double(i)*0.137,i%2==1,3))}
// Additional fractional viewport/scale and long idle phase coverage.
var records:[[String:Any]]=[]
for (index,c) in cases.enumerated() {
 let size=CGSize(width:390,height:844),counter=CGRect(x:0,y:356,width:390,height:76.6666666666667)
 let a=baseline.render(progress:c.0,elapsed:c.1,yellow:c.2,counter:counter,size:size,scale:c.3)
 let b=candidate.render(progress:c.0,elapsed:c.1,yellow:c.2,counter:counter,size:size,scale:c.3)
 precondition(a.count==3 && b.count==3)
 let cb=queue.makeCommandBuffer()!;var results:[(MTLBuffer,Int)]=[]
 for i in 0..<3 {
  let nx=(a[i].width+15)/16,ny=(a[i].height+15)/16,count=nx*ny
  let buffer=device.makeBuffer(length:count*16,options:.storageModeShared)!
  let e=cb.makeComputeCommandEncoder()!;e.setComputePipelineState(pipe)
  e.setTexture(a[i],index:0);e.setTexture(b[i],index:1);e.setBuffer(buffer,offset:0,index:0)
  e.dispatchThreadgroups(MTLSize(width:nx,height:ny,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1));e.endEncoding();results.append((buffer,count))
 }
 cb.commit();cb.waitUntilCompleted();precondition(cb.status == .completed)
 for (mask,item) in results.enumerated() {
  let values=UnsafeBufferPointer(start:item.0.contents().assumingMemoryBound(to:SIMD4<Float>.self),count:item.1)
  var changed:Double=0,maximum:Float=0,total:Double=0,pixels:Double=0
  for v in values {changed+=Double(v.x);maximum=max(maximum,v.y);total+=Double(v.z);pixels+=Double(v.w)}
  records.append(["frame":index,"mask":mask,"progress":c.0,"elapsed":c.1,"yellow":c.2,"components":changed,"maxFloatDelta":maximum,"sumFloatDelta":total,"pixels":pixels,"totalPixels":a[mask].width*a[mask].height])
 }
 if index%10==0 {print("Raw masks \(index+1)/\(cases.count)");fflush(stdout)}
}
try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("raw-masks.json"))
print("Compared \(records.count) raw masks; output thresholds unchanged")
