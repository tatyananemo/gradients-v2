# V4-Dark-Core — GradientsKit V4, d62ae67

Самостоятельный комплект исходников визуального UIKit + Metal-компонента биодатчика:

- **Yellow Dark:** утверждённый тёмный центр касания и мягкий золотисто-оранжевый след.
- **Yellow Light:** оригинальный визуал и проверенная специализация MAIN/CONTACT из `d62ae67`.
- Все предшествующие рабочие оптимизации сохранены: IOSurface, GPU Precalc, shared background,
  idle-zero, tile culling/fused distortion, окна Dark-масок и специализация Dark MAIN/CONTACT.

Основа — точные алгоритмические исходники `d62ae67`. Отклонённые цветовые эксперименты,
включая `0a60d72`, `de13ddd` и эксперимент внутреннего склона, **не включены**.
Старые V4, V4-Optimized и main репозитория не изменены.

## Что передавать

Передавайте **всю папку `V4-Dark-Core/`** с сохранением относительных путей:

```text
V4-Dark-Core/
  GradientsKit-V4/                 Swift/Metal, .inc, исходные цвета, базовые composers
  Development/DeviceComparison/   обязательные сборочные overlays и актуальный Xcode project
  Development/UIKitDemo/          исходник UIKit Demo, компонентные/UI-тесты
  Development/Validation/         существующие эталоны и инструменты проверок
  Tools/                          проверка исходников и unsigned Release/Debug build
  Documentation/                  текущий статус, исходные документы, референсы, manifest
  README.md
```

Не копируйте только вложенный `GradientsKit-V4`: действующие оптимизированные compiler inputs
собираются также из `Development/DeviceComparison`. Эта зависимость целиком находится внутри
передаваемой папки. Соседние папки репозитория, старые V2/V3, локальные /tmp-файлы и Simulator
для обычной сборки не нужны. Сторонних пакетов и submodules нет; SPM/XCFramework не поставляются.

## Требования и сборка

macOS, полный Xcode с iOS SDK и **Metal Toolchain**, Python 3 (`/usr/bin/python3`).
Deployment target — iOS 17.0+. Зафиксированный Release-артефакт получен Xcode 26.3 (17C529), arm64 iphoneos.
Если Metal Toolchain отсутствует: Xcode → Settings → Components. Выберите Xcode через `xcode-select`.

Из корня этой папки:

```sh
python3 -B Tools/verify_delivery.py
python3 -B Tools/build_release.py --derived-data /tmp/v4-dark-core-release
# При необходимости Debug, без установки и запуска:
python3 -B Tools/build_release.py --derived-data /tmp/v4-dark-core-debug --configuration OptimizedDebug
```

Или откройте **`Development/DeviceComparison/V4DeviceComparison.xcodeproj`**, схема
**V4 Dark Core**, конфигурация **OptimizedRelease** (Debug — OptimizedDebug).

```sh
xcodebuild -project Development/DeviceComparison/V4DeviceComparison.xcodeproj \
  -scheme 'V4 Dark Core' -configuration OptimizedRelease \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/v4-dark-core-release \
  CODE_SIGNING_ALLOWED=NO build
```

Продукты: `<derived-data>/Build/Products/OptimizedRelease-iphoneos/GradientsKit.framework`
и `GradientsV4Comparison.app`. `default.metallib` компилируется из включённых исходников;
готовый бинарный shader не требуется скачивать отдельно. Зафиксированный размер:
**344 604 байта**, SHA-256 `f445d41cd8ab26d318fa37b213df020a3f6af1d4b4f3199df06a7b8877f60d99`.
Лимит — 500 000 байт. При другом toolchain хеш может отличаться: расследуйте различие,
не обновляйте эталоны автоматически.

Обычный запуск схемы: Dark, 0%, без LLDB, автосвайпов и измерителя. App display name —
**V4 Dark Core**; пример bundle ID — `org.example.gradientskit.v4.darkcore.demo`.
Для своего iPhone задайте собственные Team и bundle ID в Xcode. Можно создать локальный
`Development/DeviceComparison/LocalSigning.xcconfig` с `DEVELOPMENT_TEAM = YOUR_TEAM_ID`.
Личные настройки подписи не входят в комплект. Эти инструкции ничего не устанавливают автоматически.

**Не используйте другие схемы Reference/Precalc/Combined и базовые проекты
`GradientsKit-V4/GradientsKit.xcodeproj` / `Development/UIKitDemo/GradientsUIKitV4.xcodeproj`
как эту версию:** они сохранены для исторических проверок, но не собирают весь d62ae67-путь.
При необходимости восстановить актуальный проект: `python3 -I -B Development/DeviceComparison/create_project.py`.

## Интеграция и публичный API

Добавьте актуальный DeviceComparison project в workspace приложения, свяжите target
`GradientsKit` и настройте Embed & Sign. Для SDK используйте OptimizedRelease/OptimizedDebug;
не подключайте вторую одноимённую библиотеку из базового проекта.

```swift
import UIKit
import GradientsKit

let gradient = try GradientViewController(theme: .yellowDark)
addChild(gradient)
view.addSubview(gradient.view)
gradient.view.frame = view.bounds
gradient.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
gradient.didMove(toParent: self)

// Переключение темы, существующий API:
gradient.theme = .yellowLight
```

Публичный API, gesture/session logic, прогресс и тайминги не менялись. Полные существующие
интерфейсы и containment — в [техническом документе](Documentation/TECHNICAL.md).
Не включайте диагностические environment flags при обычном использовании.
КриптоПро/криптографические операции не входят в SDK. Текущая модель прогресса — демологика
свайпов, а не подтверждение фактического выполнения внешней операции; публичного setter
произвольного внешнего прогресса сейчас нет. Контракт с конечным продуктом нужно согласовать отдельно.

## Исходные цвета

Единый файл: [`GradientsKit-V4/Configuration/YellowColors.json`](GradientsKit-V4/Configuration/YellowColors.json).
`dark` и `light` независимы. Компоненты — строки точных числовых выражений, например
`"221.0 / 255.0"`; JSON читается **при сборке**, не каждый кадр. Runtime-палитры и setPalette нет.
Меняйте только согласованные цветовые роли, затем пересобирайте и проверяйте визуал.
В Dark Touch распределение цветовых ролей также задаёт
`Development/DeviceComparison/dark_route_source.py`: не меняйте его формулы ради смены оттенка.
Не изменяйте Blue reference, геометрию, Gaussian blur, альфу или compiler flags.
Frozen-проверки фиксируют эти defaults и намеренно сообщат о согласованном изменении палитры;
не заменяйте эталоны или manifest для сокрытия различий.

## Проверенные показатели и статус

Физический iPhone 14, iOS 26.7, Release, без Instruments; каждый контроль — 3 с прогрева
и 6 с автосвайпов со старта 63% с обычным продвижением до 100%, яркость экрана 0,35:

| Сценарий | FPS | p95 / p99 кадра | Интервалы около 33 мс | Thermal state |
|---|---:|---:|---:|---|
| Dark, пустой фон | 59,95 | 16,698 / 16,699 мс | 0 | nominal |
| Dark, градиент | 59,92 | 16,699 / 16,702 мс | 0 | nominal |
| Light, смешанная траектория | 59,92 | 16,697 / 16,702 мс | 0 | nominal |

Это конкретные короткие проверки, не гарантия 60 FPS во всех сценариях и не измерение
температуры корпуса. Длительная тепловая стабильность d62ae67 не доказана; на более ранней
версии наблюдался serious при продолжительном Dark idle. Нельзя обещать отсутствие нагрева.
Dark Touch сохраняет утверждённый вид: тёмный центр и заметный золотисто-оранжевый переход;
дальнейшие попытки смягчить контур/убрать оливковое восприятие отклонены и не включены.

Непрерывные свайпы: target 100% за 9,40–9,50 с; завершение интерполяции за 9,88–9,97 с
в существующем CPU replay 30/40/60/120 Hz. Это не новый физический замер; idle/hold сами
не накапливают прогресс. Существующие проверки и ограничения: [CURRENT.md](Documentation/CURRENT.md).
Публикация не выполняет новые FPS/GPU/UI-прогоны и ничего не устанавливает на iPhone.
