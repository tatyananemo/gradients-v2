"""Build-only Dark MAIN/CONTACT specialization; original Light/fallback preserved."""
def shader(data:bytes)->bytes:
    s=data.decode()
    marker='kernel void prototypeComputeBackground('
    assert s.count(marker)==1
    a=s.index(marker);b=s.index('\n}',a)+2
    body=s[a:b]
    for index,value in [(23,'(v4DarkRouteValue==0u ? u[23]:1.0)'),
                        (24,'(v4DarkRouteValue==0u ? u[24]:3.0)'),
                        (25,'(v4DarkRouteValue==1u ? 0.0:(v4DarkRouteValue==2u ? 1.0:u[25]))')]:
        assert body.count(f'u[{index}]')==2
        body=body.replace(f'u[{index}]',value)
    constants='''constant uint v4DarkRoute [[function_constant(102)]];
constant uint v4DarkRouteValue=is_function_constant_defined(v4DarkRoute) ? v4DarkRoute:0u;
'''
    return (s[:a]+constants+body+s[b:]).encode()

def gpu(data:bytes)->bytes:
    s=data.decode()
    s=s.replace('    let preparation:MTLComputePipelineState',
        '    let darkMain:MTLComputePipelineState,darkContact:MTLComputePipelineState\n    let preparation:MTLComputePipelineState')
    old='func function(_ name:String,mode:UInt32?=nil) throws -> MTLFunction {'
    assert s.count(old)==1
    s=s.replace(old,'func function(_ name:String,mode:UInt32?=nil,route:UInt32?=nil) throws -> MTLFunction {')
    old='values.setConstantValue(&mode,type:.uint,index:101)'
    assert s.count(old)==1
    s=s.replace(old,old+'\n                if var route {values.setConstantValue(&route,type:.uint,index:102)}')
    old='background=try device.makeComputePipelineState(function:function("prototypeComputeBackground",mode:3))'
    assert s.count(old)==1
    s=s.replace(old,old+'''
        darkMain=try device.makeComputePipelineState(function:function("prototypeComputeBackground",mode:3,route:1))
        darkContact=try device.makeComputePipelineState(function:function("prototypeComputeBackground",mode:3,route:2))''')
    return s.encode()

def controller(data:bytes)->bytes:
    s=data.decode();old='encoder.setComputePipelineState(gpu.background);'
    assert s.count(old)==1
    new='''let pipeline:MTLComputePipelineState
        if uniforms[23]==1 && uniforms[24]==3 && uniforms[25]==0 {pipeline=gpu.darkMain}
        else if uniforms[23]==1 && uniforms[24]==3 && uniforms[25]==1 {pipeline=gpu.darkContact}
        else {pipeline=gpu.background}
        encoder.setComputePipelineState(pipeline);'''
    return s.replace(old,new).encode()
