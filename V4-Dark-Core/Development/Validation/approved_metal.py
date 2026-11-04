"""Frozen historical control, separate from the Yellow-only shipping library.

Validation already requires local approved Git objects for masks/behavior.
Read the old Blue module from that history; never copy it into SDK sources.
"""
import hashlib
import json
from pathlib import Path
import subprocess

from paths import ROOT, SDK, current_path
BASE = "dc7b9da4820491bc089ccfcebef3b9d0e47914d0"
BLUE = "ShaderSources/ApprovedBlue.metal.source"


def approved_blue(root=ROOT):
    return subprocess.check_output(["git", "show", BASE + ":" + BLUE], cwd=root).decode()


def remove_blue_light(source, root=ROOT):
    manifest = json.loads((current_path("Validation/v4-cleanup-deletions.json", root)).read_text())
    assert manifest["base_commit"] == BASE and set(manifest["files"]) == {BLUE}
    lines = source.splitlines(keepends=True)
    removed = set()
    for entry in manifest["files"][BLUE]:
        first, last = entry["start_line"], entry["end_line"]
        assert 1 <= first <= last <= len(lines) and entry["reason"]
        indexes = set(range(first, last + 1))
        assert not removed.intersection(indexes)
        block = "".join(lines[first - 1:last]).encode()
        assert hashlib.sha256(block).hexdigest() == entry["sha256"]
        removed.update(indexes)
    assert len(removed) == 367
    return "".join(line for i, line in enumerate(lines, 1) if i not in removed)


def historical_composition(root=ROOT):
    import sys
    sys.path.insert(0, str(root / "GradientsKit-V4/Scripts"))
    from compose_metal import compose
    return compose(root / "GradientsKit-V4", blue_source=approved_blue(root))
