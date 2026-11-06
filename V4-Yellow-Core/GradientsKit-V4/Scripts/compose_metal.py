#!/usr/bin/env python3
"""Compose canonical V4 Metal; do not rewrite shader formulas."""
import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INCLUDE_BLOCKS = ("Shared/InteractionHistory.inc", "Shared/PhysicalFields.inc", "Shared/BlueGeometryTail.inc", "Shared/YellowDarkPose.inc", "Shared/YellowInteraction.inc", "Shared/YellowLightSubstrate.inc", "Shared/YellowWaveProfile.inc")
YELLOW_MODULES = ("YellowDarkMAIN", "YellowLightMAIN", "YellowDarkContact", "YellowLightContact")
MODULES = ("ApprovedBlue", "ContactFields", "YellowShared", *YELLOW_MODULES, "V2EntryPoints")


def expand_blocks(root, source):
    # Literal source inclusion only: no substitutions, formulas or new scopes.
    def include(match):
        name = match[1]
        if name not in INCLUDE_BLOCKS:
            raise ValueError("Undeclared Metal include: " + name)
        text = (root / "ShaderSources" / name).read_bytes().decode("utf-8")
        if not text.endswith("\n") or '#include' in text:
            raise ValueError("Expected one flat, newline-terminated Metal block: " + name)
        return text
    return re.sub(r'^[ \t]*#include "([^"\n]+\.inc)"[ \t]*\n', include, source, flags=re.M)


def read_module(root, name):
    source = (root / "ShaderSources" / (name + ".metal.source")).read_bytes().decode("utf-8")
    return expand_blocks(root, source)


def compose(root=ROOT, *, blue_source=None):
    blue = read_module(root, "ApprovedBlue") if blue_source is None else expand_blocks(root, blue_source)
    entry = "[[ stitchable ]]\nhalf4 liquidSpecBackground("
    if blue.count(entry) != 1:
        raise ValueError("Expected one ApprovedBlue entry annotation")
    # This internal entry is called by the dispatcher, not directly by SwiftUI.
    # Preserve remaining public entry annotations and surviving formulas verbatim.
    result = blue.replace(entry, "half4 liquidSpecBackground(")
    result += "\n" + read_module(root, "ContactFields") + "\n\n"
    result += read_module(root, "YellowShared") + "\n"
    for name in YELLOW_MODULES:
        source = read_module(root, name)
        if source.count("[[ stitchable ]]") != 1:
            raise ValueError("Expected one entry annotation in " + name)
        # Keep the original namespace boundaries and annotation-line whitespace.
        result += "namespace " + name + " {\n"
        result += source.replace("[[ stitchable ]]", "") + "\n}\n\n"
    result += read_module(root, "V2EntryPoints")
    return result.encode("utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--check", action="store_true", help="verify an existing output without writing")
    args = parser.parse_args()
    expected = compose()
    current = args.output.read_bytes() if args.output.exists() else None
    if args.check:
        if current != expected:
            parser.exit(1, "Metal composition is missing or stale\n")
    elif current != expected:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(expected)
    print("Metal composition verified" if args.check else "Metal composition ready")


if __name__ == "__main__":
    main()
