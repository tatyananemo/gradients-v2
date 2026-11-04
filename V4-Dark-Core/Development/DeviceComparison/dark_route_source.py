"""Build-only Dark MAIN/CONTACT specialization; original Light/fallback preserved."""
def shader(data:bytes)->bytes:
    s=data.decode()
    from pathlib import Path
    from source_colors import scope,load
    colours=load(Path(__file__).resolve().parents[2]/'GradientsKit-V4')['dark']
    def rgb(role):return 'float3('+','.join(colours[role])+')'
    # Actual Dark substrate is darkBase=(0,0,0) in BlueGeometryTail.inc.
    profile="""            // Same spatial basis as original Light; only the theme's colour anchors differ.
            float3 outerOrange=mix(DEEP,MID,brighter);
            float orange=exp(-pow((heat-0.85)/0.90,2.0))*(1.0-exp(-heat*2.0))*0.75;
            cream=smoothstep(1.55,3.50,heat)*0.75;
            float accumulatedHeat=max(heat-2.0,0.0);
            exposure=1.0-exp(-accumulatedHeat*accumulatedHeat/2.8);
            // Single review variant: lift the existing broad gold contribution, not its coverage.
            float3 warmTheme=mix(outerOrange,mix(HOT,ACCENT,brighter)+ACCENT*0.15,orange);
            warmTheme=mix(warmTheme,outerOrange*(1.0-0.82),cream);
            trailColor=mix(warmTheme,outerOrange*(1.0-0.94),exposure);"""
    for key,role in [('HOT','trailHot'),('ACCENT','trailAccent'),('MID','trailMid'),('DEEP','trailDeep')]:profile=profile.replace(key,rgb(role))
    oldPalette="""            warm = mix(warm, mix(yellowHotColor.rgb, white, 0.82), cream);
            trailColor = mix(warm, mix(yellowHotColor.rgb, white, 0.94), exposure);"""
    def finish(base):
        return """        BASE=BASE*touchTransmission+touchEmission;
        return half4(half3(clamp(BASE,0.0,1.0)),1.0);""".replace('BASE',base)
    for name in ('YellowDarkMAIN','YellowDarkContact'):
        a,b=scope(s,s.index('namespace '+name+' {'));body=s[a:b]
        declaration='    float3 result=mainBase;'
        assert body.count(declaration)==1 and body.count(oldPalette)==1,name
        body=body.replace(declaration,declaration+'\n    float touchTransmission=1.0;\n    float3 touchEmission=float3(0.0);')
        body=body.replace(oldPalette,profile)
        x,y=scope(body,body.index('        if (darkTheme > 0.5) {',body.index('    float counterProtection=physical.z;')))
        body=body[:x]+"""        if (darkTheme > 0.5) {
            // Full Light-style affine composition: pigment plus theme-dual neutral screen.
            // No independent core mask and no max/union of coverage with a black centre.
            float pigmentOpacity=opacity*(0.76+0.24*exposure);
            float neutralTransmission=1.0-exposure*opacity*0.42;
            touchTransmission=(1.0-pigmentOpacity)*neutralTransmission;
            touchEmission=trailColor*pigmentOpacity*neutralTransmission;
        }"""+body[y:]
        if name=='YellowDarkMAIN':
            old='        return half4(half3(clamp(result,0.0,1.0)),1.0);'
            assert body.count(old)==1;body=body.replace(old,finish('result'))
        else:
            early='        if(W<=0.0)return half4(half3(result),1.0);'
            old='        return half4(half3(clamp(composite+trailDelta,0.0,1.0)),1.0);'
            assert body.count(early)==1 and body.count(old)==1
            body=body.replace(early,'        float3 completed=result;\n        if(W>0.0) {')
            body=body.replace(old,'        completed=composite+trailDelta;\n        }\n'+finish('completed'))
        s=s[:a]+body+s[b:]
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
