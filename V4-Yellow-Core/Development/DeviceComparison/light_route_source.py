"""Build-only Light route specialization. Dark routes and all colour math stay unchanged."""

def shader(data:bytes)->bytes:
    s=data.decode()
    # Existing constant 102: 0=fallback, 1/2=Dark MAIN/CONTACT; add 3/4=Light.
    old='(v4DarkRouteValue==0u ? u[23]:1.0)'
    new='(v4DarkRouteValue==0u ? u[23]:(v4DarkRouteValue<=2u ? 1.0:0.0))'
    assert s.count(old)==2
    s=s.replace(old,new)
    old='(v4DarkRouteValue==1u ? 0.0:(v4DarkRouteValue==2u ? 1.0:u[25]))'
    new='((v4DarkRouteValue==1u || v4DarkRouteValue==3u) ? 0.0:((v4DarkRouteValue==2u || v4DarkRouteValue==4u) ? 1.0:u[25]))'
    assert s.count(old)==2
    return s.replace(old,new).encode()

def gpu(data:bytes)->bytes:
    s=data.decode()
    old='    let darkMain:MTLComputePipelineState,darkContact:MTLComputePipelineState'
    assert s.count(old)==1
    s=s.replace(old,old+'\n    let lightMain:MTLComputePipelineState,lightContact:MTLComputePipelineState')
    old='        darkContact=try device.makeComputePipelineState(function:function("prototypeComputeBackground",mode:3,route:2))'
    assert s.count(old)==1
    return s.replace(old,old+'''
        lightMain=try device.makeComputePipelineState(function:function("prototypeComputeBackground",mode:3,route:3))
        lightContact=try device.makeComputePipelineState(function:function("prototypeComputeBackground",mode:3,route:4))''').encode()

def controller(data:bytes)->bytes:
    s=data.decode()
    old='        else {pipeline=gpu.background}'
    assert s.count(old)==1
    return s.replace(old,'''        else if uniforms[23]==0 && uniforms[24]==3 && uniforms[25]==0 {pipeline=gpu.lightMain}
        else if uniforms[23]==0 && uniforms[24]==3 && uniforms[25]==1 {pipeline=gpu.lightContact}
'''+old).encode()
