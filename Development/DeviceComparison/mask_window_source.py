"""Experimental lossless mask-window storage; input raster/blur stay unchanged."""
def renderer(data:bytes)->bytes:
    s=data.decode()
    mark='    func waitUntilScheduled()'
    if s.count(mark)!=1:raise ValueError('Unexpected mask renderer')
    s=s.replace(mark,'    var sampleOrigins:SIMD4<Float> {SIMD4(Float(workers[0].outputRegion.minY),Float(workers[1].outputRegion.minY),Float(workers[2].outputRegion.minY),0)}\n'+mark,1)
    s=s.replace('        var output:MTLTexture?', '        var output:MTLTexture?\n        var outputRegion:CGRect = .zero\n        private var regionKey:SIMD4<Double>?\n        private var fixedRegion:CGRect = .zero')
    old='let blurred=ci.applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius*scale*breath]).cropped(to:fullExtent)'
    if s.count(old)!=1:raise ValueError('Unexpected Gaussian graph')
    new='''let filtered=ci.applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius*scale*breath])
        let blurred=filtered.cropped(to:fullExtent)
        let flip=CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:fullExtent.height)
        let key=SIMD4<Double>(Double(fullWidth),Double(fullHeight),Double(counter.midY),Double(scale))
        if regionKey != key {
            // All three workers use the same conservative band. No per-frame
            // texture reallocations: include maximum breath, drift and blur.
            let maxBlur=image.applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:42*scale*1.025]).extent
            let padX=maxBlur.minX.isFinite ? max(0,-maxBlur.minX):CGFloat(fullWidth)
            let padY=maxBlur.minY.isFinite ? max(0,-maxBlur.minY):CGFloat(fullHeight)
            let low=Int(floor((counter.midY-18-8)*scale-CGFloat(rows)/2))
            let high=Int(floor((counter.midY-18+8)*scale-CGFloat(rows)/2))
            let lo=min(max(low,0),fullHeight-rows),hi=min(max(high,0),fullHeight-rows)
            let source=CGRect(x:0,y:fullHeight-hi-rows,width:fullWidth,height:rows+hi-lo)
            let bounds=source.insetBy(dx:-padX,dy:-padY).applying(flip).insetBy(dx:-2,dy:-2).integral.intersection(fullExtent)
            fixedRegion=bounds.isEmpty || bounds.isInfinite ? fullExtent:bounds
            regionKey=key
        }
        let required=filtered.extent.applying(flip).intersection(fullExtent)
        if !fixedRegion.contains(required) {fixedRegion=fullExtent}
        let region=fixedRegion
        let target=CGRect(origin:.zero,size:region.size)'''
    s=s.replace(old,new)
    s=s.replace('pixelFormat:.rgba16Float,width:fullWidth,height:fullHeight','pixelFormat:.rgba16Float,width:Int(region.width),height:Int(region.height)')
    s=s.replace('cached.width==fullWidth,cached.height==fullHeight','cached.width==Int(region.width),cached.height==Int(region.height)')
    s=s.replace('self.ci.render(oriented,to:texture,commandBuffer:command,bounds:fullExtent,colorSpace:cs)','self.ci.render(oriented.transformed(by:CGAffineTransform(translationX:-region.minX,y:-region.minY)),to:texture,commandBuffer:command,bounds:target,colorSpace:cs)')
    s=s.replace('command.commit();lastCommand=command','command.commit();lastCommand=command;outputRegion=region')
    return s.encode()

def shader(data:bytes)->bytes:
    s=data.decode();a=s.index('fragment half4 prototypeComposite(');tail=s[a:]
    tail=tail.replace('constant float4 &params [[buffer(1)]])','constant float4 &params [[buffer(1)]],constant float4 &maskOrigins [[buffer(2)]])',1)
    x=tail.index('  float keep=');y=tail.index('\n }\n return half4(c);',x);body=tail[x:y]
    old='  float4 a=float4(m0.sample(s,uv))*keep,b=float4(m1.sample(s,uv))*keep,d=float4(m2.sample(s,uv))*keep;'
    if body.count(old)!=1:raise ValueError('Unexpected mask composition')
    body=body.replace(old,'''  float3 v=(float3(in.position.y)-maskOrigins.xyz)/heights;
  float4 a=covered.x ? float4(m0.sample(s,float2(uv.x,v.x)))*keep:float4(0);
  float4 b=covered.y ? float4(m1.sample(s,float2(uv.x,v.y)))*keep:float4(0);
  float4 d=covered.z ? float4(m2.sample(s,float2(uv.x,v.z)))*keep:float4(0);''')
    body='  float3 heights=float3(m0.get_height(),m1.get_height(),m2.get_height());\n  bool3 covered=(float3(in.position.y)>=maskOrigins.xyz) & (float3(in.position.y)<maskOrigins.xyz+heights);\n  if(any(covered)) {\n'+body+'\n  }'
    return (s[:a]+tail[:x]+body+tail[y:]).encode()

def controller(data:bytes)->bytes:
    s=data.decode();old='            enc.setFragmentTexture(input,index:0)'
    if s.count(old)!=1:raise ValueError('Unexpected compositor binding')
    return s.replace(old,old+'\n            var origins=maskRenderer?.sampleOrigins ?? .zero\n            enc.setFragmentBytes(&origins,length:16,index:2)').encode()
