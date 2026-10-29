#!/usr/bin/env python3
"""Verify immutable inputs and regenerate the final compiler input; no GPU/device run."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]

def verify():
    manifest=json.loads((ROOT/'Documentation/source-manifest.json').read_text())
    for name,expected in manifest['unchangedAlgorithmInputs'].items():
        data=(ROOT/name).read_bytes()
        if hashlib.sha256(data).hexdigest()!=expected:
            raise SystemExit('Changed or missing frozen input: '+name)
    for entry in manifest['sourceFiles']:
        if len((ROOT/entry['path']).read_bytes().splitlines())!=entry['lines']:
            raise SystemExit('Source count changed: '+entry['path'])
    with tempfile.TemporaryDirectory(prefix='v4-delivery-inputs-') as folder:
        subprocess.run([sys.executable,'-I','-B',str(ROOT/'Development/DeviceComparison/prepare_sources.py'),
            '--mode','precalc','--mask-domain','--shared-background','--idle-zero-work',
            '--swipe-optimization','--mask-roi','--output',folder],check=True)
        actual=json.loads((Path(folder)/'SourceManifest.json').read_text())
        if actual!=manifest['expectedGeneratedManifest']:
            raise SystemExit('Final generated compiler input differs from '+manifest['sourceCommit'])
    refs=ROOT/'Documentation/References'
    for item in json.loads((refs/'manifest.json').read_text())['images']:
        if hashlib.sha256((refs/item['file']).read_bytes()).hexdigest()!=item['sha256']:
            raise SystemExit('Changed reference: '+item['file'])
    print('PASS: frozen Swift/Metal/overlay inputs, '+str(sum(v['lines'] for v in manifest['totals'].values()))+' source lines, final compiler inputs and reference images')
    return manifest

if __name__=='__main__':verify()
