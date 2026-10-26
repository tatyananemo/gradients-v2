#!/usr/bin/env python3
"""Compare raw CG/CI mask textures; never writes images or changes shader formulas."""
import subprocess,sys,tempfile
from pathlib import Path
here=Path(__file__).resolve().parent;root=here.parents[2]
sys.path.insert(0,str(root/'Development/Validation'));import validate as v
old=subprocess.check_output(['git','show','db3064b:UIKitComponent/GradientViewController.swift'],cwd=root,text=True)
new=(root/'GradientsKit-V4/Sources/GradientsKit/GradientViewController.swift').read_text()
header='''import Foundation
import AppKit
import Metal
import CoreImage
typealias UIColor=NSColor
final class GPU {
 let device=MTLCreateSystemDefaultDevice()!
 lazy var queue=device.makeCommandQueue()!
 lazy var ci=CIContext(mtlDevice:device,options:[.workingColorSpace:NSNull(),.outputColorSpace:NSNull()])
}
struct Frame {var time:Double;var yellow:Bool}
'''
accepted='--accepted-uikit' in sys.argv
if accepted:
 header+=subprocess.check_output(['git','show','9d4bd08:UIKitComponent/GradientMaskRenderer.swift'],cwd=root,text=True).replace('GradientMaskRenderer','AcceptedMaskRenderer')
classes=[]
for name,source in [('Legacy',old)]:
 method=v.block(source,'    func makeMask(')
 if accepted:
  method="""lazy var accepted=AcceptedMaskRenderer(device:gpu.device,queue:gpu.queue)
  func makeMask(_ index:Int,size:CGSize,scale:CGFloat)->MTLTexture {
   if maskTextures.isEmpty {
    let values=accepted.render(progress:session.interpolatedProgress(at:f.time),elapsed:f.time-session.startTime,yellow:f.yellow,counter:counter,size:size,scale:scale)
    for i in 0..<3 {maskTextures[i]=values[i]}
   }
   return maskTextures[index]!
  }
  """
 classes.append('class '+name+' {\nlet gpu:GPU\nlet session:GradientSession\nvar f:Frame\nlet counter=CGRect(x:0,y:356,width:390,height:76.6666666666667)\nvar maskContexts:[Int:CGContext]=[:]\nvar maskTextures:[Int:MTLTexture]=[:]\nvar presentationMask:CGFloat {session.interpolatedProgress(at:f.time)}\ninit(_ gpu:GPU,_ session:GradientSession,_ time:Double,_ yellow:Bool) {self.gpu=gpu;self.session=session;f=Frame(time:time,yellow:yellow)}\n'+method+'\n}')
classes.append('''class Candidate {
let renderer:GradientMaskRenderer;let session:GradientSession;let time:Double,yellow:Bool
var cached:[MTLTexture]?
init(_ gpu:GPU,_ session:GradientSession,_ time:Double,_ yellow:Bool){renderer=GradientMaskRenderer(device:gpu.device,queue:gpu.queue);self.session=session;self.time=time;self.yellow=yellow}
func makeMask(_ index:Int,size:CGSize,scale:CGFloat)->MTLTexture {
if cached==nil {cached=renderer.render(progress:session.interpolatedProgress(at:time),elapsed:time-session.startTime,yellow:yellow,counter:CGRect(x:0,y:356,width:390,height:76.6666666666667),size:size,scale:scale)}
return cached![index]
}
}''')
main=r'''
func bytes(_ texture:MTLTexture,_ gpu:GPU)->[UInt16] {
 let stride=((texture.width*8+255)/256)*256
 let buffer=gpu.device.makeBuffer(length:stride*texture.height,options:.storageModeShared)!
 let command=gpu.queue.makeCommandBuffer()!,blit=command.makeBlitCommandEncoder()!
 blit.copy(from:texture,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:MTLSize(width:texture.width,height:texture.height,depth:1),to:buffer,destinationOffset:0,destinationBytesPerRow:stride,destinationBytesPerImage:stride*texture.height)
 blit.endEncoding();command.commit();command.waitUntilCompleted();precondition(command.status == .completed)
 let p=buffer.contents().assumingMemoryBound(to:UInt16.self)
 return (0..<texture.height).flatMap {Array(UnsafeBufferPointer(start:p.advanced(by:$0*stride/2),count:texture.width*4))}
}
let gpu=GPU();var changed=0;var worst:Float=0;var count=0
for yellow in [false,true] {for progress in [0.0,0.3,0.6,0.8,1.0] {
 let session=GradientSession(at:0,initialProgress:CGFloat(progress))
 for time in [0.0,3.75] {
  let old=Legacy(gpu,session,time,yellow),new=Candidate(gpu,session,time,yellow)
  for i in 0..<3 {
   FileHandle.standardError.write(Data("Mask \(yellow) \(progress) \(time) \(i)\n".utf8))
   let a=bytes(old.makeMask(i,size:CGSize(width:390,height:844),scale:3),gpu)
   let b=bytes(new.makeMask(i,size:CGSize(width:390,height:844),scale:3),gpu)
   for j in a.indices where a[j] != b[j] {changed+=1;worst=max(worst,abs(Float(Float16(bitPattern:a[j]))-Float(Float16(bitPattern:b[j]))))}
   count+=1
  }
 }
}}
FileHandle.standardError.write(Data("Raw masks: \(count); different components: \(changed); max delta: \(worst)\n".utf8))
precondition(worst<=0.0001,"Mask change can be visible")
'''
if accepted:
 main=main.replace('precondition(worst<=0.0001,"Mask change can be visible")','precondition(changed==0,"Raw Float16 bytes differ from accepted UIKit")')
with tempfile.TemporaryDirectory() as folder:
 folder=Path(folder);(folder/'main.swift').write_text(header+'\n'.join(classes)+main)
 subprocess.run(['xcrun','swiftc','-O',str(root/'GradientsKit-V4/Sources/GradientsKit/Core/GradientSession.swift'),str(root/'GradientsKit-V4/Sources/GradientsKit/GradientMaskRenderer.swift'),str(root/'GradientsKit-V4/Sources/GradientsKit/GradientPerformanceMetrics.swift'),str(folder/'main.swift'),'-o',str(folder/'masks')],check=True)
 subprocess.run([str(folder/'masks')],check=True)
