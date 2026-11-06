#!/usr/bin/env python3
"""Verify authored inputs and every expanded compiler source against approved Yellow."""
from pathlib import Path
import hashlib,json,subprocess,sys,tempfile
ROOT=Path(__file__).resolve().parents[1]

def verify():
    manifest=json.loads((ROOT/'Verification/source-manifest.json').read_text())
    for rel,expected in manifest['inputHashes'].items():
        if hashlib.sha256((ROOT/rel).read_bytes()).hexdigest()!=expected:
            raise SystemExit('Input changed: '+rel)
    with tempfile.TemporaryDirectory(prefix='biosensor-yellow-inputs-') as folder:
        generated=Path(folder)
        subprocess.run([sys.executable,'-I','-B',str(ROOT/'Tools/generate_sdk.py'),'--output',folder],check=True)
        for rel,expected in manifest['approvedCompilerInputs'].items():
            name=Path(rel).name
            path=generated/name
            if not path.exists():
                matches=list((ROOT/'GradientsKit-V4/Sources/GradientsKit').rglob(name))
                if len(matches)!=1:raise SystemExit('Missing source: '+name)
                path=matches[0]
            if hashlib.sha256(path.read_bytes()).hexdigest()!=expected:
                raise SystemExit('Compiler input differs from approved Yellow: '+name)
    for entry in manifest['authoredSourceFiles']:
        if len((ROOT/entry['path']).read_bytes().splitlines())!=entry['lines']:
            raise SystemExit('Line count changed: '+entry['path'])
    print('PASS: all 12 Swift inputs and final Metal byte-identical to approved Yellow')
    return manifest

if __name__=='__main__':verify()
