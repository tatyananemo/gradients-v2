#!/usr/bin/env python3
"""Build SDK + Demo unsigned for generic iOS; never install or launch anything."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
from verify_delivery import ROOT,verify

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--derived-data',required=True,type=Path)
p.add_argument('--configuration',choices=['OptimizedRelease','OptimizedDebug'],default='OptimizedRelease')
a=p.parse_args()
out=a.derived_data.resolve()
if out==ROOT or ROOT in out.parents:
    raise SystemExit('Choose a DerivedData folder outside the source checkout')
manifest=verify()
command=['xcodebuild','-project',str(ROOT/'Development/DeviceComparison/V4DeviceComparison.xcodeproj'),
    '-scheme','V4 Optimized','-configuration',a.configuration,'-destination','generic/platform=iOS',
    '-derivedDataPath',str(out),'CODE_SIGNING_ALLOWED=NO','build']
subprocess.run(command,cwd=ROOT,check=True)
products=out/'Build/Products'/(a.configuration+'-iphoneos')
shader=products/'GradientsKit.framework/default.metallib'
embedded=products/'GradientsV4Comparison.app/Frameworks/GradientsKit.framework/default.metallib'
data=shader.read_bytes();sha=hashlib.sha256(data).hexdigest()
if embedded.read_bytes()!=data:raise SystemExit('Embedded SDK metallib differs')
if a.configuration=='OptimizedRelease':
    if len(data)>manifest['releaseMetallib']['limitBytes']:raise SystemExit('Release shader exceeds 500000 bytes')
    if sha!=manifest['releaseMetallib']['sha256']:raise SystemExit('Release metallib changed; investigate toolchain/input flags; do not update goldens')
report={'configuration':a.configuration,'shaderBytes':len(data),'shaderSHA256':sha,'embeddedIdentical':True,'deviceOrSimulatorLaunched':False}
(out/'delivery-build-result.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
