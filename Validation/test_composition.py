"""Meaningful composition/build-dependency checks against the approved Git object."""
import importlib.util
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from metal_dedup import verify as verify_metal_sharing

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
            original_composer = subprocess.check_output(["git", "show", "39b50ed:Scripts/compose_metal.py"], cwd=ROOT).decode()
            scope = {"__file__": str(base / "Scripts/compose_metal.py")}
            exec(compile(original_composer, "original_composer", "exec"), scope)
            for name in scope["MODULES"]:
                relative = "ShaderSources/" + name + ".metal.source"
                (base / relative).write_bytes(subprocess.check_output(["git", "show", "39b50ed:" + relative], cwd=ROOT))
            self.assertEqual(scope["compose"](base), approved)

    def test_candidate_has_only_exact_shared_implementations(self):
        verify_metal_sharing()

    def test_xcode_tracks_every_composition_input(self):
        declared = set((ROOT / "ShaderSources/CompositionInputs.xcfilelist").read_text().splitlines())
        expected = {"$(SRCROOT)/Scripts/compose_metal.py"}
        expected.update("$(SRCROOT)/ShaderSources/" + name + ".metal.source" for name in COMPOSER.MODULES)
        expected.update("$(SRCROOT)/ShaderSources/" + name for name in COMPOSER.INCLUDE_BLOCKS)
        self.assertEqual(declared, expected)

    def test_expanded_input_is_byte_identical_to_stable_75e1800(self):
        source = subprocess.check_output(["git", "show", "75e1800:Scripts/compose_metal.py"], cwd=ROOT).decode()
        scope = {"__file__": str(ROOT / "Scripts/compose_metal.py")}
        exec(compile(source, "stable_composer", "exec"), scope)
        scope["read_module"] = lambda root, name: subprocess.check_output(
            ["git", "show", "75e1800:ShaderSources/" + name + ".metal.source"], cwd=ROOT).decode()
        self.assertEqual(COMPOSER.compose(), scope["compose"]())

    def test_shared_block_changes_reach_all_three_call_sites(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            shutil.copytree(ROOT / "ShaderSources", base / "ShaderSources")
            include = base / "ShaderSources" / COMPOSER.INCLUDE_BLOCKS[0]
            include.write_text(include.read_text() + "// include dependency marker\n")
            self.assertEqual(COMPOSER.compose(base).count(b"// include dependency marker"), 3)
        project = (ROOT / "UIKitDemo/GradientsUIKit.xcodeproj/project.pbxproj").read_text()
        for name in COMPOSER.INCLUDE_BLOCKS:
            self.assertIn("$(SRCROOT)/../ShaderSources/" + name, project)

    def test_shared_fields_and_blue_tail_reach_only_their_original_sites(self):
        for name, count in [("PhysicalFields.inc", 4), ("BlueGeometryTail.inc", 3)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as folder:
                base = Path(folder)
                shutil.copytree(ROOT / "ShaderSources", base / "ShaderSources")
                include = base / "ShaderSources/Shared" / name
                include.write_text(include.read_text() + "// geometry dependency marker\n")
                self.assertEqual(COMPOSER.compose(base).count(b"// geometry dependency marker"), count)

    def test_undeclared_or_nested_blocks_are_rejected(self):
        with self.assertRaises(ValueError):
            COMPOSER.expand_blocks(ROOT, '#include "Unregistered.inc"\n')
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            path = base / "ShaderSources" / COMPOSER.INCLUDE_BLOCKS[0]
            path.parent.mkdir(parents=True)
            path.write_text('#include "Shared/InteractionHistory.inc"\n')
            with self.assertRaises(ValueError):
                COMPOSER.expand_blocks(base, '#include "Shared/InteractionHistory.inc"\n')

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
