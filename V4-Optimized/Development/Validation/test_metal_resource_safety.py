#!/usr/bin/env python3
"""CPU-only recovery tests; no MTLDevice, Simulator, application or GPU submission.

Compile maintained methods against deterministic Metal doubles, and exercise the
actual Core Graphics raster scope on CPU. This is not UIKit/GPU integration QA.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/"GradientsKit-V4/Scripts"))
from source_colors import load,swift_source

ROOT = Path(__file__).resolve().parents[2]
SDK = ROOT / 'GradientsKit-V4/Sources/GradientsKit'


def method(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


class ResourceSafetyTests(unittest.TestCase):
    def test_recovery_without_gpu_or_uikit(self):
        safety = (SDK / 'GradientRenderSafety.swift').read_text().replace('import Metal', '')
        view = (SDK / 'GradientViewController.swift').read_text()
        caption = (SDK / 'SessionCaptionProbe.swift').read_text()
        mask = (SDK / 'GradientMaskRenderer.swift').read_text()
        allocate = method(view, '    private func makeFrameTextures(')
        prepare = method(view, '    private func prepareFrameResources(')
        resume = method(view, '    public func resumeRendering()').replace('public func', 'func')
        caption_prepare = method(caption, ' func prepareResources()')
        draw = method(view, '    public func draw(in view:MTKView)')
        admit = draw[:draw.index('        let maskStart=')].replace('public func draw', 'func draw')
        admit += '''        _ = (completedSlot, drawable, command, backing, distorted)
        maskPreparations+=1
        if maskFails {renderSafety.resourcesUnavailable("Mask texture allocation");return}
        rendered=true
    }'''
        present = method(view, '    func present(')
        admission = present[present.index('        guard hasRenderableBounds'):present.index('        performanceFrame+=1')]
        release = '        if !rendered {availableSlots[slot]=true}'
        self.assertIn(release, present)
        resize = view[view.index('        if backing.width != Int(pixelSize.width)'):]
        resize = resize[:resize.index('        captionLabel?.frame=')]
        geometry = mask[mask.index('        let flow='):mask.index('        let source=cacheIntermediates')]
        # Trigger only the constructor failure, retaining the actual raster scope
        # and its defer so a retry checks both CTM and every bitmap component.
        raster = mask[mask.index('        ctx.clear(CGRect'):mask.index('        if let source {\n            let status=')]
        raster = raster.replace('let gradient=CGGradient(', 'let gradient=forceGradientFailure ? nil:CGGradient(')
        raster = raster.replace('return nil', 'return false')
        mocks = r'''
import Foundation
import CoreGraphics
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
    var calls=0,failAt=0,bufferCalls=0,bufferFailAt=0,queueCalls=0,queueFailAt=0
    func makeBuffer(length:Int,options:BufferOptions)->MTLBuffer? {
        bufferCalls+=1;return bufferCalls==bufferFailAt ? nil:MTLBuffer(length)
    }
    func makeTexture(descriptor d:MTLTextureDescriptor)->MTLTexture? {
        calls+=1;precondition(d.usage == [.shaderRead,.shaderWrite,.renderTarget])
        return calls==failAt ? nil:MTLTexture(d.width,d.height)
    }
    func makeCommandQueue()->Queue? {queueCalls+=1;return queueCalls==queueFailAt ? nil:Queue()}
}
final class Queue {
    var calls=0,fail=false
    func makeCommandBuffer()->MTLCommandBuffer? {calls+=1;return fail ? nil:MTLCommandBuffer(.notEnqueued)}
}
final class GPU {let device=Device(),queue=Queue()}
final class Metrics {func add(_ key:String,_ value:Double){}}
final class Drawable {}
final class FrameView {var bounds=CGRect(x:0,y:0,width:10,height:10)}
final class MTKView {var currentDrawable:Drawable?=Drawable();var drawableSize=CGSize(width:10,height:10);var bounds=CGRect(x:0,y:0,width:10,height:10);var frame=CGRect.zero;var contentScaleFactor:CGFloat=1}
'''
        harness = '''
final class Probe {
    let device:Device,safety:GradientRenderSafety
    var queue:Queue?=Queue(),uniformsBuffer:MTLBuffer?=MTLBuffer(128),historyBuffer:MTLBuffer?=MTLBuffer(2048),resultBuffer:MTLBuffer?=MTLBuffer(5760)
    var busy=false
    init(_ device:Device,_ safety:GradientRenderSafety){self.device=device;self.safety=safety}
''' + caption_prepare + '''
    func discardForTest(){queue=nil;uniformsBuffer=nil;historyBuffer=nil;resultBuffer=nil}
}
final class Harness {
    let gpu=GPU(),renderSafety=GradientRenderSafety(),view=FrameView()
    lazy var captionProbe:Probe?=Probe(gpu.device,renderSafety)
    var viewMetal:MTKView!=MTKView(),renderingScale:CGFloat=1,currentSize=CGSize(width:10,height:10)
    var hasRenderableBounds:Bool {view.bounds.width>=1 && view.bounds.height>=1}
    var explicitlyPaused=false
    var backing:MTLTexture?=MTLTexture(10,10),distorted:MTLTexture?=MTLTexture(10,10)
    var rendered=false,availableSlots=[true,true,true],activeSlot=0,maskPreparations=0,pauses=0,framesSkipped=0,maskFails=false
    var performanceMetrics:Metrics?,uniformBuffer:MTLBuffer?,historyBuffer:MTLBuffer?
    var uniformSlots=[MTLBuffer(112),MTLBuffer(112),MTLBuffer(112)],historySlots=[MTLBuffer(960),MTLBuffer(960),MTLBuffer(960)]
    func updateDisplayLink(){pauses+=1}
''' + allocate + '\n' + prepare + '\n' + resume + '\n' + admit + '''
    func synchronizeDrawableLayout(){
        guard !renderSafety.isStopped,let metal=viewMetal,let backing else{return}
        let pixelSize=view.bounds.size,size=pixelSize
''' + resize + '''
    }
    func frame(){
''' + admission + '''
        rendered=false;draw(in:viewMetal)
''' + release + '''
    }
    func startup()->Bool {prepareFrameResources(width:10,height:10)}
    func discardForStartupTest(){backing=nil;distorted=nil;uniformSlots=[];historySlots=[]}
}
func raster(ctx:CGContext,index:Int,forceGradientFailure:Bool,safety:GradientRenderSafety)->Bool {
    let p:CGFloat=0.6,elapsed=2.3,yellow=true,size=CGSize(width:390,height:844),scale:CGFloat=1
    let counter=CGRect(x:0,y:356,width:390,height:77)
''' + geometry + raster + '''
    return true
}
'''
        checks = r'''
// First GPU error is independent of a prior temporary resource failure.
let good=MTLCommandBuffer(.completed),s=GradientRenderSafety()
s.completed(good,stage:"good");precondition(!s.isStopped && !s.retryResources())
s.resourcesUnavailable("allocation");precondition(s.isStopped && s.retryResources() && !s.isStopped && !s.retryResources())
s.resourcesUnavailable("allocation again")
let underlying=NSError(domain:"MTLCommandBufferErrorDomain",code:3)
s.completed(MTLCommandBuffer(.error,error:underlying),stage:"mask 0")
let first=s.firstError!
DispatchQueue.concurrentPerform(iterations:1000){i in if i%2==0 {s.fail("later \(i)")} else {_=s.retryResources()}}
precondition(s.isStopped && s.firstError === first && !s.retryResources())
precondition(first.localizedDescription=="mask 0" && (first.userInfo[NSUnderlyingErrorKey] as? NSError)?.code==3)
let racing=GradientRenderSafety();racing.resourcesUnavailable("temporary")
DispatchQueue.concurrentPerform(iterations:1000){i in if i%2==0 {racing.fail("worker \(i)")} else {_=racing.retryResources()}}
let saved=racing.firstError!;precondition(racing.isStopped && !racing.retryResources());racing.fail("overwrite");precondition(racing.firstError === saved)
for status in MTLCommandBufferStatus.allCases {
    let c=MTLCommandBuffer(status);GradientRenderSafety.waitUntilScheduled(c)
    precondition(c.waits == (status == .committed ? 1:0))
}
GradientRenderSafety.waitUntilScheduled(nil)
let nilDrawable=Harness();nilDrawable.viewMetal.currentDrawable=nil
for _ in 0..<100 {nilDrawable.frame()}
precondition(nilDrawable.maskPreparations==0 && nilDrawable.gpu.queue.calls==0 && nilDrawable.availableSlots.allSatisfy{$0})
nilDrawable.viewMetal.currentDrawable=Drawable();nilDrawable.frame();precondition(nilDrawable.rendered && nilDrawable.maskPreparations==1)
let busy=Harness();busy.availableSlots=[false,false,false];busy.frame();precondition(busy.gpu.queue.calls==0)
let command=Harness();command.gpu.queue.fail=true;command.frame()
precondition(command.renderSafety.isStopped && command.availableSlots.allSatisfy{$0})
for _ in 0..<100 {command.frame()};precondition(command.gpu.queue.calls==1)
command.resumeRendering();command.frame();precondition(command.gpu.queue.calls==2 && command.renderSafety.isStopped)
for _ in 0..<100 {command.frame()};precondition(command.gpu.queue.calls==2)
command.gpu.queue.fail=false;command.resumeRendering();command.frame();precondition(command.rendered && !command.renderSafety.isStopped)
let stopped=Harness();stopped.renderSafety.fail("fatal");stopped.resumeRendering();stopped.frame()
precondition(stopped.renderSafety.isStopped && stopped.gpu.queue.calls==0 && stopped.gpu.device.calls==0)
// A failed resize retains the full old bundle, submits nothing at the new size,
// and does not free an older frame's slot when a later frame is cancelled.
for failing in [1,2] {
    let h=Harness(),oldBacking=h.backing!,oldDistorted=h.distorted!
    h.view.bounds.size=CGSize(width:20,height:30);h.availableSlots[0]=false
    h.gpu.device.failAt=failing;h.frame()
    precondition(h.renderSafety.isStopped && h.backing === oldBacking && h.distorted === oldDistorted)
    precondition(h.viewMetal.drawableSize==CGSize(width:10,height:10) && h.gpu.queue.calls==0 && h.availableSlots==[false,true,true])
    let attempts=h.gpu.device.calls
    for _ in 0..<100 {h.frame()};precondition(h.gpu.device.calls==attempts)
    h.gpu.device.failAt=0;h.resumeRendering();h.frame()
    precondition(!h.renderSafety.isStopped && h.rendered && h.backing!.width==20 && h.distorted!.height==30 && h.availableSlots==[false,false,true])
    // In-flight completion alone releases the older slot; resume never resets it.
    h.availableSlots[0]=true
}
for failing in 1...6 {
    let h=Harness();h.discardForStartupTest();h.gpu.device.bufferFailAt=failing
    precondition(!h.startup() && h.renderSafety.isStopped && h.uniformSlots.isEmpty && h.historySlots.isEmpty)
    h.gpu.device.bufferFailAt=0;h.resumeRendering();h.frame()
    precondition(h.rendered && !h.renderSafety.isStopped && h.uniformSlots.count==3 && h.historySlots.count==3)
    precondition(h.uniformSlots.allSatisfy{$0.length==112} && h.historySlots.allSatisfy{$0.length==960})
}
for failing in [1,2] {
    let h=Harness();h.discardForStartupTest();h.gpu.device.failAt=failing
    precondition(!h.startup() && h.backing==nil && h.distorted==nil)
    let buffers=h.gpu.device.bufferCalls
    h.gpu.device.failAt=0;h.resumeRendering();h.frame()
    precondition(h.rendered && h.gpu.device.bufferCalls==buffers)
}
// Mask failure cancels only this frame. The existing IOSurface pool is untouched.
let mask=Harness();mask.maskFails=true;mask.frame()
precondition(mask.renderSafety.isStopped && mask.availableSlots.allSatisfy{$0} && !mask.rendered)
mask.maskFails=false;mask.resumeRendering();mask.frame();precondition(mask.rendered && !mask.renderSafety.isStopped)
for failing in 0...3 {
    let h=Harness(),probe=h.captionProbe!;probe.discardForTest()
    if failing==0 {h.gpu.device.queueFailAt=1} else {h.gpu.device.bufferFailAt=failing}
    precondition(!probe.prepareResources() && h.renderSafety.isStopped && probe.queue==nil && probe.uniformsBuffer==nil && probe.historyBuffer==nil && probe.resultBuffer==nil)
    h.gpu.device.queueFailAt=0;h.gpu.device.bufferFailAt=0;h.resumeRendering();h.frame()
    precondition(h.rendered && !h.renderSafety.isStopped && probe.uniformsBuffer!.length==128 && probe.historyBuffer!.length==2048 && probe.resultBuffer!.length==5760)
    // No replacement while the complete caption bundle is in flight.
    probe.busy=true;let u=probe.uniformsBuffer!,calls=h.gpu.device.bufferCalls
    precondition(probe.prepareResources() && probe.uniformsBuffer === u && h.gpu.device.bufferCalls==calls)
}
let cs=CGColorSpace(name:CGColorSpace.sRGB)!
func bitmap()->CGContext {CGContext(data:nil,width:390,height:180,bitsPerComponent:8,bytesPerRow:0,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!}
let recovered=bitmap(),reference=bitmap(),rasterSafety=GradientRenderSafety(),originalTransform=recovered.ctm
precondition(!raster(ctx:recovered,index:0,forceGradientFailure:true,safety:rasterSafety) && recovered.ctm==originalTransform)
precondition(rasterSafety.isStopped && rasterSafety.retryResources())
precondition(raster(ctx:recovered,index:0,forceGradientFailure:false,safety:rasterSafety))
precondition(raster(ctx:reference,index:0,forceGradientFailure:false,safety:GradientRenderSafety()))
precondition(recovered.bytesPerRow==reference.bytesPerRow)
let count=recovered.bytesPerRow*recovered.height
precondition(Data(bytes:recovered.data!,count:count)==Data(bytes:reference.data!,count:count),"Retry inherited stale CGContext transform or clip")
print("Resource recovery: fatal/temporary separation, concurrent first error, explicit bounded retry, nil drawable recovery, slots, atomic startup/resize, masks, caption resources and exact CPU raster retry passed")
'''
        with tempfile.TemporaryDirectory(prefix='v4-resource-safety-') as folder:
            folder = Path(folder)
            source = folder / 'main.swift'
            source.write_text(mocks + swift_source(load(ROOT/"GradientsKit-V4")) + safety + harness + checks)
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
        self.assertIn('backing.width==Int(viewMetal.drawableSize.width)', present)
        background = method(view, '    private func scheduleOutstandingWorkForBackground()')
        for call in ['maskRenderer?.waitUntilScheduled()', 'GradientRenderSafety.waitUntilScheduled(lastCommand)', 'captionProbe?.waitUntilScheduled()']:
            self.assertIn(call, background)
        for signature in ['    @objc private func applicationDidEnterBackground()', '    @objc private func sceneDidEnterBackground(']:
            self.assertIn('scheduleOutstandingWorkForBackground()', method(view, signature))
        self.assertEqual(view.count('renderSafety.retryResources()'), 1)
        self.assertIn('renderSafety.retryResources()', method(view, '    public func resumeRendering()'))
        # Failed startup allocation must not skip gesture/UI/lifecycle setup.
        load = method(view, '    public override func viewDidLoad()')
        self.assertIn('_=prepareFrameResources(', load)
        self.assertNotIn('else{return}', load)
        self.assertIn('UIApplication.didEnterBackgroundNotification', load)
        self.assertIn('UIScene.didEnterBackgroundNotification', load)
        for source in [view, mask, caption]:
            self.assertNotIn('waitUntilCompleted(', source)
            self.assertIn('safety.completed(', source)
            self.assertNotRegex(source, r'(?:renderSafety|safety)\.fail\("[^"\n]*(?:allocation|unavailable)')
        for signature in ['    func present(', '    public func draw(in view:MTKView)', '    func tick()']:
            self.assertNotIn('waitUntilScheduled', method(view, signature))
        self.assertIn('workers.forEach {GradientRenderSafety.waitUntilScheduled($0.lastCommand)}', mask)
        self.assertIn('func waitUntilScheduled(){GradientRenderSafety.waitUntilScheduled(lastCommand)}', caption)
        self.assertIn('ctx.saveGState();defer {ctx.restoreGState()}', mask)
        self.assertIn('safety.fail("Mask IOSurface unlock"', mask)  # integrity failure remains terminal
        self.assertNotIn('makeTexture(descriptor:desc)!', mask)
        self.assertNotIn('makeCommandBuffer()!', mask)
        self.assertNotIn('makeTexture(descriptor:d)!', view)
        self.assertNotIn('options:.storageModeShared)!', view)
        self.assertNotIn('makeComputeCommandEncoder()!', view)
        self.assertNotIn('makeRenderCommandEncoder(descriptor:desc)!', view)
        self.assertNotIn('output!', mask)


if __name__ == '__main__':
    unittest.main()
