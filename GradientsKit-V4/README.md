# GradientsKit V4

Самостоятельный исходный UIKit + Metal SDK для iOS 17+. Две темы: `yellowDark` и `yellowLight`. SwiftUI, Demo, Development, Git и другие версии приложения для сборки не нужны.

## Передача и сборка

Передавайте **всю эту папку**: `Configuration/`, `Sources/`, `ShaderSources/` (включая `Shared/*.inc` и `CompositionInputs.xcfilelist`), `Scripts/`, `GradientsKit.xcodeproj`, `.gitignore` и этот README. Вложенный Git-репозиторий не создаётся.

Требуются Xcode с iOS SDK и `/usr/bin/python3` (Xcode Command Line Tools). Откройте `GradientsKit.xcodeproj`, выберите схему **GradientsKit** и нужный iOS Simulator или iOS device, выполните Build. Из командной строки:

```sh
xcodebuild -project GradientsKit.xcodeproj -scheme GradientsKit -configuration Release -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

При необходимости проект воспроизводимо восстанавливается командой `python3 -I -B Scripts/create_sdk_project.py`. Генераторы не читают Development или Git. Metal composer раскрывает утверждённые модули и `.inc` в DerivedData; не редактируйте полученный файл. `default.metallib` компилируется в bundle самого framework и загружается оттуда, а не из приложения.

## Внутренние цвета Yellow — один файл, затем пересборка

Редактируйте только `Configuration/YellowColors.json`: секции `dark` и `light` независимы. Это настройки исходников SDK, не публичный API. Приложение не читает JSON и не меняет pipeline во время работы. Например, замените только `dark.contactCore` на `["1.0", "220.0 / 255.0", "45.0 / 255.0"]`, затем пересоберите SDK. Light останется прежней. Для проверки другого оттенка Light меняйте соответствующее поле в `light`.

Компоненты — строки с исходными decimal-выражениями sRGB в 0...1, например `"221.0 / 255.0"`. Не округляйте их до HEX/коротких десятичных дробей. Генератор проверяет поля и диапазоны, передаёт выражения компилятору Metal/Swift в исходной точности; JSON не попадает в bundle. Дефолтный Metal compiler input побайтово совпадает с `615dfe0`. Цвета масок становятся внутренними `static let` CGFloat, tint подписи создаётся один раз.

Назначения полей:

- `mainDeep/Mid/Hot/Accent` — цветовые опоры MAIN и связанной передачи света; это разные роли, не общий RGB-фильтр.
- `contactArc/Core` — свободная оранжевая дуга и жёлтый контакт. Dark `contactHueBright/Shade` — ранее скрытые опоры оттенка `(1,.82,0)` и `(1,.72,0)`; `contactDiffuseSource/Peak` — сохранённые цветовые опоры общего readout. Не все эти роли участвуют в каждом состоянии.
- Light `primarySource/Peak`, `haloWarm/White`, `transmissionRed` — существующие спектральные опоры Light. Коэффициенты смешивания и яркости не являются параметрами.
- `trailDeep/Mid/Hot/Accent/White` — собственные цвета следа свайпа. Они независимы от одноимённых MAIN-опор.
- `counterTint` — существующий белый цвет мягкой защиты в Yellow readout, с прежней геометрией/альфой.
- Dark `maskTint/Base` — RGB источников трёх CG/CI-масок; Light `captionTint` — RGB нижней UI-подложки. Blur, прозрачность и активация не меняются.

Формулы HSV/OKLab, gamma, luminance weights, диапазоны, матрицы, опорные Blue-цвета, чёрный canvas и чёрная Metal-подложка не редактируются. Последняя задана исходным умножением RGB на оставшуюся альфу, без отдельного RGB-параметра: её перекраска потребовала бы изменения формулы и сюда не включена. Цвета текста/кнопок не являются палитрой градиента.

Общие цветовые helpers при необходимости получают отдельную привязку констант для каждой темы с прежними сигнатурами и арифметикой. Геометрия остаётся общей. При дефолтах такие дополнительные привязки не создаются. Новый оттенок закономерно меняет результат существующих нелинейных цветовых формул: после редактирования проверяйте визуал, не меняйте эталоны под него. Сгенерированные файлы в DerivedData не редактируйте.

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
- Ошибки начальной Metal-инициализации передаются через `throws`. Временный отказ ресурсов приостанавливает рендер: один вызов `resumeRendering()` разрешает одну повторную попытку, без автоматического цикла. Фатальная GPU-ошибка сохраняется и не сбрасывается этим методом.
- До публикации приложения разработчики должны проверить privacy manifest / required-reason API (`systemUptime`), лицензионные условия распространения, подпись и работу на реальном iPhone. Privacy manifest в этой поставке ещё не добавлен; Simulator не подтверждает производительность устройства.
- Полный GPU + Thread Sanitizer в Simulator остаётся непроверенным сценарием. Эталоны и тесты находятся отдельно в Development и требуют истории исходного репозитория.

## Полный список передаваемых файлов

Передавайте эти файлы с сохранением относительных путей:

```text
.gitignore
Configuration/YellowColors.json
GradientsKit.xcodeproj/project.pbxproj
GradientsKit.xcodeproj/xcshareddata/xcschemes/GradientsKit.xcscheme
README.md
Scripts/compose_metal.py
Scripts/compose_uikit_metal.py
Scripts/create_sdk_project.py
Scripts/source_colors.py
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
Sources/GradientsKit/GradientRenderSafety.swift
Sources/GradientsKit/GradientTheme.swift
Sources/GradientsKit/GradientViewController.swift
Sources/GradientsKit/SessionCaptionProbe.swift
Sources/GradientsKit/Shaders/GradientAdapters.metal
```
