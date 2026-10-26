#!/usr/bin/env python3
"""Check current SDK adapters against unchanged Yellow hashes; no image/report capture."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts"))
from compose_metal import compose

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--reference-run", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--metal", type=Path, help="actual Xcode SDK compiler input to check")
args = parser.parse_args()
base = args.reference_run.resolve()
assert json.loads((base / "result.json").read_text())["passed"]
oracle = json.loads((ROOT / "Validation/reference.json").read_text())["render_sha256"]
cases = [c for c in json.loads((base / "cases.json").read_text()) if c["name"].startswith("yellow-")]
assert len(cases) == 36
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
inputs = out / "cases.json"
inputs.write_text(json.dumps(cases))
source = compose().replace(b"[[ stitchable ]]", b"") + b"\n" + (ROOT / "UIKitComponent/Shaders/GradientAdapters.metal").read_bytes()
if args.metal:
    assert args.metal.read_bytes() == source, "Xcode SDK compiler input differs from maintained sources"
shader = out / "SDK.metal"
shader.write_bytes(source)
binary = out / "adapter-check"
subprocess.run(["xcrun", "swiftc", "-O", str(Path(__file__).with_name("check_adapter.swift")), "-o", str(binary)], check=True)
results = {}
for mode in ["fragment", "compute"]:
    folder = out / mode
    subprocess.run([str(binary), str(shader), str(inputs), str(folder), mode], check=True)
    outputs = list(folder.glob("*.rgba16f"))
    assert len(outputs) == 36
    changed = [p.name for p in outputs if hashlib.sha256(p.read_bytes()).hexdigest() != oracle[p.name]]
    results[mode] = {"compared": len(outputs), "exact": len(outputs) - len(changed), "changed": changed}
    assert not changed, (mode, changed)
(out / "result.json").write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps(results, indent=2))
