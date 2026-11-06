# V4-Yellow-Core — Biosensor Yellow

Компактный исходный SDK для визуального биосенсора UIKit + Metal:

- **Dark** — первый оптимизированный Dark со светлым центром, в котором утверждённые цветовые точки касания заменены на жёлтый `#FFDD2D`. MAIN и IDLE сохранены.
- **Light** — последняя оптимизированная реализация из `d62ae67`, без визуальных изменений.
- Результат генерации совпадает с утверждённой Biosensor Yellow: 12 Swift-файлов и один развёрнутый Metal-файл. Release `default.metallib`: **346 444 байта**, SHA-256 `a1332fc32c901811c2c1611826547aede17267294c74a891272718d2f48f1985`.

Пакет содержит SDK, авторские исходники, конфигурацию и необходимые сборочные генераторы. Demo, временный измеритель 0–100%, автосвайпы, тестовые отчёты, локальные логи, готовые экспериментальные приложения и личная подпись не входят. Существующие отключаемые метрики базового SDK сохранены: это часть уже утверждённых Swift-входов, а не добавленный временный измеритель.

## Структура

```text
V4-Yellow-Core/
├── README.md
├── BiosensorYellowSDK.xcodeproj/
├── GradientsKit-V4/
│   ├── Sources/GradientsKit/       # базовые Swift и Metal-адаптер
│   ├── ShaderSources/             # авторские Metal-модули и Shared/*.inc
│   ├── Configuration/YellowColors.json
│   └── Scripts/                   # композиция Metal и привязка цветов
├── Development/DeviceComparison/  # только сборочные генераторы и cache-буфер SDK
├── Tools/                        # генерация, проверка входов, Release-сборка
└── Verification/source-manifest.json
```

Название `Development/DeviceComparison` сохранено для исходных относительных импортов. Здесь **нет Demo**: лежащие внутри генераторы и `GradientPrecalculationBuffers.swift` являются необходимыми входами оптимизированного SDK. Передавайте всю папку `V4-Yellow-Core`, а не только вложенную `GradientsKit-V4`.

Манифест содержит эталонные хеши исходников и ожидаемого артефакта; это сборочные метаданные, не отчёт прогона на устройстве. Все пути проекта относительные. Соседние версии, Git-репозиторий и временные локальные файлы для сборки не требуются.

## Требования

- iOS **17.0+**, UIKit-приложение и поддержка Metal на целевом устройстве.
- Для воспроизведения зафиксированного бинарного результата: **Xcode 26.3 (17C529)**, iPhoneOS SDK 26.2, установленный компонент **Metal Toolchain**, сборка arm64 для `iphoneos`.
- Python **3.9+**, только стандартная библиотека. Xcode build phase вызывает `/usr/bin/python3`; проверьте доступность Python и выбранного Xcode через Command Line Tools.
- Системные frameworks: UIKit, Foundation, Metal, MetalKit, Core Image, Core Graphics и IOSurface. Внешние Swift-пакеты и pip-зависимости не нужны.

Python и JSON используются **при сборке**. Их нет в runtime-зависимостях приложения. Другой Xcode/Metal-компилятор может создать иной бинарный результат: для него нужна отдельная проверка, а не автоматическая замена эталонного хеша.

## Генерация и Release-сборка

1. Полностью распакуйте ZIP.
2. Откройте `BiosensorYellowSDK.xcodeproj`.
3. Выберите схему **Biosensor Yellow SDK**, конфигурацию **Release** и назначение **Any iOS Device (arm64)**.
4. Выполните **Product → Build** (`⌘B`). Build phase автоматически генерирует Swift/Metal в DerivedData и собирает `GradientsKit.framework`. Это framework-проект: самостоятельного приложения и команды Run для iPhone здесь нет.

Из корня `V4-Yellow-Core` можно явно выполнить:

```sh
# Проверка авторских входов и идентичности генерируемых исходников.
python3 -B Tools/verify_sources.py

# Только генерация для просмотра. Не добавляйте эти файлы вторым набором в target.
python3 -B Tools/generate_sdk.py --output /private/tmp/v4-yellow-generated

# Автономная Release-сборка с проверкой размера и SHA-256 metallib.
python3 -B Tools/build_release.py --derived-data /private/tmp/v4-yellow-release
```

Результат последней команды: `/private/tmp/v4-yellow-release/Build/Products/Release-iphoneos/GradientsKit.framework`, включая `default.metallib`. Лог/результат этой проверки создаётся только во внешней DerivedData-директории и не является частью поставки.

Базовые `GradientGPU.swift`, `GradientViewController.swift` и `GradientMaskRenderer.swift` преобразуются генератором. Xcode уже компилирует правильные сгенерированные версии. Не добавляйте одновременно базовые и развёрнутые копии. `.metal.source` и `.inc` нельзя компилировать как отдельные Metal translation units: их собирает генератор в `GradientsUIKit.metal`.

## Подключение к существующему приложению

1. Скопируйте всю папку `V4-Yellow-Core` в исходники приложения и добавьте `BiosensorYellowSDK.xcodeproj` в общий Xcode workspace или как project reference.
2. В target приложения добавьте зависимость **GradientsKit** и продукт `GradientsKit.framework` в **Frameworks, Libraries, and Embedded Content → Embed & Sign**.
3. При Release-сборке приложения зависимость SDK также должна собираться в **Release**. Если у приложения собственные имена конфигураций, настройте их соответствие; для этого SDK стандартные конфигурации — Debug/Release.
4. Настройте Team и Bundle Identifier **своего приложения**. SDK по умолчанию собирается без подписи, подпись вложенного framework выполняется при Embed & Sign в host-приложении. Сертификатов и provisioning profiles автора в пакете нет.
5. Передавайте в приложение framework целиком с его `default.metallib`; не удаляйте Metal-библиотеку. Для устройства нужен продукт `iphoneos/arm64`; готовый SPM-пакет и XCFramework не поставляются. Поддержка Simulator в этой поставке не заявлена — проект настроен на `iphoneos`.

Ниже пример обычного UIKit containment. `onVisualCompletion` — явно объявленный callback приложения, **не новый API SDK**.

```swift
import UIKit
import GradientsKit

@MainActor
final class BiosensorHostViewController: UIViewController {
    private var biosensor: GradientViewController?
    private var completionHandled = false

    // Callback самого приложения, не метод SDK.
    var onVisualCompletion: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        do {
            let component = try GradientViewController(
                theme: .yellowDark, initialProgress: 0
            )
            biosensor = component
            component.onFrame = { [weak self] frame in
                guard let self, !self.completionHandled,
                      frame.progress >= 1 else { return }
                self.completionHandled = true
                self.biosensor?.pauseRendering()
                DispatchQueue.main.async { [weak self] in
                    // Здесь приложение завершает сценарий и открывает следующий экран.
                    self?.onVisualCompletion?()
                }
            }
            addChild(component)
            component.view.frame = view.bounds
            component.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(component.view)
            component.didMove(toParent: self)
        } catch {
            // Пример ошибки инициализации Metal: приложение выбирает свой fallback UI.
            let label = UILabel(frame: view.bounds.insetBy(dx: 24, dy: 100))
            label.numberOfLines = 0
            label.text = "Не удалось запустить биосенсор: \(error)"
            view.addSubview(label)
        }
    }

    func setLightAppearance(_ light: Bool) {
        biosensor?.theme = light ? .yellowLight : .yellowDark
    }
}
```

Создавайте и используйте контроллер на main actor. SDK сам принимает непрерывные свайпы: не отправляйте те же касания повторно через `session.dragChanged(...)`. `onSettings` можно использовать для интерфейса настроек самого приложения; если открывается панель поверх биосенсора, состояние сессии переключается существующим `session.setSettingsVisible(_:at:)`, где время — `Date().timeIntervalSinceReferenceDate`.

## Прогресс и завершение: фактические возможности API

| Задача | Существующий интерфейс |
|---|---|
| Создать компонент / задать стартовую долю | `try GradientViewController(theme:initialProgress:)`, доля `0...1` |
| Переключить тему | `component.theme = .yellowLight` / `.yellowDark` |
| Читать прогресс | `component.session.targetProgress` — только чтение; `component.onFrame` → `frame.progress` |
| Получать состояние кадров | `onFrame: ((GradientRenderFrame) -> Void)?` |
| Приостановить / продолжить | `pauseRendering()` / `resumeRendering()` |
| Начать заново | `reset(animated:)` |
| Обработать кнопку настроек | `onSettings: (() -> Void)?` |

`frame.progress` — целевой прогресс сессии в диапазоне `0...1`; процентный индикатор строится по нему. Геометрия жидкости догоняет его с исходным сглаживанием. `onFrame` сообщает о формировании кадра, а не о подтверждённом GPU-показе.

**При достижении 100% продукт завершает сценарий и открывает следующий экран.** В примере это одноразовая проверка `frame.progress >= 1`, приостановка рендера и callback host-приложения. Сам SDK не выполняет навигацию и не имеет отдельного `onCompleted`. Не включайте продолжающийся после 100% idle/угасание в обязательный продуктовый сценарий. При уходе со страницы корректно удаляйте дочерний контроллер или закрывайте host; lifecycle-обработка сохранена.

### Что пока отсутствует для внешнего управления прогрессом

Публичного `setProgress(...)` или setter для текущего прогресса **нет**. `initialProgress` задаётся только при создании; `targetProgress` и `frame.progress` доступны только для чтения. В этой реализации визуальный прогресс по-прежнему накапливается существующей логикой свайпов.

Поэтому передавать текущие значения из внешнего источника (например, фактического процесса сбора энтропии) через готовый публичный API сейчас нельзя. Для такого подключения нужен отдельно согласованный API/адаптер. В поставке он не добавлялся; обход через изменение внутренних `uniforms`, подмену жестов или ускорение прогресса не предлагается.

SDK не вызывает КриптоПро и не подтверждает достаточность криптографической энтропии. Приложение связывает визуальный сценарий с реальным процессом и выполняет переход на основании логики продукта. Пример выше показывает завершение **визуального** сценария, а не API внешней библиотеки.

## Цвета и сохранение оптимизаций

- Базовые авторские настройки цветов: `GradientsKit-V4/Configuration/YellowColors.json`, независимые секции Dark/Light. Это конфигурация исходников с пересборкой, не runtime API.
- Утверждённые точки жёлтого центра Dark: `GradientsKit-V4/ShaderSources/Shared/YellowDarkTouchColor.inc`. Фрагмент применяется к двум исходным Dark-путям; Light не меняется.
- Не редактируйте generated-файлы в DerivedData. Любое преднамеренное изменение цвета закономерно нарушит сравнение с замороженным манифестом и требует отдельного визуального согласования.
- Для сохранения проверенной версии оставляйте весь существующий pipeline генераторов: precalculation, shared background, idle-zero, swipe, mask window, Dark/Light route specialization и Yellow touch. Не заменяйте его прямой компиляцией только базовых Swift/Metal-файлов.
- Сохраняйте function constants 101/102, раскладку cache-буфера, размер/точность текстур, IOSurface-пул, число кадров in-flight, границы dispatch и обработку ошибок Metal.
- Blue-названные файлы содержат общую математическую геометрию и опорные вычисления, необходимые Yellow. Это не необязательная старая тема для удаления.

## Размер исходников

По прежней методике V4 Optimized — физические строки с комментариями и пустыми строками, `.inc` один раз:

| Авторский код | Файлы | Строки |
|---|---:|---:|
| Swift | 11 | 1 433 |
| Metal, `.metal.source` и `.inc` | 17 | 3 959 |
| **Всего** | **28** | **5 392** |

Python-инструменты сборки/проверки считаются отдельно: **15 файлов, 942 строки**. JSON, документация и сгенерированные входы не входят в исторический счётчик Swift/Metal. Развёрнутый набор содержит 1 506 строк Swift и 8 223 строки Metal; он генерируется при сборке, а не дублируется в исходном дереве.
