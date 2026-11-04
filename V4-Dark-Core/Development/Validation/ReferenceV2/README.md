> Исторический материал: относится к указанному ниже этапу/исходникам, а не к новой проверке `1b3c287`.
> Текущий статус V4-Optimized, границы точности масок/кадров, FPS и заполнение 9–10 с — в [RESULTS.md](../../../Documentation/RESULTS.md).
> Старые source guards могут намеренно отвергать поздние согласованные изменения; это не инструкция сборки optimized SDK.

# Frozen SwiftUI V2 source oracle

These seven Swift files are retained byte-for-byte, not built into V4. Validation reads their original input callbacks, fixed parameters, frame expressions, UI declarations and caption/mask definitions. `metal_dedup.py` verifies their accepted source identity.

The old app project and empty asset metadata were removed because no current build or numerical validator uses them. The runnable historical project remains available in Git at `dc7b9da`; do not modify these fixtures to make a candidate pass.

`full-screen-baseline.json` is the immutable 88-screen baseline metadata moved from UIKitMigration/baseline.json without changing a byte. Preserve it for future visual investigations; the original capture workflow is in Git history.
