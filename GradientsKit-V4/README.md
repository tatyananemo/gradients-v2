# GradientsKit V4

Самостоятельный исходный UIKit + Metal SDK для iOS 17+. Две темы: `yellowDark` и `yellowLight`. SwiftUI, Demo, Development, Git и другие версии приложения для сборки не нужны.

## Передача и сборка

Передавайте **всю эту папку**: `Sources/`, `ShaderSources/` (включая `Shared/*.inc` и `CompositionInputs.xcfilelist`), `Scripts/`, `GradientsKit.xcodeproj`, `.gitignore` и этот README. Вложенный Git-репозиторий не создаётся.

Требуются Xcode с iOS SDK и `/usr/bin/python3` (Xcode Command Line Tools). Откройте `GradientsKit.xcodeproj`, выберите схему **GradientsKit** и нужный iOS Simulator или iOS device, выполните Build. Из командной строки:

```sh
xcodebuild -project GradientsKit.xcodeproj -scheme GradientsKit -configuration Release -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

При необходимости проект воспроизводимо восстанавливается командой `python3 -I -B Scripts/create_sdk_project.py`. Генераторы не читают Development или Git. Metal composer раскрывает утверждённые модули и `.inc` в DerivedData; не редактируйте полученный файл. `default.metallib` компилируется в bundle самого framework и загружается оттуда, а не из приложения.

## Подключение к UIKit-приложению

Добавьте `GradientsKit.xcodeproj` в проект или workspace приложения. В target приложения добавьте `GradientsKit.framework` в **Frameworks, Libraries, and Embedded Content → Embed & Sign**, а SDK — в зависимости сборки. Настройте подпись и Team приложения и framework для реального устройства. Все пути SDK относительные.

```swift
import UIKit
import GradientsKit

let gradient = try GradientViewController(theme: .yellowDark)
parent.addChild(gradient)
gradient.view.frame = parent.view.bounds
gradient.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
parent.view.addSubview(gradient.view)
gradient.didMove(toParent: parent)

gradient.theme = .yellowLight
gradient.onSettings = { /* настройки принадлежат приложению */ }
gradient.onFrame = { frame in /* frame.progress */ }
gradient.reset(animated: true)
```

Создавайте и используйте контроллер на main actor. Компонент владеет свайпами, прогрессом и display link; не отправляйте те же жесты в session второй раз. `pauseRendering()` / `resumeRendering()` доступны для политики перекрытий приложения; автоматическая обработка видимости и app/scene lifecycle сохранена. Вручную приостановленный компонент сам не возобновляется. `GradientSession` требует последовательного владения; время внешних событий — `Date.timeIntervalSinceReferenceDate`. Сохраняйте слабые ссылки в callbacks, если иначе образуется цикл удержания.

## Границы готовности

- Это исходный Xcode framework; Package.swift и готовый XCFramework не поставляются. Simulator и device требуют разных сборок.
- UIKit, Metal/MetalKit, Core Image, Core Graphics, IOSurface, Foundation — системные зависимости. Внешних пакетов нет.
- Типографика, отступы, маски и анимации фиксированы утверждённым дизайном; автоматической адаптации Dynamic Type / Reduce Motion нет. Safe area и навигация принадлежат host-приложению.
- Общая геометрия в Blue-названных файлах нужна Yellow: не удалять эти файлы.
- Ошибки начальной Metal-инициализации передаются через `throws`; полноценный recoverable API для поздних ошибок ресурсов пока не определён.
- До публикации приложения разработчики должны проверить privacy manifest / required-reason API (`systemUptime`), лицензионные условия распространения, подпись и работу на реальном iPhone. Privacy manifest в этой поставке ещё не добавлен; Simulator не подтверждает производительность устройства.
- Полный GPU + Thread Sanitizer в Simulator остаётся непроверенным сценарием. Эталоны и тесты находятся отдельно в Development и требуют истории исходного репозитория.

## Полный список передаваемых файлов

Передавайте эти файлы с сохранением относительных путей:

```text
.gitignore
GradientsKit.xcodeproj/project.pbxproj
GradientsKit.xcodeproj/xcshareddata/xcschemes/GradientsKit.xcscheme
README.md
Scripts/compose_metal.py
Scripts/compose_uikit_metal.py
Scripts/create_sdk_project.py
Scripts/xcode_project.py
ShaderSources/ApprovedBlue.metal.source
ShaderSources/CompositionInputs.xcfilelist
ShaderSources/ContactFields.metal.source
ShaderSources/Shared/BlueGeometryTail.inc
ShaderSources/Shared/InteractionHistory.inc
ShaderSources/Shared/PhysicalFields.inc
ShaderSources/Shared/YellowDarkPose.inc
ShaderSources/Shared/YellowInteraction.inc
ShaderSources/Shared/YellowLightSubstrate.inc
ShaderSources/Shared/YellowWaveProfile.inc
ShaderSources/V2EntryPoints.metal.source
ShaderSources/YellowDarkContact.metal.source
ShaderSources/YellowDarkMAIN.metal.source
ShaderSources/YellowLightContact.metal.source
ShaderSources/YellowLightMAIN.metal.source
ShaderSources/YellowShared.metal.source
Sources/GradientsKit/Core/GradientResetPresentation.swift
Sources/GradientsKit/Core/GradientSession.swift
Sources/GradientsKit/GradientGPU.swift
Sources/GradientsKit/GradientMaskRenderer.swift
Sources/GradientsKit/GradientPercentageLabel.swift
Sources/GradientsKit/GradientPerformanceMetrics.swift
Sources/GradientsKit/GradientTheme.swift
Sources/GradientsKit/GradientViewController.swift
Sources/GradientsKit/SessionCaptionProbe.swift
Sources/GradientsKit/Shaders/GradientAdapters.metal
```
