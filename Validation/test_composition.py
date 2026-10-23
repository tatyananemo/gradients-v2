"""Meaningful composition/build-dependency checks against the approved Git object."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from metal_deletions import verify as verify_metal_deletions

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("composer", ROOT / "Scripts/compose_metal.py")
COMPOSER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMPOSER)


class CompositionTests(unittest.TestCase):
    def test_original_composition_still_reproduces_approved_library(self):
        approved = subprocess.check_output(["git", "show", "542b89b:LiquidSpecBackground.metal"], cwd=ROOT)
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            (base / "ShaderSources").mkdir()
            for name in COMPOSER.MODULES:
                relative = "ShaderSources/" + name + ".metal.source"
                (base / relative).write_bytes(subprocess.check_output(["git", "show", "39b50ed:" + relative], cwd=ROOT))
            self.assertEqual(COMPOSER.compose(base), approved)

    def test_candidate_has_only_documented_deletions(self):
        verify_metal_deletions()

    def test_xcode_tracks_every_composition_input(self):
        declared = set((ROOT / "ShaderSources/CompositionInputs.xcfilelist").read_text().splitlines())
        expected = {"$(SRCROOT)/Scripts/compose_metal.py"}
        expected.update("$(SRCROOT)/ShaderSources/" + name + ".metal.source" for name in COMPOSER.MODULES)
        self.assertEqual(declared, expected)

    def test_cli_is_independent_of_cwd_and_preserves_unchanged_output(self):
        with tempfile.TemporaryDirectory(prefix="V2 composition ") as folder:
            path = Path(folder) / "Derived Sources" / "LiquidSpecBackground.metal"
            command = [sys.executable, "-I", "-B", str(ROOT / "Scripts/compose_metal.py"), "--output", str(path)]
            subprocess.run(command, cwd=folder, check=True)
            before = path.stat().st_mtime_ns
            subprocess.run(command, cwd=folder, check=True)
            subprocess.run(command + ["--check"], cwd=folder, check=True)
            self.assertEqual(path.stat().st_mtime_ns, before)
            self.assertEqual(path.read_bytes(), COMPOSER.compose())


if __name__ == "__main__":
    unittest.main()
