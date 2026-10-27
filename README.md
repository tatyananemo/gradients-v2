# GradientsKit V4 — development repository

Один Git-проект, две части:

```text
GradientsKit-V4/     самостоятельный SDK — передаётся целиком
  Sources/GradientsKit/   Swift-компонент и Metal adapters
  ShaderSources/         канонические Metal-модули и Shared/*.inc
  Scripts/               composer и генератор Xcode-проекта
  GradientsKit.xcodeproj/ framework, схема GradientsKit
  README.md
Development/        в поставку SDK не входит
  UIKitDemo/        приложение, компонентные и UI-тесты
  Validation/       неизменяемые эталоны и проверки
  Scripts/          генератор Demo-проекта
```

Инструкция подключения: [GradientsKit-V4/README.md](GradientsKit-V4/README.md).

Для разработки откройте `Development/UIKitDemo/GradientsUIKitV4.xcodeproj`, выберите **GradientsUIKitV4**. Demo и тесты связываются с внешним framework-target из `GradientsKit-V4/GradientsKit.xcodeproj`; собственных копий SDK у них нет. Product → Test запускает компонентные и UI-проверки.

Восстановление проектов из корня репозитория:

```sh
python3 -I -B GradientsKit-V4/Scripts/create_sdk_project.py
python3 -I -B Development/Scripts/create_demo_project.py
```

Утверждённые Metal-формулы, публичный API и поведение сохранены. Экспериментальный путь Dark-масок переиспользует IOSurface при прежних CG-геометрии и Gaussian blur; замеры и эталоны остаются раздельными. Для численных проверок нужна локальная история Git; передаваемому SDK она не нужна. См. `Development/Validation/README.md`. Сгенерированный Metal и продукты сборки не хранятся в Git. Другие V2/V3/production не используются.
