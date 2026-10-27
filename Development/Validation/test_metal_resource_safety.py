#!/usr/bin/env python3
"""CPU-only failure-path tests. Never creates MTLDevice or starts Simulator.

Compile the maintained failure latch plus extracted allocation/admission methods
against deterministic Metal doubles. UIKit/GPU integration remains a later check.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SDK = ROOT / 'GradientsKit-V4/Sources/GradientsKit'


def method(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


class ResourceSafetyTests(unittest.TestCase):
    def test_failure_paths_without_metal_or_uikit(self):
        safety = (SDK / 'GradientRenderSafety.swift').read_text().replace('import Metal', '')
        view = (SDK / 'GradientViewController.swift').read_text()
        allocate = method(view, '    private func makeFrameTextures(')
        draw = method(view, '    public func draw(in view:MTKView)')
        # Execute the actual admission prefix before any mask preparation.
        admit = draw[:draw.index('        let maskStart=')].replace('public func draw', 'func draw')
        admit += '        _ = (completedSlot, drawable, command, backing, distorted)\n        maskPreparations+=1;rendered=true\n    }'
        resize = view[view.index('        if backing.width != Int(pixelSize.width)'):]
        resize = resize[:resize.index('        currentSize=size')]
        inputs = view[view.index('        var newUniforms:'):view.index('        backing=textures.0;distorted=textures.1')]
        mocks = r'''
import Foundation
// Metal doubles deliberately use the names in the production implementation.
enum MTLCommandBufferStatus:CaseIterable {case notEnqueued,enqueued,committed,scheduled,completed,error}
final class MTLCommandBuffer {
    var status:MTLCommandBufferStatus;var error:Error?;var waits=0
    init(_ status:MTLCommandBufferStatus,error:Error?=nil){self.status=status;self.error=error}
    func waitUntilScheduled(){waits+=1;status = .scheduled}
}
final class MTLTexture {let width:Int,height:Int;init(_ w:Int,_ h:Int){width=w;height=h}}
struct Usage:OptionSet {let rawValue:Int;static let shaderRead=Usage(rawValue:1),shaderWrite=Usage(rawValue:2),renderTarget=Usage(rawValue:4)}
enum Format {case rgba16Float}
enum Storage {case `private`}
final class MTLTextureDescriptor {
    var width=0,height=0;var usage:Usage=[];var storageMode:Storage = .private
    static func texture2DDescriptor(pixelFormat:Format,width:Int,height:Int,mipmapped:Bool)->MTLTextureDescriptor {
        precondition(!mipmapped);let d=MTLTextureDescriptor();d.width=width;d.height=height;return d
    }
}
final class MTLBuffer {let length:Int;init(_ length:Int){self.length=length}}
enum BufferOptions {case storageModeShared}
final class Device {
    var calls=0,failAt=0,bufferCalls=0,bufferFailAt=0
    func makeBuffer(length:Int,options:BufferOptions)->MTLBuffer? {
        bufferCalls+=1;return bufferCalls==bufferFailAt ? nil:MTLBuffer(length)
    }
    func makeTexture(descriptor d:MTLTextureDescriptor)->MTLTexture? {
        calls+=1;precondition(d.usage == [.shaderRead,.shaderWrite,.renderTarget])
        return calls==failAt ? nil:MTLTexture(d.width,d.height)
    }
}
final class Queue {
    var calls=0,fail=false
    func makeCommandBuffer()->MTLCommandBuffer? {calls+=1;return fail ? nil:MTLCommandBuffer(.notEnqueued)}
}
final class GPU {let device=Device(),queue=Queue()}
final class Metrics {func add(_ key:String,_ value:Double){}}
final class Drawable {}
final class MTKView {var currentDrawable:Drawable?}
'''
        harness = '''
final class Harness {
    let gpu=GPU(),renderSafety=GradientRenderSafety()
    var backing:MTLTexture?=MTLTexture(10,10),distorted:MTLTexture?=MTLTexture(10,10)
    var rendered=false,availableSlots=[true,true,true],activeSlot=0,maskPreparations=0,pauses=0
    var performanceMetrics:Metrics?
    var uniformSlots=[MTLBuffer(1)],historySlots=[MTLBuffer(1)]
    func updateDisplayLink(){pauses+=1}
''' + allocate + '\n' + admit + '''
    func allocateInputs(){
''' + inputs + '''
        uniformSlots=newUniforms;historySlots=newHistory
    }

    func resize(_ pixelSize:CGSize){guard let backing else{return}
''' + resize + '''
    }
    func frame(_ view:MTKView){
        guard let slot=availableSlots.firstIndex(of:true) else{return}
        activeSlot=slot;availableSlots[slot]=false
        rendered=false;draw(in:view)
        if !rendered {availableSlots[slot]=true}
    }
}
'''
        checks = r'''
let good=MTLCommandBuffer(.completed),s=GradientRenderSafety()
s.completed(good,stage:"good");precondition(!s.isStopped)
let underlying=NSError(domain:"MTLCommandBufferErrorDomain",code:3)
s.completed(MTLCommandBuffer(.error,error:underlying),stage:"mask 0")
let first=s.firstError!
DispatchQueue.concurrentPerform(iterations:1000){i in s.fail("later \(i)")}
precondition(s.isStopped && s.firstError === first)
precondition(first.localizedDescription=="mask 0")
precondition((first.userInfo[NSUnderlyingErrorKey] as? NSError)?.code==3)
let racing=GradientRenderSafety()
DispatchQueue.concurrentPerform(iterations:1000){i in racing.fail("worker \(i)")}
let saved=racing.firstError!;racing.fail("overwrite");precondition(racing.firstError === saved)
for status in MTLCommandBufferStatus.allCases {
    let c=MTLCommandBuffer(status)
    GradientRenderSafety.waitUntilScheduled(c)
    precondition(c.waits == (status == .committed ? 1:0))
}
GradientRenderSafety.waitUntilScheduled(nil)
// Both queues, including a mask that outlives an abandoned composition.
let mask=MTLCommandBuffer(.committed),composition=MTLCommandBuffer(.completed),caption=MTLCommandBuffer(.committed)
for c in [mask,composition,caption] {GradientRenderSafety.waitUntilScheduled(c)}
precondition(mask.waits==1 && composition.waits==0 && caption.waits==1)
let view=MTKView(),nilDrawable=Harness()
for _ in 0..<100 {nilDrawable.frame(view)}
precondition(nilDrawable.maskPreparations==0 && nilDrawable.gpu.queue.calls==0)
precondition(nilDrawable.availableSlots.allSatisfy{$0})
let normal=Harness();view.currentDrawable=Drawable();normal.frame(view)
precondition(normal.maskPreparations==1 && normal.gpu.queue.calls==1 && !normal.availableSlots[0])
let busy=Harness();busy.availableSlots=[false,false,false];busy.frame(view)
precondition(busy.maskPreparations==0 && busy.gpu.queue.calls==0)
let failedCommand=Harness();failedCommand.gpu.queue.fail=true;failedCommand.frame(view)
precondition(failedCommand.renderSafety.isStopped && failedCommand.maskPreparations==0 && failedCommand.availableSlots.allSatisfy{$0})
let stopped=Harness();stopped.renderSafety.fail("fatal");stopped.frame(view)
precondition(stopped.gpu.queue.calls==0 && stopped.maskPreparations==0)
for failing in [1,2] {
    let h=Harness(),oldBacking=h.backing!,oldDistorted=h.distorted!
    h.gpu.device.failAt=failing;h.resize(CGSize(width:20,height:30))
    precondition(h.renderSafety.isStopped && h.backing === oldBacking && h.distorted === oldDistorted)
    precondition(h.gpu.device.calls==failing && h.pauses==1)
}
for failing in 1...6 {
    let h=Harness(),oldU=h.uniformSlots[0],oldH=h.historySlots[0]
    h.gpu.device.bufferFailAt=failing;h.allocateInputs()
    precondition(h.renderSafety.isStopped && h.uniformSlots[0] === oldU && h.historySlots[0] === oldH)
    precondition(h.gpu.device.bufferCalls==failing)
}
let buffers=Harness();buffers.allocateInputs()
precondition(!buffers.renderSafety.isStopped && buffers.uniformSlots.count==3 && buffers.historySlots.count==3)
precondition(buffers.uniformSlots.allSatisfy{$0.length==112} && buffers.historySlots.allSatisfy{$0.length==960})
let unchanged=Harness();unchanged.resize(CGSize(width:10,height:10));precondition(unchanged.gpu.device.calls==0)
let resized=Harness();resized.resize(CGSize(width:20,height:30))
precondition(resized.gpu.device.calls==2 && resized.backing!.width==20 && resized.distorted!.height==30 && !resized.renderSafety.isStopped)
print("Resource safety: first-error concurrency, terminal failures, scheduling states/both queues, nil drawable x100, busy slots, command/texture/buffer allocation failure, atomic resize passed")
'''
        with tempfile.TemporaryDirectory(prefix='v4-resource-safety-') as folder:
            folder = Path(folder)
            source = folder / 'main.swift'
            source.write_text(mocks + safety + harness + checks)
            for mode, flags in [('Debug', ['-Onone']), ('Release', ['-O'])]:
                binary = folder / mode
                subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'ModuleCache'), *flags, str(source), '-o', str(binary)], check=True)
                subprocess.run([str(binary)], check=True)

    def test_submission_and_lifecycle_wiring(self):
        view = (SDK / 'GradientViewController.swift').read_text()
        mask = (SDK / 'GradientMaskRenderer.swift').read_text()
        caption = (SDK / 'SessionCaptionProbe.swift').read_text()
        present = method(view, '    func present(')
        draw = method(view, '    public func draw(in view:MTKView)')
        self.assertNotIn('maskRenderer.render', present)
        self.assertLess(draw.index('guard let drawable=view.currentDrawable'), draw.index('maskRenderer.render'))
        self.assertLess(draw.index('guard let command='), draw.index('maskRenderer.render'))
        self.assertIn('if !rendered {availableSlots[slot]=true}', present)
        self.assertIn('guard !renderSafety.isStopped', present)
        self.assertIn('renderSafety.isStopped', method(view, '    public func draw(in view:MTKView)'))
        background = method(view, '    private func scheduleOutstandingWorkForBackground()')
        for call in ['maskRenderer?.waitUntilScheduled()', 'GradientRenderSafety.waitUntilScheduled(lastCommand)', 'captionProbe?.waitUntilScheduled()']:
            self.assertIn(call, background)
        for signature in ['    @objc private func applicationDidEnterBackground()', '    @objc private func sceneDidEnterBackground(']:
            self.assertIn('scheduleOutstandingWorkForBackground()', method(view, signature))
        self.assertIn('UIApplication.didEnterBackgroundNotification', view)
        self.assertIn('UIScene.didEnterBackgroundNotification', view)
        for source in [view, mask, caption]:
            self.assertNotIn('waitUntilCompleted(', source)
            self.assertIn('safety.completed(', source)
        for signature in ['    func present(', '    public func draw(in view:MTKView)', '    func tick()']:
            self.assertNotIn('waitUntilScheduled', method(view, signature))
        self.assertIn('workers.forEach {GradientRenderSafety.waitUntilScheduled($0.lastCommand)}', mask)
        self.assertIn('func waitUntilScheduled(){GradientRenderSafety.waitUntilScheduled(lastCommand)}', caption)
        self.assertNotIn('makeTexture(descriptor:desc)!', mask)
        self.assertNotIn('makeCommandBuffer()!', mask)
        self.assertNotIn('makeTexture(descriptor:d)!', view)
        self.assertNotIn('options:.storageModeShared)!', view)
        self.assertNotIn('makeComputeCommandEncoder()!', view)
        self.assertNotIn('makeRenderCommandEncoder(descriptor:desc)!', view)
        self.assertNotIn('output!', mask)


if __name__ == '__main__':
    unittest.main()
