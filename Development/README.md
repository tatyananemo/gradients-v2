# Development

Эта папка нужна только разработчикам и проверкам. SDK находится единственным экземпляром в соседней `../GradientsKit-V4`.

- `UIKitDemo/GradientsUIKitV4.xcodeproj`: обычное UIKit-приложение, схема GradientsUIKitV4, компонентные и UI-тесты.
- `Validation/`: численные эталоны и воспроизводимые проверки. Исторические Git objects нужны только этим проверкам.
- `Scripts/create_demo_project.py`: создаёт Demo-проект с cross-project dependency на SDK; SDK-проект создаётся его собственным генератором.

Обе папки остаются в одном Git-репозитории. При передаче SDK Development копировать не требуется.
