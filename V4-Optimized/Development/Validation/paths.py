"""Locate current files while preserving historical Git paths in validation proofs."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
SDK = ROOT / "GradientsKit-V4"


def current_path(relative, root=ROOT):
    relative = str(relative)
    if relative.startswith("UIKitComponent/"):
        return root / "GradientsKit-V4/Sources/GradientsKit" / relative.removeprefix("UIKitComponent/")
    if relative.startswith(("ShaderSources/", "Scripts/")):
        return root / "GradientsKit-V4" / relative
    if relative.startswith(("Validation/", "UIKitDemo/")):
        return root / "Development" / relative
    raise ValueError("Unmapped historical path: " + relative)
