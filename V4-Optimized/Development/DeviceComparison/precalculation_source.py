"""Exact source builder for the reviewed axis/frame experiment.

Only used by the isolated device-comparison project. No SDK inputs are edited.
"""
import re
import sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'GradientsKit-V4/Scripts'))
from compose_uikit_metal import compose_sdk

current=compose_sdk().decode()
physical=(ROOT/'GradientsKit-V4/ShaderSources/Shared/PhysicalFields.inc').read_text()
assert current.count(physical)==2

# Cache only raw sin outputs with independently provable frame/X/Y inputs.
# pGlobal, angle, tap-distance and mixed X/Y expressions are deliberately excluded.
groups={'x':[], 'y':[], 'frame':[]}
cursor=0
while True:
    first=physical.find('sin(',cursor)
    if first<0:break
    end=first+4;depth=1
    while depth:
        depth+=(physical[end]=='(')-(physical[end]==')');end+=1
    call=physical[first:end];cursor=end
    tokens=set(re.findall(r'[A-Za-z_]\w*(?:\.[xy])?',call[4:-1]))
    allowed={'time','rise','progress','keyProgress','p.x','p.y','uv.x','uv.y','position.x','position.y'}
    if not tokens<=allowed:continue
    axes={s[-1] for s in tokens if s.endswith(('.x','.y'))}
    if len(axes)>1:continue
    category=next(iter(axes)) if axes else 'frame'
    if call not in groups[category]:groups[category].append(call)
assert [len(groups[k]) for k in ('x','y','frame')]==[10,8,12]

states=[]
for match in re.finditer(r'    LayerState (\w+) = makeState\(',physical):
    end=physical.index(');',match.end())+2
    states.append((match[1],physical[match.start():end]))
assert len(states)==5
frame_start=244;state_start=frame_start+len(groups['frame']);x_start=state_start+6*len(states)
nx,ny=len(groups['x']),len(groups['y'])

changed=physical
only_axes=physical
only_frame=physical
for category,calls in groups.items():
    for index,call in enumerate(calls):
        assert physical.count(call)==1
        if category=='x':
            address=f'{x_start}+{nx}*uint(position.x*interactionSegments[240])+{index}'
            enabled='v4CacheAxes'
        elif category=='y':
            address=f'{x_start}+{nx}*uint(interactionSegments[241])+{ny}*uint(position.y*interactionSegments[240])+{index}'
            enabled='v4CacheAxes'
        else:address=str(frame_start+index);enabled='v4CacheFrame'
        replacement=f'({enabled} ? interactionSegments[{address}] : {call})'
        changed=changed.replace(call,replacement)
        if category=='frame':only_frame=only_frame.replace(call,replacement)
        else:only_axes=only_axes.replace(call,replacement)
for index,(name,declaration) in enumerate(states):
    rhs=declaration[declaration.index('makeState('):-1]
    replacement=f'    LayerState {name} = v4CacheFrame ? v4CachedLayer(interactionSegments,{state_start+index*6}) : {rhs};'
    changed=changed.replace(declaration,replacement)
    only_frame=only_frame.replace(declaration,replacement)
source=current.replace(physical,changed)
flags='''
constant uint v4PrecalcMode [[function_constant(101)]];
constant bool v4CacheAxes=is_function_constant_defined(v4PrecalcMode) ? ((v4PrecalcMode&1u)!=0u):false;
constant bool v4CacheFrame=is_function_constant_defined(v4PrecalcMode) ? ((v4PrecalcMode&2u)!=0u):false;
'''
source=source.replace('using namespace metal;','using namespace metal;\n'+flags,1)
struct_end=source.index('};',source.index('struct LayerState'))+2
loader='''
LayerState v4CachedLayer(device const float *cache,uint offset) {
    LayerState value;
    value.pos=float2(cache[offset],cache[offset+1]);
    value.dim=float2(cache[offset+2],cache[offset+3]);
    value.opacity=cache[offset+4];value.blur=cache[offset+5];
    return value;
}
'''
source=source[:struct_end]+loader+source[struct_end:]
producer='''
kernel void prototypePrepareAxes(constant float *u [[buffer(0)]],device const float *history [[buffer(1)]],
    device float *cache [[buffer(2)]],constant uint4 &extent [[buffer(3)]],uint id [[thread_position_in_grid]]) {
    if(id<extent.w) cache[id]=history[id];
    float scale=as_type<float>(extent.z);
    if(id==0) {cache[240]=scale;cache[241]=float(extent.x);cache[242]=float(extent.y);cache[243]=0.0;}
    float progress=clamp(u[2],0.0,1.0),time=u[10];
    float2 safeSize=float2(max(u[0],1.0),max(u[1],1.0));
    float2 position=(float2(id)+0.5)/scale;
    float2 p=float2(position.x/safeSize.x*375.0,position.y/safeSize.y*812.0);
    float2 uv=position/safeSize;
    float baseRise=progress*(0.42+0.58*progress);
    float smoothRise=smootherLiquid(progress);
    float rise=mix(baseRise,smoothRise,0.34);
    float keyProgress=clamp(progress,0.0,0.82);
'''
producer+='    if(v4CacheAxes && id<extent.x) {\n'
producer+=''.join(f'        cache[{x_start}+{nx}*id+{i}]={call};\n' for i,call in enumerate(groups['x']))
producer+='    }\n    if(v4CacheAxes && id<extent.y) {\n'
producer+=''.join(f'        cache[{x_start}+{nx}*extent.x+{ny}*id+{i}]={call};\n' for i,call in enumerate(groups['y']))
producer+='    }\n    if(v4CacheFrame && id==0) {\n'
producer+=''.join(f'        cache[{frame_start+i}]={call};\n' for i,call in enumerate(groups['frame']))
producer+='\n'.join(declaration for _,declaration in states)+'\n'
for index,(name,_) in enumerate(states):
    for component,field in enumerate(['pos.x','pos.y','dim.x','dim.y','opacity','blur']):
        producer+=f'        cache[{state_start+index*6+component}]={name}.{field};\n'
producer+='    }\n}\n'
source+=producer

def compose_candidate(root=ROOT):
    if Path(root).resolve()!=ROOT.resolve():
        raise ValueError('Use the sibling SDK of this comparison project')
    return source.encode()
