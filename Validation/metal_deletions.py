"""Verify that the Metal candidate is the approved Swift checkpoint with deletions only.

This is a validation guard, not a source generator; Xcode compiles the edited modules.
The original GPU/behavior reference is never replaced.
"""
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SWIFT_BASE = "39b50ed"


def verify(root=ROOT):
    manifest = json.loads((root / "Validation/metal-deletions.json").read_text())
    assert manifest["base_commit"] == SWIFT_BASE
    files = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", SWIFT_BASE], cwd=root, text=True).splitlines()
    for name in files:
        if not (name.endswith(".swift") or name.startswith("ShaderSources/")):
            continue
        original = subprocess.check_output(["git", "show", f"{SWIFT_BASE}:{name}"], cwd=root)
        entries = manifest["files"].get(name, [])
        if entries:
            assert name.endswith(".metal.source"), "Swift and build inputs are frozen"
            removed = set()
            lines = original.splitlines(keepends=True)
            for entry in entries:
                first, last = entry["start_line"], entry["end_line"]
                assert entry["reason"] and 1 <= first <= last <= len(lines)
                indexes = set(range(first, last + 1))
                assert not removed.intersection(indexes), "Overlapping deletion ranges"
                removed.update(indexes)
            expected = b"".join(line for i, line in enumerate(lines, 1) if i not in removed)
        else:
            expected = original
        assert (root / name).read_bytes() == expected, f"Undeclared change or non-deletion: {name}"
    assert set(manifest["files"]).issubset(files)
    # No alternate runtime sources may bypass these guards.
    actual_swift = {str(p.relative_to(root)) for p in root.glob("*.swift")}
    actual_swift.update(str(p.relative_to(root)) for p in (root / "Sources").glob("*.swift"))
    assert actual_swift == {p for p in files if p.endswith(".swift") and not p.startswith("Validation/")}
    return manifest


if __name__ == "__main__":
    data = verify()
    print("Deletion-only Metal changes verified; Swift is identical to", SWIFT_BASE)
