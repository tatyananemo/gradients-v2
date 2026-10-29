#!/usr/bin/env python3
"""Prepare and compile native Mac-only experiments. Never launches any application."""
import argparse,json,shutil,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'Development/DeviceComparison'))
sys.path.insert(0,str(HERE))
from prepare_sources import outputs,mask_source
from idle_cache_source import compose

def local_mask_source():
    s=(ROOT/'GradientsKit-V4/Sources/GradientsKit/GradientMaskRenderer.swift').read_text().replace('GradientMaskRenderer','LocalMaskRenderer')
    s=s.replace('        var output:MTLTexture?', '''        private var localKey:String?
            private var localImage:CIImage?
            var output:MTLTexture?''')
    a=s.index('        // Cached validation contexts');b=s.index('        let rasterEnd=',a)
    s=s[:a]+'''        // Test-only cache of the unanimated source. Never caches the animated mask.
            // Rebuilds on any progress, colour, raster extent or scale change.
            let key="\\(p):\\(yellow):\\(fullWidth):\\(rows):\\(scale)"
            if localKey != key || localImage == nil {
                guard let ctx=CGContext(data:nil,width:fullWidth,height:rows,bitsPerComponent:8,bytesPerRow:0,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return nil}
                ctx.translateBy(x:CGFloat(fullWidth)/2,y:CGFloat(rows)/2)
                ctx.scaleBy(x:scale,y:-scale)
                let ellipse=CGRect(x:-w[index]/2,y:-h[index]/2,width:w[index],height:h[index])
                ctx.addEllipse(in:ellipse);ctx.clip()
                if index==2 {ctx.setFillColor(color(tint,0.22));ctx.fill(ellipse)}
                else {
                    let colors:[CGColor] = index==0 ? [color(black,0.86),color(black,0.72+flow*0.10),color(tint,0.34+p*0.12),color(black,0)]:[color(tint,0.46),color(black,0.46),color(black,0)]
                    guard let gradient=CGGradient(colorsSpace:cs,colors:colors as CFArray,locations:nil) else {return nil}
                    ctx.drawRadialGradient(gradient,startCenter:.zero,startRadius:index==0 ? 12:2,endCenter:.zero,endRadius:index==0 ? 136:106,options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
                }
                guard let snapshot=ctx.makeImage() else{return nil}
                localImage=CIImage(cgImage:snapshot);localKey=key
                metrics?.add("localMaskSourceMiss",1)
            } else {metrics?.add("localMaskSourceHit",1)}
    ''' +s[b:]
    a=s.index('        let image:CIImage');b=s.index('        let radius:CGFloat=',a)
    s=s[:a]+'''        guard let localImage else {return nil}
            let ax=breath*sx[index],ay=breath*sy[index]
            let transform=CGAffineTransform(a:ax,b:0,c:0,d:ay,
                tx:(counter.midX+breath*ox[index])*scale-ax*CGFloat(fullWidth)/2,
                ty:CGFloat(fullHeight)-(counter.midY-18+breath*oy[index])*scale-ay*CGFloat(rows)/2)
            let ci=localImage.transformed(by:transform)
                .composited(over:CIImage(color:.clear).cropped(to:fullExtent))
    ''' +s[b:]
    s=s.replace('        source?.command=command','')
    s=s.replace('        if source == nil {context=nil}','')
    return s

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--cases',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
    ref,pre=outputs('reference'),outputs('precalc')
    (out/'candidate936.metal').write_bytes(ref['GradientsUIKit.metal'])
    (out/'precalculated.metal').write_bytes(pre['GradientsUIKit.metal'])
    (out/'idle-cache.metal').write_bytes(compose())
    (out/'colors.swift').write_bytes(ref['GradientYellowColors.swift'])
    (out/'DomainMaskRenderer.swift').write_bytes(mask_source(True).replace(b'GradientMaskRenderer',b'DomainMaskRenderer'))
    (out/'LocalMaskRenderer.swift').write_text(local_mask_source())
    cases=json.loads(a.cases.read_text());assert len(cases)==494
    (out/'cases.json').write_text(json.dumps(cases))
    bench=[]
    for rnd in range(7):
        for i in range(16):
            f=next(x for x in cases if x['name']=='extra-dark-p2-t3').copy();f['uniforms']=f['uniforms'].copy();t=(i+0.5)/16*3
            f['uniforms'][10]=3+rnd*3+t;f['uniforms'][26]=rnd*3+t
            f['name']=f'bench-round{rnd}-{i}';bench.append(f)
    (out/'benchmark.json').write_text(json.dumps(bench))
    (out/'main.swift').write_bytes((HERE/'CompareMasks.swift').read_bytes())
    common=[ROOT/'GradientsKit-V4/Sources/GradientsKit'/n for n in ['GradientRenderSafety.swift','GradientMaskRenderer.swift','GradientPerformanceMetrics.swift']]
    subprocess.run(['xcrun','swiftc','-O','-module-cache-path',str(out/'ModuleCache'),*map(str,common),str(out/'DomainMaskRenderer.swift'),str(out/'LocalMaskRenderer.swift'),str(out/'colors.swift'),str(out/'main.swift'),'-o',str(out/'compare')],check=True)
    raw=out/'raw-src';raw.mkdir();(raw/'main.swift').write_bytes((HERE/'CompareRawMasks.swift').read_bytes())
    subprocess.run(['xcrun','swiftc','-O','-module-cache-path',str(out/'ModuleCache'),*map(str,common),str(out/'DomainMaskRenderer.swift'),str(out/'colors.swift'),str(raw/'main.swift'),'-o',str(out/'raw-masks')],check=True)
    print('Prepared native Mac hosts only; run the commands documented in README explicitly.')
