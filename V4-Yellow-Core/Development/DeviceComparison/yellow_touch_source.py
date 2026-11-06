"""Restore the exact approved Yellow touch stops, only in Dark MAIN/CONTACT."""
from pathlib import Path


def shader(data:bytes,sdk:Path)->bytes:
    source=data.decode()
    old="""            warm = mix(warm, mix(yellowHotColor.rgb, white, 0.82), cream);
            trailColor = mix(warm, mix(yellowHotColor.rgb, white, 0.94), exposure);"""
    fragment=(sdk/'ShaderSources/Shared/YellowDarkTouchColor.inc').read_text().removesuffix('\n')
    for name,following in [('YellowDarkMAIN','YellowLightMAIN'),('YellowDarkContact','YellowLightContact')]:
        start=source.index('namespace '+name+' {')
        end=source.index('namespace '+following+' {',start)
        body=source[start:end]
        if body.count(old)!=1:
            raise ValueError('Unexpected approved Dark touch source: '+name)
        source=source[:start]+body.replace(old,fragment)+source[end:]
    return source.encode()
