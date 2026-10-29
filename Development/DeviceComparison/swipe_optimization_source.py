"""Experimental build overlay: conservative history tiles and fused distortion.

No SDK inputs change. Original arithmetic and segment accumulation order remain.
"""
from shared_background_source import function

def shader(data: bytes) -> bytes:
    s=data.decode()
    a,b,c=function(s,'float interactionLightField(')
    original=s[a:c]
    start=original.index('        float age =')
    end=original.index('    }\n    return field;',start)
    body=original[start:end]
    # Ascending set bits retain the original float accumulation order.
    replacement='''    if(v4CacheFrame) {
            uint width=uint(segments[241]),height=uint(segments[242]);
            uint columns=(width+15u)/16u;
            uint2 pixel=uint2(uv*float2(width,height));
            pixel=min(pixel,uint2(width-1u,height-1u));
            uint offset=286u+10u*width+8u*height+2u*((pixel.y/16u)*columns+pixel.x/16u);
            uint2 bits=uint2(as_type<uint>(segments[offset]),as_type<uint>(segments[offset+1]));
            for(uint word=0;word<2;word++) {
                uint remaining=bits[word];
                while(remaining!=0u) {
                    uint index=ctz(remaining)+32u*word;
                    remaining&=remaining-1u;
                    int i=int(index)*6;
                    if(i+5>=count)continue;
    '''+body+'''            }
            }
            return field;
        }
    '''
    replacement=replacement.replace('if(v4CacheFrame)', 'if(v4CacheFrame && count>=6)')
    original=original.replace('    for (int i =',replacement+'    for (int i =',1)
    s=s[:a]+original+s[c:]
    # One writer per tile. The existing pass completes before any cache reads.
    # The outward two-pixel guard only admits extra candidates; the original
    # per-pixel rejection and Gaussian remain authoritative.
    producer='''
        uint columns=(extent.x+15u)/16u,rows=(extent.y+15u)/16u;
        if(id<columns*rows) {
            float aspect=max(u[0],1.0)/max(u[1],1.0);
            float2 safeSize=max(float2(u[0],u[1]),float2(1.0));
            uint2 low=uint2((id%columns)*16u,(id/columns)*16u);
            uint2 high=min(low+15u,extent.xy-1u);
            float2 pLo=((float2(low)+0.5)/as_type<float>(extent.z))/safeSize*float2(aspect,1.0);
            float2 pHi=((float2(high)+0.5)/as_type<float>(extent.z))/safeSize*float2(aspect,1.0);
            float2 padding=float2(2.0)/(as_type<float>(extent.z)*safeSize)*float2(aspect,1.0)+0.00001;
            uint2 bits=uint2(0);
            for(uint i=0;i+5u<extent.w;i+=6u) {
                float age=history[i+4u],lift=age*0.055;
                float2 a=float2(history[i]*aspect,history[i+1u]-lift);
                float2 b=float2(history[i+2u]*aspect,history[i+3u]-lift);
                float2 radii=float2(0.057+age*0.007,0.065+age*0.016);
                if(any(pHi+padding<min(a,b)-radii*3.0)||any(pLo-padding>max(a,b)+radii*3.0))continue;
                uint index=i/6u;bits[index/32u]|=1u<<(index%32u);
            }
            uint offset=286u+10u*extent.x+8u*extent.y+2u*id;
            cache[offset]=as_type<float>(bits.x);cache[offset+1u]=as_type<float>(bits.y);
        }
    '''
    producer=producer.replace('if(id<columns*rows)', 'if(extent.w>=6u && id<columns*rows)')
    a=s.index('kernel void prototypePrepareAxes(');b=s.index('    if(id<extent.w)',a)
    s=s[:b]+producer+s[b:]
    a=s.index('fragment half4 prototypeComposite(')
    old=' float4 c=float4(image.sample(s,uv));'
    if s[a:].count(old)!=1:raise ValueError('Unexpected compositor source')
    # Preserve the old distortion half4 rounding before float compositor math.
    new='''
 half4 sampled;
 if(params.w>0.002) {
  float2 p=in.position.xy/params.x;
  float2 source=gradientTrailDistortion(p,float2(u[0],u[1]),float2(u[4],u[5]),float2(u[6],u[7]),params.w,u[10]);
  sampled=image.sample(s,source/float2(u[0],u[1]));
 } else {sampled=image.sample(s,uv);}
 float4 c=float4(sampled);'''
    return (s[:a]+s[a:].replace(old,new.lstrip('\n'),1)).encode()

def buffers(data: bytes) -> bytes:
    text=data.decode()
    text=text.replace('let (bytes,overflowBytes)=count.multipliedReportingOverflow',
        'let tileFloats=2*((width+15)/16)*((height+15)/16)\n        let (allocated,overflowTiles)=count.addingReportingOverflow(tileFloats)\n        let (bytes,overflowBytes)=allocated.multipliedReportingOverflow')
    text=text.replace('!overflowHeader,!overflowBytes','!overflowHeader,!overflowTiles,!overflowBytes')
    text=text.replace('let count=max(width,height,historyCount)',
        'let count=max(width,height,historyCount,historyCount>=6 ? ((width+15)/16)*((height+15)/16):0)')
    return text.encode()

def controller(data: bytes) -> bytes:
    text=data.decode()
    a,b,c=function(text,'        if strength>0.002')
    text=text[:a]+text[c:]
    text=text.replace('var input=backing','let input=backing')
    old='SIMD4<Float>(scale,(backgroundOnly || captionOnly) ? 0:1,(f.dark && !backgroundOnly) ? 1:0,0)'
    if text.count(old)!=1:raise ValueError('Unexpected compositor inputs')
    return text.replace(old,old[:-2]+'strength)').encode()
