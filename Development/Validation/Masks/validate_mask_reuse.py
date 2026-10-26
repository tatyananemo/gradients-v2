#!/usr/bin/env python3
"""Raw GPU regression against accepted pre-optimization masks, including resource reuse.
Three frames are queued before waiting to verify CG image snapshot lifetimes.
No PNG, screenshot, video or HTML is generated. Never wait in the live renderer.
"""
import subprocess,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[3]
reference=subprocess.check_output(['git','show','9d4bd08:UIKitComponent/GradientMaskRenderer.swift'],cwd=root,text=True).replace('GradientMaskRenderer','ReferenceMaskRenderer')
main=r'''
import Foundation
import Metal
let device=MTLCreateSystemDefaultDevice()!,queue=device.makeCommandQueue()!
let reference=ReferenceMaskRenderer(device:device,queue:queue)
let candidate=GradientMaskRenderer(device:device,queue:queue)
let source="""
#include <metal_stdlib>
using namespace metal;
kernel void compare(texture2d<float,access::read> a [[texture(0)]],texture2d<float,access::read> b [[texture(1)]],device atomic_uint *result [[buffer(0)]],uint2 id [[thread_position_in_grid]]) {
 if(id.x>=a.get_width()||id.y>=a.get_height())return;
 float4 x=a.read(id),y=b.read(id);
 for(int c=0;c<4;++c)if(x[c]!=y[c]) {
  atomic_fetch_add_explicit(result,1,memory_order_relaxed);
  atomic_fetch_max_explicit(result+1,as_type<uint>(abs(x[c]-y[c])),memory_order_relaxed);
 }
}
"""
let library=try device.makeLibrary(source:source,options:nil)
let pipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"compare")!)
var total=0,worst:Float=0
for batch in 0..<12 {
 autoreleasepool {
 var results:[MTLBuffer]=[]
 for slot in 0..<3 {
  let i=batch*3+slot,p:[CGFloat]=[0,0.3,0.6,0.8,1]
  let args=(p[i%5],Double(i)*0.137,i%2==1,CGRect(x:0,y:356,width:390,height:76.6666666666667),CGSize(width:390,height:844),CGFloat(3))
  let a=reference.render(progress:args.0,elapsed:args.1,yellow:args.2,counter:args.3,size:args.4,scale:args.5)
  let b=candidate.render(progress:args.0,elapsed:args.1,yellow:args.2,counter:args.3,size:args.4,scale:args.5)
  let command=queue.makeCommandBuffer()!
  for j in 0..<3 {
   let buffer=device.makeBuffer(length:8,options:.storageModeShared)!
   memset(buffer.contents(),0,8);results.append(buffer)
   let encoder=command.makeComputeCommandEncoder()!
   encoder.setComputePipelineState(pipeline);encoder.setTexture(a[j],index:0);encoder.setTexture(b[j],index:1);encoder.setBuffer(buffer,offset:0,index:0)
   encoder.dispatchThreads(MTLSize(width:a[j].width,height:a[j].height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1));encoder.endEncoding()
  }
  command.commit()
 }
 let end=queue.makeCommandBuffer()!;end.commit();end.waitUntilCompleted();precondition(end.status == .completed)
 for b in results {
  let values=b.contents().assumingMemoryBound(to:UInt32.self)
  total+=Int(values[0]);worst=max(worst,Float(bitPattern:values[1]))
 }
 }
}
print("Reused sources, 36 frames / 108 masks, 3 in flight: different components=\(total), max delta=\(worst)")
precondition(total==0,"Shared source content or synchronization differs from accepted masks")
'''
with tempfile.TemporaryDirectory() as folder:
 folder=Path(folder);(folder/'reference.swift').write_text(reference);(folder/'main.swift').write_text(main)
 for variant,flags in [('uncached-original-gaussian',[])]:
  print(variant,flush=True)
  subprocess.run(['xcrun','swiftc','-O',*flags,str(folder/'reference.swift'),str(root/'GradientsKit-V4/Sources/GradientsKit/GradientMaskRenderer.swift'),str(root/'GradientsKit-V4/Sources/GradientsKit/GradientPerformanceMetrics.swift'),str(folder/'main.swift'),'-o',str(folder/'check')],check=True)
  subprocess.run([str(folder/'check')],check=True)
