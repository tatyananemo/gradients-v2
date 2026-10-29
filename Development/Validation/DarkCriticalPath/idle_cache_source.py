"""Mac-only producer/consumer trial. Never alters SDK or device-build sources."""
import sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'Development/DeviceComparison'))
from precalculation_source import compose_candidate

def compose():
    source=compose_candidate().decode()
    signature='float v4CachedIdleWave(float2 position,float2 size,float activity,float time,float waveStrength,device const float *cache)'
    source=source.replace('using namespace metal;','using namespace metal;\n'+signature+';\n',1)
    call='idleWaveDensity(position, size, idleActivity, idleTime, waveStrength)'
    assert source.count(call)==2
    source=source.replace(call,'v4CachedIdleWave(position, size, idleActivity, idleTime, waveStrength,interactionSegments)')
    # Same scalar formulas and original Float32 precision; only invariant scope changes.
    source+='\n'+signature+''' {
    if(!v4CacheAxes) return idleWaveDensity(position,size,activity,time,waveStrength);
    uint width=uint(cache[241]),height=uint(cache[242]);
    uint begin=286+10*width+8*height;
    uint x=uint(position.x*cache[240]),y=uint(position.y*cache[240]);
    uint column=begin+2+5*x;
    float2 safeSize=max(size,float2(1.0));
    float2 p=position/safeSize*float2(375.0,812.0);
    float distanceToArc=p.y-cache[column+1];
    float thickness=cache[begin+1];
    float mainWave=exp(-pow(distanceToArc/thickness,2.0))*cache[column+2];
    float secondWave=exp(-pow((distanceToArc+72.0)/(thickness*1.35),2.0))*cache[column+3]*0.32;
    float halo=cache[begin+2+5*width+y]*cache[column+4]*0.12;
    float energy=clamp(mainWave+secondWave+halo,0.0,1.0)*cache[begin]*clamp(waveStrength,0.3,2.0);
    return clamp(energy*0.84,0.0,0.86);
}
'''
    start=source.index('kernel void prototypePrepareAxes(')
    end=source.index('\n}\n',start)
    extra='''
    if(v4CacheAxes) {
        uint begin=286+10*extent.x+8*extent.y;
        float idleTime=u[26],activity=u[25];
        float2 safeSize=max(float2(u[0],u[1]),float2(1.0));
        float2 p=position/safeSize*float2(375.0,812.0);
        float cycleRaw=fract(idleTime/3.0);
        float cycle=smootherLiquid(cycleRaw);
        float visibility=smoothstep(0.02,0.11,cycleRaw)*(1.0-smoothstep(0.88,1.0,cycleRaw))*smootherLiquid(clamp(activity,0.0,1.0));
        float waveY=mix(-110.0,925.0,cycle);
        float width=mix(72.0,420.0,cycle);
        float thickness=mix(19.0,42.0,cycle);
        if(id==0) {cache[begin]=visibility;cache[begin+1]=thickness;}
        if(id<extent.x) {
            float dx=p.x-187.5;
            uint column=begin+2+5*id;
            cache[column]=dx;
            cache[column+1]=waveY+(dx*dx)/max(width*1.72,1.0);
            cache[column+2]=exp(-pow(dx/width,2.0));
            cache[column+3]=exp(-pow(dx/(width*1.18),2.0));
            cache[column+4]=exp(-pow(dx/max(width*1.18,1.0),2.0));
        }
        if(id<extent.y) cache[begin+2+5*extent.x+id]=exp(-pow((p.y-waveY)/180.0,2.0));
    }'''
    source=source[:end]+extra+source[end:]
    return source.encode()
