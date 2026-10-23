"""Meaningful composition/build-dependency checks against the approved Git object."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("composer", ROOT / "Scripts/compose_metal.py")
COMPOSER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMPOSER)


class CompositionTests(unittest.TestCase):
    def test_exact_approved_library(self):
        approved = subprocess.check_output(
            ["git", "show", "542b89b:LiquidSpecBackground.metal"], cwd=ROOT)
        self.assertEqual(COMPOSER.compose(), approved)

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
