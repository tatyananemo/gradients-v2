#!/usr/bin/env python3
"""Offline baseline/replay checks. Does not install or launch an iOS app."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from metal_dedup import verify as verify_metal_sharing
from approved_metal import historical_composition

from paths import ROOT, SDK, current_path
BASE = "542b89b54b9299b48d4121de7f6ee182f3e3f340"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def app_source():
    reference = current_path("Validation/ReferenceV2")
    files = sorted(reference.glob("*.swift")) + sorted((reference / "Sources").glob("*.swift"))
    return "\n".join(p.read_text() for p in files)


def fixed_parameters(source, approved):
    default = block(approved, "enum GradientPresetLibrary")
    default = default.split("static let airyPreset", 1)[0]
    values = {name: (int(value) if name == "waveCount" else float(value))
              for name, value in re.findall(r"^\s+(\w+): ([0-9.]+),?\s*$", default, re.M)}
    assert len(values) == 14
    if "@State private var preset" in source:
        for name in values:
            assert "= GradientPresetLibrary.defaultPreset." + name in source
        return values
    actual = {}
    for name in values:
        found = re.findall(r"private let " + name + r": (?:CGFloat|Int) = ([0-9.]+)", source)
        assert len(found) == 1, name
        actual[name] = int(found[0]) if name == "waveCount" else float(found[0])
    assert actual == values, "Frozen shader parameters differ from approved defaults"
    return actual


def call(source, name):
    start = source.index(name + "(")
    opening = source.index("(", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "(") - (source[end] == ")")
        end += 1
    return source[start:end]


def check_render_arguments(source, approved):
    previous = call(approved, "ShaderLibrary.gradientsV2Background")
    previous = previous.replace("interactionTrailArguments(at: now, origin: globalFrame.origin, size: gradientLayerSize)", "v2History")
    current = call(source, "ShaderLibrary.gradientsV2Background")
    current = current.replace("interactionTrailArguments(at: now, origin: globalFrame.origin, size: gradientLayerSize)", "v2History")
    assert current == previous, "Swift-to-Metal background arguments changed"
    assert call(source, "ShaderLibrary.gradientTrailDistortion") == call(approved, "ShaderLibrary.gradientTrailDistortion")
    assert 'Text("Устанавливаем защищенное соединение. Водите пальцем в разных частях экрана")' in source


def check_preserved_ui(source, approved):
    # These active overlays are outside the offscreen Metal renderer.
    for marker in ["enum GradientAppTheme", "enum GradientColorPreset",
                   "struct V2CaptionBackdrop", "class V2CaptionProbe",
                   "struct V2CounterExclusion", "struct V2CaptionFrameKey",
                   "struct V2MaskUniformsKey", "struct OptionalDistortionModifier"]:
        assert block(source, marker) == block(approved, marker), marker
    current_mask = block(source, "struct PercentCenterMask")
    approved_mask = block(approved, "struct PercentCenterMask")
    assert block(current_mask, "if isDarkTheme") == block(approved_mask, "if isDarkTheme")
    current_ui = block(source, "                    VStack {")
    previous_ui = block(approved, "                    VStack {")
    # The removed offset was permanently zero: its start time was never triggered.
    previous_ui = previous_ui.replace("\n                            .offset(x: bottomTextShake.width, y: bottomTextShake.height)", "")
    current_ui = current_ui.replace("\n                            .offset(x: bottomTextShake.width, y: bottomTextShake.height)", "")
    assert current_ui == previous_ui, "Main screen layout or styling changed"
    for text in [source, approved]:
        start = text.index("let v2Uniforms:")
        uniforms = text[start:text.index("                ZStack {", start)]
        if text is source:
            current_uniforms = uniforms
        else:
            assert current_uniforms == uniforms, "Caption probe uniforms changed"


def behavior_source(source):
    template = (current_path("Validation/behavior_driver.swift.txt")).read_text()
    markers = ["struct ProgressIncrement", "final class TouchRuntime", "struct InteractionTrailSegment"]
    if "struct GradientTrailSample" in source:
        markers.append("struct GradientTrailSample")
    else:
        template = template.replace("    var gradientTrailSamples: [GradientTrailSample] = []\n", "")
    declarations = [block(source, ("private " if "private " + m in source else "") + m) for m in markers]
    constants = [re.search(r"^    private let " + name + r"[^\n]+", source, re.M).group()
                 for name in ["progressAnimationDuration", "progressStep", "maximumProgressRate"]]
    methods = [block(source, "private func " + name + "(") for name in [
        "reset", "interpolatedProgress", "advanceProgress", "recordInteractionTrail",
        "interactionTrailArguments"]]
    # The offline host is a reference type. Explicit capture permits the original
    # reset closure's implicit property accesses without changing its operations.
    assert methods[0].count("let resetProgress = {") == 1
    methods[0] = methods[0].replace("let resetProgress = {", "let resetProgress = { [self] in")
    for token, marker in [("CHANGED", ".onChanged { value in"), ("ENDED", ".onEnded { value in")]:
        handler = block(source, marker)
        handler = handler[handler.index("{ value in") + len("{ value in"):-1]
        clock = "let gestureNow = Date().timeIntervalSinceReferenceDate"
        assert handler.count(clock) == 1
        # Only the test's clock is injected. The callback algorithm is unchanged.
        template = template.replace("@@" + token + "@@", handler.replace(clock, "let gestureNow = gestureTime"))
    return (template.replace("@@DECLARATIONS@@", "\n".join(declarations))
            .replace("@@CONSTANTS@@", "\n".join(constants))
            .replace("@@METHODS@@", "\n".join(methods)))


def render_cases(parameters):
    parameters = {k: int(v) if float(v).is_integer() else v for k, v in parameters.items()}
    result = []
    for theme, dark, yellow in [("blue-dark", 1, 0), ("blue-light", 0, 0),
                                ("yellow-dark", 1, 3), ("yellow-light", 0, 3)]:
        def add(label, p, idle, t, history=()):
            u = [390, 844, p, 0, .72, .62, .32, .68, 0, 0, p * 10 + t,
                 parameters["progressSpeed"], parameters["fillGain"], parameters["waveStrength"],
                 parameters["waveSpread"], parameters["topBloom"], parameters["whiteCore"],
                 parameters["blueDepth"], 0, parameters["shockStrength"], parameters["shockInteraction"],
                 parameters["shockTrail"], parameters["waveCount"], dark, yellow, idle, t, len(history)]
            result.append({"name": f"{theme}-{label}", "uniforms": u, "history": list(history)})
        for p in [.3, .6, .8]:
            percent = round(p * 100)
            add(f"p{percent}-main", p, 0, 0)
            for t in [1.2, 1.65, 2.1]:
                add(f"p{percent}-contact-t{t}", p, 1, t)
        add("p0-idle", 0, 1, 1.65)
        add("p100-idle", 1, 1, 1.65)
        for label, age, fade in [("swipe", .05, 1), ("release", .65, .5), ("released", 1.3, 0)]:
            add(label, .6, 0, .8, [.15, .75, .72, .62, age, .9 * fade,
                                  .72, .62, .4, .35, age, 1.2 * fade])
        history = []
        for i in range(40):
            history.extend([.1, .15 + i % 7 * .1, .9, .2 + i % 7 * .1, i * .02, .7])
        add("maximum-history", .8, 0, .8, history)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--metal", type=Path, help="composed canonical V4 Metal input")
    parser.add_argument("--no-images", action="store_true", help="compatibility flag; checks are always numeric")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    import importlib.util
    spec = importlib.util.spec_from_file_location("composer", current_path("Scripts/compose_metal.py"))
    composer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(composer)
    metal = args.metal or out / "V4.metal"
    if args.metal is None:
        metal.write_bytes(composer.compose())
    assert metal.read_bytes() == composer.compose(), "Metal does not match current canonical modules"
    verify_metal_sharing()
    source = app_source()
    approved = subprocess.check_output(["git", "show", BASE + ":GradientInstallView.swift"], cwd=ROOT).decode()
    parameters = fixed_parameters(source, approved)
    check_render_arguments(source, approved)
    check_preserved_ui(source, approved)
    reference = json.loads((current_path("Validation/reference.json")).read_text())
    behavior = out / "behavior.swift"
    behavior.write_text(behavior_source(source))
    subprocess.run(["xcrun", "swiftc", "-O", str(behavior), "-o", str(out / "behavior")], check=True)
    subprocess.run([str(out / "behavior"), str(out / "behavior.json")], check=True)
    assert sha((out / "behavior.json").read_bytes()) == reference["behavior_sha256"], "Behavior replay differs"
    cases = render_cases(parameters)
    (out / "cases.json").write_text(json.dumps(cases, indent=2) + "\n")
    assert sha((out / "cases.json").read_bytes()) == reference["cases_sha256"], "Validation inputs differ"
    yellow_cases = [c for c in cases if c["name"].startswith("yellow-")]
    (out / "yellow-cases.json").write_text(json.dumps(yellow_cases, indent=2) + "\n")
    # Frozen rendering oracle is untouched. Disable only its PNG encoder in a
    # temporary harness; all GPU calculations and raw output writes stay exact.
    text = (current_path("Validation/render_reference.swift")).read_text()
    start = text.index("    let provider = CGDataProvider")
    end = text.index("    precondition(CGImageDestinationFinalize(destination))", start)
    end += len("    precondition(CGImageDestinationFinalize(destination))")
    renderer = out / "render-numeric.swift"
    renderer.write_text(text[:start] + text[end:])
    subprocess.run(["xcrun", "swiftc", "-O", str(renderer), "-o", str(out / "render")], check=True)
    def render(shader, inputs, folder):
        subprocess.run([str(out / "render"), str(shader), str(inputs), str(folder), "--no-images"], check=True)
        return {p.name: sha(p.read_bytes()) for p in folder.iterdir()
                if p.suffix in {".rgba16f", ".probe", ".distortion"}}
    current = render(metal, out / "yellow-cases.json", out / "frames")
    expected = {k: v for k, v in reference["render_sha256"].items() if k.startswith("yellow-")}
    assert current == expected, "Current V4 Yellow pixels, probe or distortion differ"
    # Blue-only code is read from approved local Git history for the historical
    # control, never restored to SDK or copied into maintained source files.
    control = out / "historical-control.metal"
    control.write_bytes(historical_composition())
    historical = render(control, out / "cases.json", out / "historical-frames")
    assert historical == reference["render_sha256"], "Historical 216-output control differs"
    result = {"passed": True, "base_commit": BASE, "frames": len(cases),
              "raw_gpu_outputs_compared": len(historical),
              "current_v4_yellow_frames": len(yellow_cases),
              "current_v4_yellow_outputs_compared": len(current),
              "behavior_checkpoints": len(json.loads((out / "behavior.json").read_text())),
              "metal_exact_sharing_and_declared_v4_deletions": True,
              "shader_parameters_and_arguments_identical": True, "gpu_byte_identical": True,
              "recorded_reference": False,
              "scope": "Current V4 Yellow 108 outputs plus historical 216-output control. No UI screenshots."}
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
