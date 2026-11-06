#!/usr/bin/env python3
"""Build only the compact SDK, unsigned for generic iOS; verify approved metallib."""
from pathlib import Path
import argparse,hashlib,json,subprocess
from verify_sources import ROOT,verify
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--derived-data',required=True,type=Path)
args=parser.parse_args();target=args.derived_data.resolve()
if target==ROOT or ROOT in target.parents:raise SystemExit('Use DerivedData outside the source folder')
manifest=verify()
subprocess.run(['xcodebuild','-project',str(ROOT/'BiosensorYellowSDK.xcodeproj'),'-scheme','Biosensor Yellow SDK',
    '-configuration','Release','-destination','generic/platform=iOS','-derivedDataPath',str(target),
    'CODE_SIGNING_ALLOWED=NO','build'],cwd=ROOT,check=True)
framework=target/'Build/Products/Release-iphoneos/GradientsKit.framework'
shader=framework/'default.metallib';data=shader.read_bytes()
expected=manifest['approvedMetallib']
if len(data)!=expected['bytes'] or hashlib.sha256(data).hexdigest()!=expected['sha256']:
    raise SystemExit('Release metallib differs; do not replace the approved baseline')
report={'releaseBuildSucceeded':True,'metallibBytes':len(data),'metallibSHA256':hashlib.sha256(data).hexdigest(),
    'approvedMetallibIdentical':True,'allSwiftCompilerInputsIdentical':True,'deviceOrSimulatorLaunched':False}
(target/'verification-result.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
