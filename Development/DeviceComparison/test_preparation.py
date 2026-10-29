"""CPU-only integration contracts. Never launches an app or creates a GPU device."""
import hashlib
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1];SDK=ROOT/'GradientsKit-V4'
sys.path.insert(0,str(HERE))
from prepare_sources import outputs

class PreparationTests(unittest.TestCase):
    def test_reference_is_exact_original(self):
        a=outputs('reference')
        for name in ['GradientGPU.swift','GradientViewController.swift','GradientMaskRenderer.swift']:
            self.assertEqual(a[name],(SDK/'Sources/GradientsKit'/name).read_bytes())
        self.assertEqual(hashlib.sha256(a['GradientsUIKit.metal']).hexdigest(),'6543c25f9bf24ccd7b58cd8e08e8711f599c97e9dcdcfdf0d3ae60714e713bea')

    def test_candidate_is_reviewed_shader_and_same_colors_api(self):
        a,b=outputs('reference'),outputs('precalc')
        self.assertEqual(hashlib.sha256(b['GradientsUIKit.metal']).hexdigest(),'06145e07ae6d8723e81a17741ec48905637e8365e8816fce35a39e797adb2e06')
        self.assertEqual(a['GradientYellowColors.swift'],b['GradientYellowColors.swift'])
        public=lambda s:[x.strip() for x in s.decode().splitlines() if re.search(r'\bpublic\b',x)]
        self.assertEqual(public(a['GradientViewController.swift']),public(b['GradientViewController.swift']))

    def test_mask_domain_is_only_one_graph_change(self):
        a=outputs('precalc');b=outputs('precalc',mask_domain=True)
        for name in a:
            if name != 'GradientMaskRenderer.swift':self.assertEqual(a[name],b[name])
        expansion=b'\n            .composited(over:CIImage(color:.clear).cropped(to:fullExtent))'
        self.assertEqual(a['GradientMaskRenderer.swift'].replace(expansion,b''),b['GradientMaskRenderer.swift'])
        self.assertNotEqual(a['GradientMaskRenderer.swift'],b['GradientMaskRenderer.swift'])
        with self.assertRaises(ValueError):outputs('reference',mask_domain=True)

    def test_pipeline_modes_and_allocation_publication(self):
        b=outputs('precalc');g=b['GradientGPU.swift'].decode();v=b['GradientViewController.swift'].decode()
        for phrase in ['function("prototypePrepareAxes",mode:3)','function("prototypeComputeBackground",mode:3)','function("v2CaptionProbe",mode:0)','pipeline("prototypeComposite",.bgra8Unorm,mode:0)']:
            self.assertIn(phrase,g)
        self.assertEqual(v.count('precalculation=textures.2'),2)
        self.assertLess(v.index('guard let precalculation=GradientPrecalculationBuffers'),v.index('return (backing,distorted,precalculation)'))
        self.assertIn('backing == nil || distorted == nil || precalculation == nil',v)
        # Existing nil drawable, error/slot handling and background drain remain.
        draw=v[v.index('    public func draw(in view:MTKView)'):]
        self.assertLess(draw.index('guard let drawable=view.currentDrawable'),draw.index('maskRenderer.render'))
        self.assertLess(draw.index('precalculation.encode'),draw.index('encoder.setComputePipelineState(gpu.background)'))
        self.assertIn('encoder.setBuffer(cache,offset:0,index:1)',draw)
        self.assertIn('if !rendered {availableSlots[slot]=true}',v)
        self.assertIn('self?.availableSlots[completedSlot]=true',v)
        for phrase in ['maskRenderer?.waitUntilScheduled()','GradientRenderSafety.waitUntilScheduled(lastCommand)','captionProbe?.waitUntilScheduled()']:
            self.assertIn(phrase,v)
        self.assertNotIn('waitUntilCompleted',v)

    def test_sdk_inputs_unchanged(self):
        for path in SDK.rglob('*'):
            if not path.is_file() or '.xcodeproj' in str(path) or '__pycache__' in str(path):continue
            relative=str(path.relative_to(ROOT))
            expected=subprocess.check_output(['git','show','9368500:'+relative],cwd=ROOT)
            self.assertEqual(path.read_bytes(),expected,relative)

    def test_resource_logic_with_mocks_debug_release(self):
        source=(HERE/'GradientPrecalculationBuffers.swift').read_text().replace('import Metal','')
        mocks=r'''
import Foundation
struct MTLResourceOptions:OptionSet {let rawValue:Int;static let storageModePrivate=Self(rawValue:1);static let hazardTrackingModeTracked=Self(rawValue:2)}
final class MTLBuffer {let length:Int;var label:String?;init(_ length:Int){self.length=length}}
final class WeakBuffer {weak var value:MTLBuffer?;init(_ value:MTLBuffer){self.value=value}}
final class MTLDevice {
 var maxBufferLength=1000000,failAt:Int?,attempts=0;var allocated:[WeakBuffer]=[]
 func makeBuffer(length:Int,options:MTLResourceOptions)->MTLBuffer? {
  precondition(options.contains(.storageModePrivate) && options.contains(.hazardTrackingModeTracked))
  attempts+=1;if attempts==failAt{return nil};let b=MTLBuffer(length);allocated.append(WeakBuffer(b));return b
 }
}
struct MTLSize {let width:Int,height:Int,depth:Int}
final class MTLComputePipelineState {var maxTotalThreadsPerThreadgroup=64}
final class MTLComputeCommandEncoder {
 var label:String?,buffers:[Int:MTLBuffer]=[:],extent:[UInt32]=[],groups:Int=0,ended=false
 func setComputePipelineState(_ p:MTLComputePipelineState){}
 func setBuffer(_ b:MTLBuffer,offset:Int,index:Int){precondition(offset==0);buffers[index]=b}
 func setBytes(_ pointer:UnsafeRawPointer,length:Int,index:Int){precondition(length==16 && index==3);extent=Array(UnsafeBufferPointer(start:pointer.assumingMemoryBound(to:UInt32.self),count:4))}
 func dispatchThreadgroups(_ n:MTLSize,threadsPerThreadgroup t:MTLSize){precondition(t.width==64 && t.height==1 && t.depth==1);groups=n.width}
 func endEncoding(){ended=true}
}
final class MTLCommandBuffer {
 var unavailable=false,encoders:[MTLComputeCommandEncoder]=[]
 func makeComputeCommandEncoder()->MTLComputeCommandEncoder? {if unavailable{return nil};let e=MTLComputeCommandEncoder();encoders.append(e);return e}
}
'''
        checks=r'''
precondition(GradientPrecalculationBuffers.byteCount(width:1170,height:2532)==128968)
precondition(GradientPrecalculationBuffers.byteCount(width:390,height:844)==43752)
for size in [(0,1),(-1,3),(1,0),(Int.max,Int.max)] {precondition(GradientPrecalculationBuffers.byteCount(width:size.0,height:size.1)==nil)}
let failed=MTLDevice();failed.failAt=2
precondition(GradientPrecalculationBuffers(device:failed,width:1170,height:2532)==nil)
precondition(failed.allocated.allSatisfy{$0.value==nil}) // unpublished partial allocation is released
let device=MTLDevice(),p=MTLComputePipelineState(),u=MTLBuffer(112),h=MTLBuffer(960)
var resources:GradientPrecalculationBuffers?=GradientPrecalculationBuffers(device:device,width:1170,height:2532)
precondition(resources!.slots.count==3)
precondition(resources!.slots[0] !== resources!.slots[1] && resources!.slots[1] !== resources!.slots[2])
precondition(resources!.buffer(slot:0,width:1171,height:2532)==nil)
precondition(resources!.buffer(slot:3,width:1170,height:2532)==nil)
var commands:[MTLCommandBuffer]=[]
for slot in 0..<3 {
 let cb=MTLCommandBuffer();let result=resources!.encode(command:cb,pipeline:p,uniformBuffer:u,historyBuffer:h,historyCount:240,scale:3,slot:slot)
 precondition(result === resources!.slots[slot]);let e=cb.encoders[0]
 precondition(e.buffers[0] === u && e.buffers[1] === h && e.buffers[2] === result)
 precondition(e.extent == [1170,2532,Float(3).bitPattern,240] && e.groups==40 && e.ended)
 commands.append(cb)
}
let invalid=MTLCommandBuffer()
precondition(resources!.encode(command:invalid,pipeline:p,uniformBuffer:u,historyBuffer:h,historyCount:241,scale:3,slot:0)==nil)
precondition(resources!.encode(command:invalid,pipeline:p,uniformBuffer:u,historyBuffer:h,historyCount:1,scale:Float.nan,slot:0)==nil)
precondition(resources!.encode(command:invalid,pipeline:p,uniformBuffer:MTLBuffer(4),historyBuffer:h,historyCount:0,scale:3,slot:0)==nil)
precondition(resources!.encode(command:invalid,pipeline:p,uniformBuffer:u,historyBuffer:MTLBuffer(4),historyCount:240,scale:3,slot:0)==nil)
precondition(resources!.encode(command:invalid,pipeline:p,uniformBuffer:u,historyBuffer:h,historyCount:0,scale:3,slot:3)==nil)
p.maxTotalThreadsPerThreadgroup=32
precondition(resources!.encode(command:invalid,pipeline:p,uniformBuffer:u,historyBuffer:h,historyCount:0,scale:3,slot:0)==nil)
precondition(invalid.encoders.isEmpty);p.maxTotalThreadsPerThreadgroup=64
invalid.unavailable=true
precondition(resources!.encode(command:invalid,pipeline:p,uniformBuffer:u,historyBuffer:h,historyCount:0,scale:3,slot:0)==nil)
// Failed replacement cannot mutate or publish over old extent.
let replacementDevice=MTLDevice();replacementDevice.failAt=1
precondition(GradientPrecalculationBuffers(device:replacementDevice,width:844,height:390)==nil)
precondition(resources!.width==1170 && resources!.height==2532)
// Encoders retain their bound objects while an old cache owner disappears.
let weak=WeakBuffer(resources!.slots[0]);resources=nil;precondition(weak.value != nil)
commands.removeAll();precondition(weak.value==nil)
print("Precalculation CPU logic: layout, failure, slots, extent, encoding, resize retention passed")
'''
        with tempfile.TemporaryDirectory() as folder:
            folder=Path(folder);(folder/'main.swift').write_text(mocks+source+checks)
            for mode,flag in [('Debug','-Onone'),('Release','-O')]:
                binary=folder/mode
                subprocess.run(['xcrun','swiftc',flag,'-module-cache-path',str(folder/'Cache'),str(folder/'main.swift'),'-o',str(binary)],check=True)
                subprocess.run([str(binary)],check=True)

if __name__=='__main__':unittest.main()
