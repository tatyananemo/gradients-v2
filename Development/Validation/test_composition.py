"""Meaningful composition/build-dependency checks against the approved Git object."""
import importlib.util
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from metal_dedup import verify as verify_metal_sharing, expected_sources, expected_historical_composition
from approved_metal import historical_composition, approved_blue, remove_blue_light

from paths import ROOT, SDK, current_path
SPEC = importlib.util.spec_from_file_location("composer", current_path("Scripts/compose_metal.py"))
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

    def test_candidate_has_only_approved_sharing_and_v4_deletions(self):
        verify_metal_sharing()

    def test_shipping_blue_has_only_declared_deletions(self):
        source = (current_path("ShaderSources/ApprovedBlue.metal.source")).read_text()
        self.assertEqual(source, expected_sources()["ShaderSources/ApprovedBlue.metal.source"])
        self.assertNotIn("qaCurrentAcceptedDarkBlue", source)
        self.assertNotIn("qaContactDarkReference", source)
        self.assertIn("liquidSpecBackground", source)
        self.assertNotEqual(COMPOSER.compose(), historical_composition())

    def test_oracles_are_unchanged_from_v4_main(self):
        for path in ["Validation/reference.json", "Validation/metal-dedup.json", "Validation/metal-deletions.json"]:
            self.assertEqual(current_path(path).read_bytes(), subprocess.check_output(
                ["git", "show", "dc7b9da:" + path], cwd=ROOT))

    def test_full_screen_baseline_metadata_is_preserved(self):
        self.assertEqual((current_path("Validation/ReferenceV2/full-screen-baseline.json")).read_bytes(),
                         subprocess.check_output(["git", "show", "dc7b9da:Validation/UIKitMigration/baseline.json"], cwd=ROOT))

    def test_xcode_tracks_every_composition_input(self):
        declared = set((current_path("ShaderSources/CompositionInputs.xcfilelist")).read_text().splitlines())
        expected = {"$(SRCROOT)/Scripts/compose_metal.py"}
        expected.update("$(SRCROOT)/ShaderSources/" + name + ".metal.source" for name in COMPOSER.MODULES)
        expected.update("$(SRCROOT)/ShaderSources/" + name for name in COMPOSER.INCLUDE_BLOCKS)
        self.assertEqual(declared, expected)

    def test_historical_control_has_only_declared_delta_from_stable_75e1800(self):
        source = subprocess.check_output(["git", "show", "75e1800:Scripts/compose_metal.py"], cwd=ROOT).decode()
        scope = {"__file__": str(current_path("Scripts/compose_metal.py"))}
        exec(compile(source, "stable_composer", "exec"), scope)
        scope["read_module"] = lambda root, name: subprocess.check_output(
            ["git", "show", "75e1800:ShaderSources/" + name + ".metal.source"], cwd=ROOT).decode()
        self.assertEqual(expected_historical_composition(optimized=False), scope["compose"]())
        self.assertEqual(historical_composition(), expected_historical_composition())

    def test_shared_block_changes_reach_the_remaining_sdk_call_site(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            shutil.copytree(SDK / "ShaderSources", base / "ShaderSources")
            include = base / "ShaderSources" / COMPOSER.INCLUDE_BLOCKS[0]
            include.write_text(include.read_text() + "// include dependency marker\n")
            self.assertEqual(COMPOSER.compose(base).count(b"// include dependency marker"), 1)
        project = (SDK / "GradientsKit.xcodeproj/project.pbxproj").read_text()
        for name in COMPOSER.INCLUDE_BLOCKS:
            self.assertIn("$(SRCROOT)/ShaderSources/" + name, project)

    def test_shared_fields_and_blue_tail_reach_only_their_original_sites(self):
        for name, count in [("PhysicalFields.inc", 2), ("BlueGeometryTail.inc", 1)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as folder:
                base = Path(folder)
                shutil.copytree(SDK / "ShaderSources", base / "ShaderSources")
                include = base / "ShaderSources/Shared" / name
                include.write_text(include.read_text() + "// geometry dependency marker\n")
                self.assertEqual(COMPOSER.compose(base).count(b"// geometry dependency marker"), count)

    def test_undeclared_or_nested_blocks_are_rejected(self):
        with self.assertRaises(ValueError):
            COMPOSER.expand_blocks(SDK, '#include "Unregistered.inc"\n')
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
            command = [sys.executable, "-I", "-B", str(current_path("Scripts/compose_metal.py")), "--output", str(path)]
            subprocess.run(command, cwd=folder, check=True)
            before = path.stat().st_mtime_ns
            subprocess.run(command, cwd=folder, check=True)
            subprocess.run(command + ["--check"], cwd=folder, check=True)
            self.assertEqual(path.stat().st_mtime_ns, before)
            self.assertEqual(path.read_bytes(), COMPOSER.compose())

    def test_packaging_preserves_all_sdk_swift_and_metal_bytes(self):
        files = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", "ca0222e"], cwd=ROOT, text=True).splitlines()
        source_files = [p for p in files if (p.startswith("UIKitComponent/") and p.endswith((".swift", ".metal"))) or p.startswith("ShaderSources/")]
        self.assertEqual(len(source_files), 22)
        for path in source_files:
            with self.subTest(path=path):
                expected = expected_sources()[path] if path.startswith("ShaderSources/") else subprocess.check_output(
                    ["git", "show", "ca0222e:" + path], cwd=ROOT).decode()
                self.assertEqual(current_path(path).read_text(), expected)

    def test_demo_uses_external_sdk_target_without_source_copies(self):
        import json
        project = current_path("UIKitDemo/GradientsUIKitV4.xcodeproj/project.pbxproj")
        data = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(project)]))
        objects = data["objects"].values()
        targets = [v["name"] for v in objects if v["isa"] == "PBXNativeTarget"]
        self.assertEqual(set(targets), {"GradientsUIKitV4", "GradientsUIKitV4Tests", "GradientsUIKitV4UITests"})
        paths = [v["path"] for v in objects if v["isa"] == "PBXFileReference"]
        self.assertIn("../../GradientsKit-V4/GradientsKit.xcodeproj", paths)
        self.assertEqual({p for p in paths if p.endswith(".swift")},
                         {"AppDelegate.swift", "Tests/ComponentTests.swift", "Tests/SDKStabilityTests.swift", "UITests/InteractionTests.swift"})
        self.assertTrue(any(v["isa"] == "PBXReferenceProxy" and v["path"] == "GradientsKit.framework" for v in objects))

    def test_standalone_sdk_project_has_no_development_inputs(self):
        import json
        project = SDK / "GradientsKit.xcodeproj/project.pbxproj"
        data = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(project)]))
        targets = [v["name"] for v in data["objects"].values() if v["isa"] == "PBXNativeTarget"]
        self.assertEqual(targets, ["GradientsKit"])
        for v in data["objects"].values():
            for path in v.get("inputPaths", []) + ([v["path"]] if "path" in v else []):
                self.assertNotIn("..", path)
                self.assertNotIn("Development/", path)

    def test_sdk_project_regenerates_in_isolated_python_without_development(self):
        with tempfile.TemporaryDirectory() as folder:
            copied = Path(folder) / "GradientsKit-V4"
            shutil.copytree(SDK, copied, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
            before = (copied / "GradientsKit.xcodeproj/project.pbxproj").read_bytes()
            subprocess.run([sys.executable, "-I", "-B", str(copied / "Scripts/create_sdk_project.py")], cwd=folder, check=True)
            self.assertEqual(before, (copied / "GradientsKit.xcodeproj/project.pbxproj").read_bytes())
            self.assertFalse((Path(folder) / "Development").exists())

    def test_new_shared_blocks_reach_every_original_call_site(self):
        import json
        plan = json.loads(current_path("Validation/metal-optimization.json").read_text())
        for record in plan["literal_blocks"]:
            with self.subTest(path=record["path"]), tempfile.TemporaryDirectory() as folder:
                base = Path(folder)
                shutil.copytree(SDK / "ShaderSources", base / "ShaderSources")
                path = base / record["path"]
                path.write_text(path.read_text() + "// new shared block dependency marker\n")
                self.assertEqual(COMPOSER.compose(base).count(b"// new shared block dependency marker"),
                                 sum(record["occurrences"].values()))


if __name__ == "__main__":
    unittest.main()
