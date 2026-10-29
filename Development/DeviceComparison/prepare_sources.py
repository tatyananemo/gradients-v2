#!/usr/bin/env python3
"""Build-only overlays for the isolated A/B device project; SDK remains immutable."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
SDK=ROOT/'GradientsKit-V4'
sys.path.insert(0,str(SDK/'Scripts'))
sys.path.insert(0,str(HERE))
from compose_uikit_metal import compose_sdk
from source_colors import load,swift_source
from precalculation_source import compose_candidate
from shared_background_source import compose_candidate as compose_shared_candidate

def replace(source,old,new,count=1):
    if source.count(old)!=count:
        raise ValueError('Unexpected source shape: '+old[:100])
    return source.replace(old,new)

def gpu_source():
    s=(SDK/'Sources/GradientsKit/GradientGPU.swift').read_text()
    s=replace(s,'    let clear:MTLTexture','    let preparation:MTLComputePipelineState\n    let clear:MTLTexture')
    s=replace(s,'func function(_ name:String) throws -> MTLFunction {','''func function(_ name:String,mode:UInt32?=nil) throws -> MTLFunction {
            if var mode {
                let values=MTLFunctionConstantValues()
                values.setConstantValue(&mode,type:.uint,index:101)
                return try compiledLibrary.makeFunction(name:name,constantValues:values)
            }''')
    s=replace(s,'func pipeline(_ name:String,_ format:MTLPixelFormat) throws -> MTLRenderPipelineState {','func pipeline(_ name:String,_ format:MTLPixelFormat,mode:UInt32?=nil) throws -> MTLRenderPipelineState {')
    s=replace(s,'descriptor.fragmentFunction=try function(name)','descriptor.fragmentFunction=try function(name,mode:mode)')
    s=replace(s,'background=try device.makeComputePipelineState(function:function("prototypeComputeBackground"))','''preparation=try device.makeComputePipelineState(function:function("prototypePrepareAxes",mode:3))
        guard preparation.maxTotalThreadsPerThreadgroup>=64 else {throw NSError(domain:"GradientsKit.PrecalculationThreads",code:1)}
        background=try device.makeComputePipelineState(function:function("prototypeComputeBackground",mode:3))''')
    s=replace(s,'caption=try device.makeComputePipelineState(function:function("v2CaptionProbe"))','caption=try device.makeComputePipelineState(function:function("v2CaptionProbe",mode:0))')
    s=replace(s,'composite=try pipeline("prototypeComposite",.bgra8Unorm)','composite=try pipeline("prototypeComposite",.bgra8Unorm,mode:0)')
    return s.encode()

def controller_source():
    s=(SDK/'Sources/GradientsKit/GradientViewController.swift').read_text()
    s=replace(s,'    var masks:[MTLTexture]=[]','    private var precalculation:GradientPrecalculationBuffers?\n    var masks:[MTLTexture]=[]')
    s=replace(s,'if backing == nil || distorted == nil {','if backing == nil || distorted == nil || precalculation == nil {')
    s=replace(s,'backing=textures.0;distorted=textures.1','backing=textures.0;distorted=textures.1;precalculation=textures.2',count=2)
    s=replace(s,'private func makeFrameTextures(width:Int,height:Int)->(MTLTexture,MTLTexture)? {','private func makeFrameTextures(width:Int,height:Int)->(MTLTexture,MTLTexture,GradientPrecalculationBuffers)? {')
    s=replace(s,'        return (backing,distorted)','''        guard let precalculation=GradientPrecalculationBuffers(device:gpu.device,width:width,height:height) else {
            renderSafety.resourcesUnavailable("Precalculation buffer allocation");return nil
        }
        return (backing,distorted,precalculation)''')
    s=replace(s,'        // Each in-flight frame owns its shared CPU inputs. No semaphore wait on main.','''        guard let precalculation,precalculation.width==backing.width,precalculation.height==backing.height else {
            renderSafety.resourcesUnavailable("Precalculation extent unavailable");return
        }
        // Each in-flight frame owns its shared CPU inputs. No semaphore wait on main.''')
    s=replace(s,'        guard let encoder=command.makeComputeCommandEncoder() else {renderSafety.resourcesUnavailable("Background compute encoder allocation");return}','''        guard let precalculation,
              let cache=precalculation.encode(command:command,pipeline:gpu.preparation,
                  uniformBuffer:uniformBuffer,historyBuffer:historyBuffer,historyCount:history.count,
                  scale:scale,slot:activeSlot) else {
            renderSafety.resourcesUnavailable("Precalculation encoding unavailable");return
        }
        guard let encoder=command.makeComputeCommandEncoder() else {renderSafety.resourcesUnavailable("Background compute encoder allocation");return}''')
    s=replace(s,'encoder.setBuffer(historyBuffer,offset:0,index:1)','encoder.setBuffer(cache,offset:0,index:1)')
    return s.encode()

def mask_source(reduce_domain=False):
    source=(SDK/'Sources/GradientsKit/GradientMaskRenderer.swift').read_bytes()
    if reduce_domain:
        expansion=b'\n            .composited(over:CIImage(color:.clear).cropped(to:fullExtent))'
        if source.count(expansion)!=1:
            raise ValueError('Unexpected mask source domain')
        source=source.replace(expansion,b'')
    return source

def outputs(mode,mask_domain=False,shared_background=False):
    optimized=mode=='precalc'
    if (mask_domain or shared_background) and not optimized:
        raise ValueError('Reference must retain the approved mask graph')
    return {
        'GradientsUIKit.metal':compose_shared_candidate(ROOT) if shared_background else compose_candidate(ROOT) if optimized else compose_sdk(),
        'GradientYellowColors.swift':swift_source(load(SDK)).encode(),
        'GradientGPU.swift':gpu_source() if optimized else (SDK/'Sources/GradientsKit/GradientGPU.swift').read_bytes(),
        'GradientViewController.swift':controller_source() if optimized else (SDK/'Sources/GradientsKit/GradientViewController.swift').read_bytes(),
        'GradientMaskRenderer.swift':mask_source(mask_domain),
        'GradientPrecalculationBuffers.swift':(HERE/'GradientPrecalculationBuffers.swift').read_bytes() if optimized else b'// Reference build: no precalculation resources.\n',
    }

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--mode',choices=['reference','precalc'],required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--mask-domain',action='store_true',help='Experimental CI source extent; no SDK input edits')
    p.add_argument('--shared-background',action='store_true',help='Experimental single geometry/MAIN readout')
    a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=True)
    generated=outputs(a.mode,a.mask_domain,a.shared_background)
    for name,data in generated.items():
        path=a.output/name
        if not path.exists() or path.read_bytes()!=data:path.write_bytes(data)
    manifest={'mode':a.mode,'mask_domain':a.mask_domain,'shared_background':a.shared_background,'files':{n:hashlib.sha256(d).hexdigest() for n,d in generated.items()}}
    (a.output/'SourceManifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('Prepared isolated '+a.mode+' sources in '+str(a.output))
