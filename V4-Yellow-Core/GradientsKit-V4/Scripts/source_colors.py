"""Build-time Yellow RGB binding. No runtime config, uniforms or specialization.

Canonical ShaderSources are immutable literal oracles. Default bindings reproduce
that compiler input byte for byte. A changed shared color helper is instantiated
only for its owning theme, with the same signature, types and arithmetic.
"""
from fractions import Fraction
import json
import re

GLOBAL_ROLES={'yellowDeepColor':'mainDeep','yellowMidColor':'mainMid','yellowHotColor':'mainHot','yellowLightAccent':'mainAccent'}
RGB_ROLES=tuple(GLOBAL_ROLES.values())+('contactArc','contactCore','contactHueBright','contactHueShade','contactDiffuseSource','contactDiffusePeak','primarySource','primaryPeak','haloWarm','haloWhite','trailDeep','trailMid','trailHot','trailAccent','trailWhite','counterTint')
NUMBER=r'(?:\d+\.\d*|\.\d+)(?:[eE][+-]?\d+)?'
EXPRESSION=re.compile(r'\s*'+NUMBER+r'(?:\s*/\s*'+NUMBER+r')?\s*\Z')


def value(expr):
    if not isinstance(expr,str) or not EXPRESSION.fullmatch(expr):
        raise ValueError('Expected a decimal literal or decimal-literal division: '+repr(expr))
    terms=expr.split('/')
    try:result=Fraction(terms[0].strip())/(Fraction(terms[1].strip()) if len(terms)==2 else 1)
    except ZeroDivisionError:raise ValueError('Zero color denominator: '+expr) from None
    if not 0<=result<=1:raise ValueError('Color component outside 0...1: '+expr)
    return result


def load(root):
    data=json.loads((root/'Configuration/YellowColors.json').read_text())
    if set(data)!={'_instructions','dark','light'}:raise ValueError('Unknown color configuration section')
    for theme,extra in [('dark',('maskTint','maskBase')),('light',('captionTint',))]:
        excluded={'primarySource','primaryPeak','haloWarm','haloWhite'} if theme=='dark' else {'contactHueBright','contactHueShade','contactDiffuseSource','contactDiffusePeak'}
        expected=(set(RGB_ROLES)-excluded)|set(extra)|({'transmissionRed'} if theme=='light' else set())
        if set(data[theme])!=expected:raise ValueError('Unknown/missing '+theme+' color role')
        for role,rgb in data[theme].items():
            if role=='transmissionRed':value(rgb);continue
            if not isinstance(rgb,list) or len(rgb)!=3:raise ValueError('Expected RGB triple: '+role)
            for component in rgb:value(component)
    return data


def scope(source,start):
    # Ignore comments without changing character offsets.
    clean=re.sub(r'//[^\n]*|/\*[\s\S]*?\*/',lambda m:' '*len(m[0]),source)
    opening=clean.index('{',start);end=opening+1;depth=1
    while depth:
        depth+=(clean[end]=='{')-(clean[end]=='}');end+=1
    return start,end


def function(source,name):
    match=re.search(r'(?m)^(?:float3|half4) '+re.escape(name)+r'\([^;{}]*\)\s*\{',source)
    if not match:raise ValueError('Missing color helper '+name)
    a,b=scope(source,match.start());return source[a:b]


class Binder:
    def __init__(self,config,blue):
        self.config=config;self.slots={}
        self.globals={name:re.search(r'constant float[34] '+name+r' = float[34]\(([^;]+)\);',blue)[1].split(',')[:3] for name in GLOBAL_ROLES}

    def component(self,text):
        m=re.fullmatch(r'(yellow\w+)\.([rgb])',text.strip())
        return self.globals[m[1]]['rgb'.index(m[2])] if m else text.strip()

    def rgb(self,expr):
        if expr in self.globals:return self.globals[expr]
        if expr.endswith('.rgb') and expr[:-4] in self.globals:return self.globals[expr[:-4]]
        m=re.fullmatch(r'float3\((.*)\)',expr)
        if not m:raise ValueError('Unreviewed RGB operand '+expr)
        parts=m[1].split(',');return [self.component(p) for p in (parts*3 if len(parts)==1 else parts)]

    def slot(self,role,original,channel=None):
        configured=self.config[role]
        if channel is None:
            original_values=self.rgb(original)
            replacement=original if all(value(a)==value(b) for a,b in zip(configured,original_values)) else 'float3('+','.join(configured)+')'
        else:
            new=configured if isinstance(configured,str) else configured[channel]
            old=self.component(original)
            replacement=original if value(new)==value(old) else '('+new+')'
        marker='__V4_RGB_'+str(len(self.slots))+'__';self.slots[marker]=replacement;return marker

    def globals_in(self,text,trail=False):
        def replace(m):
            name,suffix=m[1],m[2];role=GLOBAL_ROLES[name]
            if trail:role={'mainDeep':'trailDeep','mainMid':'trailMid','mainHot':'trailHot','mainAccent':'trailAccent'}[role]
            if suffix in ('r','g','b'):return self.slot(role,m[0],channel='rgb'.index(suffix))
            if suffix=='rgb' or name=='yellowLightAccent':return self.slot(role,m[0])
            raise ValueError('Unreviewed Yellow constant use: '+m[0])
        return re.sub(r'\b(yellowDeepColor|yellowMidColor|yellowHotColor|yellowLightAccent)(?:\.(rgb|r|g|b))?\b',replace,text)

    def resolve(self,text):
        for marker,expr in self.slots.items():text=text.replace(marker,expr)
        return text

    def bind(self,text):
        # The trail block has independent pigments, not accidental MAIN aliases.
        start=text.find('    float counterProtection=physical.z;')
        if start>=0:
            end=text.index('    float3 trailDelta=result-mainBase;',start)
            trail=text[start:end].replace('white=float3(1.0)','white='+self.slot('trailWhite','float3(1.0)'))
            text=text[:start]+self.globals_in(trail,trail=True)+text[end:]
        # White in hue algebra, gamma, bounds and Blue references is NOT a color setting.
        text=text.replace('mainBase=mix(mainBase,float3(1.0),','mainBase=mix(mainBase,'+self.slot('counterTint','float3(1.0)')+',')
        for operand,role in [('float3(1.0,140.0/255.0,0.0)','contactArc'),('float3(1.0,221.0/255.0,45.0/255.0)','contactCore'),('float3(1.0,0.82,0.0)','contactHueBright'),('float3(1.0,0.72,0.0)','contactHueShade'),('float3(1.0,0.48,0.14)','contactDiffuseSource'),('float3(1.0,1.0,0.24)','contactDiffusePeak'),('float3(1.0,1.0,.24)','contactDiffusePeak'),('float3(yellowLightAccent.r,yellowLightAccent.g,0.0)','primarySource'),('float3(1.0,1.0,0.0)','primaryPeak')]:
            if operand in text:text=text.replace(operand,self.slot(role,operand))
        if 'primary.g=mix(yellowMidColor.g,1.0,primaryEnergy)' in text:text=text.replace('primary.g=mix(yellowMidColor.g,1.0,primaryEnergy)','primary.g=mix(yellowMidColor.g,'+self.slot('primaryPeak','1.0',channel=1)+',primaryEnergy)')
        if 'return float3(1.0,mix(yellowMidColor.g,' in text:text=text.replace('return float3(1.0,mix(yellowMidColor.g,','return float3('+self.slot('transmissionRed','1.0',channel=0)+',mix(yellowMidColor.g,')
        if 'mix(yellowHotColor.rgb,float3(1.0),0.82)' in text:text=text.replace('mix(yellowHotColor.rgb,float3(1.0),0.82)','mix('+self.slot('haloWarm','yellowHotColor.rgb')+','+self.slot('haloWhite','float3(1.0)')+',0.82)')
        return self.resolve(self.globals_in(text))


def bind_metal(source,root,config=None):
    config=load(root) if config is None else config
    shared_start=source.index('namespace YellowShared {');shared_end=source.index('} // namespace YellowShared',shared_start)
    shared=source[shared_start:shared_end]
    blue=source[:shared_start]
    # Only these four shared functions contain Yellow RGB operands. Geometry,
    # wave profiles, HSV algebra and Blue energy references stay shared verbatim.
    names=('yellowReviewDarkPalette','yellowReviewTransmission','yellowReviewLightSource','yellowReviewLightPeak')
    helpers={name:function(shared,name) for name in names}
    historical=function(blue,'qaHistoricalYellowDarkWave')
    for theme in ('dark','light'):
        binder=Binder(config[theme],blue)
        changed={}
        modules=''.join(source[a:b] for a,b in [scope(source,source.index('namespace Yellow'+theme.title()+kind+' {')) for kind in ('MAIN','Contact')])
        for name,body in helpers.items():
            # Light supplies its own source/peak; only instantiate referenced helpers.
            if 'using YellowShared::'+name+';' not in modules:continue
            bound=binder.bind(body)
            if bound!=body:changed[name]=bound
        helper_namespace='Yellow'+theme.title()+'Colors'
        for module in ('MAIN','Contact'):
            name='Yellow'+theme.title()+module
            start,end=scope(source,source.index('namespace '+name+' {'))
            block=source[start:end];original=block
            block=binder.bind(block)
            for helper in changed:
                block=block.replace('using YellowShared::'+helper+';','using '+helper_namespace+'::'+helper+';')
            if 'qaHistoricalYellowDarkWave(' in original:
                local=binder.bind(historical)
                if local!=historical:block=block.replace('namespace '+name+' {\n','namespace '+name+' {\n'+local+'\n')
            source=source[:start]+block+source[end:]
        if changed:
            start=source.index('namespace Yellow'+theme.title()+'MAIN {')
            source=source[:start]+'namespace '+helper_namespace+' {\n'+'\n\n'.join(changed.values())+'\n}\n'+source[start:]
    return source


def swift_source(config):
    # Exact source expressions reach CGFloat directly: no Float/Double upload,
    # JSON parsing, color conversion or dynamic palette object in the renderer.
    lines=['// Generated at build time from Configuration/YellowColors.json.','import CoreGraphics','enum GradientYellowColors {']
    for name,rgb in [('darkMaskTint',config['dark']['maskTint']),('darkMaskBase',config['dark']['maskBase'])]:
        lines.append('    static let '+name+':[CGFloat]=['+','.join(rgb)+']')
    lines.append('    static let lightCaptionTint:(CGFloat,CGFloat,CGFloat)=('+','.join(config['light']['captionTint'])+')')
    return '\n'.join(lines+['}',''])
