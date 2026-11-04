#!/usr/bin/env python3
"""Prepare bounded Mac-only numerical controls; never edit the SDK or oracles.

Use an output of validate_axis_precalculation.py as --trial. This command only
writes temporary sources/manifests. Run compare_background_variants.swift
explicitly against a manifest after compiling that host for native macOS.
"""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'GradientsKit-V4/Scripts'))
from compose_uikit_metal import compose_sdk

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--trial', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
trial = args.trial.resolve()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
base = (trial / 'candidate936.metal').read_text()
assert base.encode() == compose_sdk(), 'Use the unchanged 9368500 SDK'
cached = (trial / 'precalculated.metal').read_text()
start = cached.index('constant uint v4PrecalcMode [[function_constant(101)]];')
end = cached.index('\n', cached.index('constant bool v4CacheFrame=', start))
static = cached[:start] + 'constant bool v4CacheAxes=true;\nconstant bool v4CacheFrame=true;' + cached[end:]

# A source-identical numerical body, with an inactive branch. Compare the
# specialized pipeline with the same constant branch removed at library build.
noop = base.replace('using namespace metal;', 'using namespace metal;\nconstant uint v4DiagnosticMode [[function_constant(101)]];', 1)
start = noop.index('kernel void prototypeComputeBackground(')
brace = noop.index('{', start) + 1
noop = noop[:brace] + '\n if(v4DiagnosticMode==99u)return;' + noop[brace:]
noop_static = noop.replace('constant uint v4DiagnosticMode [[function_constant(101)]];', 'constant uint v4DiagnosticMode=0;')

start = static.index('kernel void prototypePrepareAxes(')
brace = static.index('{', start) + 1
strict = static[:brace] + '\n#pragma clang fp reassociate(off) contract(off)\n' + static[brace:]
materialized = static[:start] + static[start:].replace('float2 p=', 'volatile float2 p=').replace('float2 uv=', 'volatile float2 uv=').replace('float rise=', 'volatile float rise=')
no_fma = static[:brace] + '\n#pragma clang fp contract(off)\n' + static[brace:]
no_reassociate = static[:brace] + '\n#pragma clang fp reassociate(off)\n' + static[brace:]

sources = dict(baseline936=base, precalcSpecialized=cached, precalcStatic=static,
               noopSpecialized=noop, noopStatic=noop_static,
               producerStrict=strict, producerMaterialized=materialized,
               producerNoFMA=no_fma, producerNoReassociate=no_reassociate)
expressions = ['p.x', 'p.y', 'uv.x', 'uv.y', 'rise',
               'p.x * 0.018 + time * 0.50 + rise * 2.0',
               'sin(p.x * 0.018 + time * 0.50 + rise * 2.0)',
               'p.x * 0.041 - time * 0.36 + rise * 4.0',
               'sin(p.x * 0.041 - time * 0.36 + rise * 4.0)', 'clearWave']

# Only this limited probe was transparent on the complete control image.
# Broad probes of all locals/hash intermediates changed the baseline themselves
# and must NOT be used as evidence about the uninstrumented kernel.
for name, text in [('smallBase', base), ('smallStatic', static)]:
    start = text.index('float4 yellowReferenceContactFields(')
    point = text.index('    float bottomClear =', start)
    code = '\n    if(position.x==323.5 && position.y==578.5) {\n'
    code += ''.join(f'        ((device float*)interactionSegments)[{50000+i}]={e};\n'
                    for i, e in enumerate(expressions))
    if name == 'smallStatic':
        code += '        ((device float*)interactionSegments)[50010]=interactionSegments[286+10*uint(position.x*interactionSegments[240])];\n'
        code += '        ((device float*)interactionSegments)[50011]=interactionSegments[286+10*uint(position.x*interactionSegments[240])+1];\n'
    code += '    }\n'
    sources[name] = text[:point] + code + text[point:]
for name, text in sources.items():
    (out / (name + '.metal')).write_text(text)

def variant(name):
    v = dict(name=name, source=str(out / (name + '.metal')), width=8, height=8, zeros=False)
    if name in ['precalcSpecialized', 'precalcStatic', 'producerStrict', 'producerMaterialized', 'producerNoFMA', 'producerNoReassociate', 'smallStatic']:
        v['precalc'] = 3
        v['precalcStatic'] = name != 'precalcSpecialized'
    if name == 'noopSpecialized':
        v['specialize'] = 0
    return v

old = json.loads((trial / 'manifest.json').read_text())
def manifest(name, names, trace=False, timed=False):
    m = dict(variants=[variant(n) for n in names], cases=old['cases'], oracle=old['oracle'],
             output=str(out / (name + '.json')), rounds=3 if timed else 0,
             diagnosticsOnly=not timed, cacheFloatCount=old['cacheFloatCount'])
    if not timed:
        m['controlFrame'] = 'yellow-dark-p30-main'
    if trace:
        m['traceLabels'] = expressions + ['cacheSin0', 'cacheSin1']
    (out / (name + '-manifest.json')).write_text(json.dumps(m, indent=2) + '\n')

manifest('control', ['baseline936', 'precalcSpecialized', 'precalcStatic', 'noopSpecialized', 'noopStatic'])
manifest('trace', ['baseline936', 'precalcStatic', 'smallBase', 'smallStatic'], trace=True)
manifest('fix', ['baseline936', 'precalcStatic', 'producerStrict', 'producerMaterialized'])
manifest('fp', ['baseline936', 'precalcStatic', 'producerNoFMA', 'producerNoReassociate'])
manifest('timed', ['baseline936', 'precalcSpecialized', 'precalcStatic', 'noopSpecialized'], timed=True)
print(out)
