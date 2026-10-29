# Development и действующий optimized SDK

В этой финальной передаче `DeviceComparison` — **обязательная часть сборки SDK `1b3c287`**,
а не папка, которую можно удалить после запуска Demo. Историческое название сохранено ради
воспроизводимости. См. корневой README и Documentation/TECHNICAL.md.

- `DeviceComparison`: актуальный project/overlays/cache, схема V4 Optimized; остальные схемы — прежние контрольные варианты.
- `UIKitDemo/AppDelegate.swift`: общий Demo, без собственной копии рендера. Tests/UITests сохранены.
- `UIKitDemo/*.xcodeproj`: историческая базовая V4, не финальный optimized путь.
- `Validation`: неизменяемые численные эталоны, исторические доказательства и инструменты повторения.
  Их наличие не означает, что старые runner scripts проверяют актуальный Optimized путь автоматически.
  Многие проверки исходной истории требуют полного clone; обычная Release-сборка Git не читает.

Не включаются локальная подпись, device data, traces, binaries/DerivedData, логи или новые эксперименты.
