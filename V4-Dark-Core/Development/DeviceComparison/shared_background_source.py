"""Experimental Combined-only readout reuse; SDK sources stay immutable."""
from pathlib import Path
import re,sys
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Development/DeviceComparison'))
from precalculation_source import compose_candidate as compose_base

def function(source,signature):
    start=source.index(signature);brace=source.index('{',start)
    masked=re.sub(r'/\*.*?\*/|//[^\n]*',lambda m:' '*len(m.group()),source,flags=re.S)
    depth=1;end=brace+1
    while depth:
        depth+=(masked[end]=='{')-(masked[end]=='}');end+=1
    return start,brace,end

def shared_fields():
    source=compose_base().decode()
    start,brace,end=function(source,'half4 liquidSpecBackground(')
    helper=source[start:end]
    split=helper.index('{')
    helper=helper[:split].replace('liquidSpecBackground(','v4BlueAndPhysical(').rstrip()
    assert helper.endswith(')')
    helper=helper[:-1]+', thread float4 &v4Fields) '+source[brace:end]
    marker='    float3 blueDarkReference = darkResult;'
    assert helper.count(marker)==1
    helper=helper.replace(marker,'''    v4Fields=float4(sharedLightField,idleDensity,counterProtection,
        grain*mix(0.0010,0.0035,grainMask)*(1.0-completionBlackout)*darkCanvasReveal);
    if(float(half(idleDensity))<=0.0) return half4(0);
'''+marker)
    source=source[:end]+'\n'+helper+'\n'+source[end:]
    # Only the actual Yellow Dark CONTACT namespace. MAIN/Light stay on old path.
    ns=source.index('namespace YellowDarkContact {');a,b,c=function(source[ns:],'half4 liquidYellowReviewBackground(')
    a+=ns;b+=ns;c+=ns;body=source[a:c]
    marker='    float4 physical=yellowReferenceContactFields('
    x=body.index(marker);y=body.index(';',x)+1
    original=body[x:y]
    args=original[original.index('(')+1:-2]
    assert args.endswith('interactionSegments,interactionFloatCount')
    blue_args=args[:-len('interactionFloatCount')]+'0'
    replacement='''    float4 physical;half4 v4Blue;
    if(themeStrength>0.5) v4Blue=v4BlueAndPhysical('''+blue_args+''',physical);
    else {'''+original.strip()+''' }
'''
    # In Light fallback assign the outer value, never shadow it.
    replacement=replacement.replace('else {float4 physical=','else {physical=')
    body=body[:x]+replacement+body[y:]
    x=body.index('        float3 blueProfile=float3(liquidSpecBackground(');y=body.index(';',x)+1
    body=body[:x]+'        float3 blueProfile=float3(v4Blue.rgb);'+body[y:]
    source=source[:a]+body+source[c:]
    return source.encode()


def reuse_main():
    source=shared_fields().decode()
    a,b,c=function(source,'half4 v4BlueAndPhysical(')
    helper=source[a:c]
    helper=helper.replace(', thread float4 &v4Fields)',', thread float4 &v4Fields,float v4Main)')
    pos=helper.index('    float3 qaVisualMain = darkResult;')
    x,brace,end=function(helper[pos:],'    if (isBluePreset > 0.5 && themeStrength > 0.5)')
    x+=pos;brace+=pos;end+=pos
    inner=helper[brace+1:end-1]
    helper=helper[:brace+1]+'''\n        if(progress<=0.70) {
            qaVisualMain=darkBandCoreColor*v4Main;
            darkResult=qaVisualMain;
        } else {
'''+inner+'\n        }\n'+helper[end-1:]
    source=source[:a]+helper+source[c:]
    ns=source.index('namespace YellowDarkContact {');a,b,c=function(source[ns:],'half4 liquidYellowReviewBackground(');a+=ns;b+=ns;c+=ns
    body=source[a:c]
    decl='    bool dark=themeStrength>0.5;';main='    float M=dark ? yellowReviewDarkMainAtPose(uv,progress,time) : qaMainAtPose(uv,progress,time,false);'
    assert body.count(decl)==1 and body.count(main)==1
    body=body.replace(decl,'').replace(main,'')
    marker='    float4 physical;half4 v4Blue;';body=body.replace(marker,decl+'\n'+main+'\n'+marker)
    assert body.count(',0,physical);')==1
    body=body.replace(',0,physical);',',0,physical,M);')
    source=source[:a]+body+source[c:]
    return source.encode()


def compose_candidate(root=ROOT):
    if Path(root).resolve()!=ROOT.resolve():raise ValueError("Use sibling SDK")
    return reuse_main()
