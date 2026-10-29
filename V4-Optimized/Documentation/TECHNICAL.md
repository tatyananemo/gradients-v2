# GradientsKit V4 — техническая передача `2f12367`

## 1. Границы ответственности

Это визуальный UIKit + Metal-компонент. Не содержит КриптоПро, сетевого соединения,
криптографических операций или интеграции с фактическим completion. Не проектировать
неизвестный API КриптоПро по uniforms/сценарию Demo. Внешний продукт должен определять истинный
progress/result; нынешний `GradientSession` воспроизводит утверждённую демологику свайпов.
Публичного метода `setProgress`, binding к КриптоПро и runtime-палитры **нет**.

Основа — `2f12367`, включая source colors `54863da`, первоначальные GPU-правки `9368500`,
предрасчёт/специализацию, IOSurface, исправления resource failures из `615dfe0`, shared background,
idle-zero, tile culling, fused distortion и conservative mask ROI. Отклонённые GPU-маски,
autoreleasepool/direct-bitmap и приблизительные формы не входят в активный путь.

## 2. Действующая архитектура

```text
Host UIKit / Demo (только переключение темы, reset и опциональные измерения)
  └─ GradientViewController [UI thread, CADisplayLink, gesture recognizer, lifecycle]
      ├─ GradientSession [состояние, history, target/rendered progress, idle/release clocks]
      ├─ GradientGPU [MTLDevice, framework library, pipelines, common command queue]
      ├─ GradientPrecalculationBuffers [3 private tracked cache buffers]
      ├─ GradientMaskRenderer [3 workers, CGContext → IOSurface → CI Gaussian → textures]
      └─ SessionCaptionProbe [отдельная command queue, 360 samples → hysteresis]

Кадр: acquire slot → acquire drawable → Dark masks → axes/frame/tile prep
      → background compute → compositor (distortion fused) → present → completion frees slot
UIKit UILabel / материалы / Light caption layer находятся поверх MTKView.
```

CPU/GPU-времена здесь перекрываются: нельзя складывать mask CPU, GPU callback duration и drawable
wait и выдавать сумму за frame interval. Последовательные команды одной очереди упорядочивают
вывод масок и их последующее чтение compositor; caption работает через отдельный сериализованный
busy-пробник. Обычный кадр не ждёт GPU completion на main, но `currentDrawable` способен блокировать.

## 3. Зачем нужны шаблоны и overlays

Отдельные Swift/Metal-файлы в `GradientsKit-V4` — канонические входы. Финальный DeviceComparison
build phase вызывает `prepare_sources.py`, который читает только относительные соседние пути,
применяет принятые overlays и пишет compiler inputs в `DERIVED_FILE_DIR`. Исходники не изменяются.
Эту архитектуру не переделывали при финальной упаковке, чтобы сохранить уже проверенный результат.

| Файл / зона | Ответственность |
|---|---|
| `Core/GradientSession.swift` | Единственный владелец жестового состояния, rate limiting, easing, trail packing и 28 uniforms |
| `Core/GradientResetPresentation.swift` | Только 0,35-с presentation процента/масок, не новые физические часы |
| `GradientViewController.swift` | UIKit layout, display link, ввод, три slots, drawable, кадр, UI/lifecycle; компилируется версия после overlays |
| `GradientTheme.swift` | Две публичные темы и convenience initializer |
| `GradientGPU.swift` | Precompiled library из SDK bundle, pipelines; генерируемая версия добавляет specialization/prep |
| `GradientPrecalculationBuffers.swift` в DeviceComparison | Расчёт безопасных размеров и три private caches, encode prep; tile capacity добавляется overlay |
| `GradientMaskRenderer.swift` | Три CG/IOSurface/CI worker, fallback snapshot, masked textures; ROI добавляет окно/его origin |
| `SessionCaptionProbe.swift` | Сэмплирование зоны подписи, риск/фильтр/гистерезис/activation; не читает pixels drawable назад на CPU |
| `GradientRenderSafety.swift` | Потокобезопасная первая ошибка, раздельные fatal GPU и retryable resources; scheduling в background |
| `GradientPercentageLabel.swift` | UILabel и переход цифр reset, без SwiftUI |
| `GradientPerformanceMetrics.swift` | Ограниченные opt-in samples; не включены обычным запуском |
| `ApprovedBlue.metal.source` | Общие математика, shape pose, brightness reference, distortion, hue helpers. Название Blue историческое; нельзя удалить целиком |
| `ContactFields.metal.source` + `Shared/PhysicalFields.inc` | Геометрические/физические поля, density, interaction history; не только Blue |
| `YellowDarkMAIN/Contact.metal.source` | Отдельные Dark MAIN/readout и CONTACT, hue/energy связи |
| `YellowLightMAIN/Contact.metal.source` | Light readout, спектральные роли/насыщенность и композиция |
| `YellowShared.metal.source`, `Shared/Yellow*.inc` | Общая Yellow-математика, точные позы/волна/след, SUBSTRATE FIX |
| `V2EntryPoints.metal.source` | Точки входа сборки исходных четырёх маршрутов; публично V4 предоставляет только Yellow |
| `Shaders/GradientAdapters.metal` | Compute/fragment/vertex bridges, caption sampling; overlays формируют финальный compositor |
| `Configuration/YellowColors.json`, `Scripts/source_colors.py` | Единственные editable цвета и их build-time binding |
| `Scripts/compose_metal.py`, `compose_uikit_metal.py` | Текстовое раскрытие модулей/.inc и конфигурации без минификации |

Обязательные принятые overlays в `Development/DeviceComparison`:

- `precalculation_source.py`: 10 выражений по X, 8 по Y, 12 по кадру и 5 LayerState; function constant 101.
- `shared_background_source.py`: переиспользование уже вычисленного physical/MAIN при допустимых условиях;
  поздняя MAIN-ветка сохраняется, это не общая приближённая замена всех shape density.
- `idle_zero_source.py`: специализация существующих нулевых входов с fallback исходного пути.
- `swipe_optimization_source.py`: консервативный per-tile список возможных сегментов, исходная per-pixel проверка
  и ascending accumulation; distortion перенесён в существующий compositor с прежним half4 rounding.
- `mask_window_source.py`: консервативное неизменно размерное окно маски, sampleOrigins; при выходе поддержки — full fallback.
- `prepare_sources.py`: точный порядок комбинации и fail-fast проверки ожидаемого исходного текста.
- `prepare_demo.py`, `PhysicalRunMonitor.swift`: исходный Demo с **opt-in** физическими измерениями, не часть алгоритма SDK.

Не отключать флаги по одному в финальной схеме и не выдавать получившуюся другую конфигурацию
за эту V4. Reference/Precalc/Combined сохранены для истории сравнения, финальная — только Optimized.

## 4. Сборочная конфигурация и точность

`V4_COMPARISON_MODE=precalc`; `V4_MASK_DOMAIN`, `V4_SHARED_BACKGROUND`, `V4_IDLE_ZERO_WORK`,
`V4_SWIPE_OPTIMIZATION`, `V4_MASK_ROI` = 1. `PRECALC_COMPARISON` включён.
Release Swift `-O`, Debug `-Onone`; `MTL_FAST_MATH=YES` сохранён, precision не меняется.
Background dispatch — 8×8, округлённые uniform threadgroups; kernel проверяет границы.
Prep — 64 threads/group. Caption — 32 threads/group, 12 групп для 360 элементов и guard id≥360.
Не возвращать неподдерживаемый nonuniform dispatch, ранее выявленный Metal API Validation.

Function constant **101 = 3** у `prototypePrepareAxes` / `prototypeComputeBackground`;
**101 = 0** у `prototypeComposite` / `v2CaptionProbe`. Vertex/distortion constant не требуют.
Проверка создания compositor/probe pipeline с неправильным отсутствующим constant прежде выявляла
ошибку — нельзя просто взять optimized metallib и старую фабрику pipelines.

Целевой drawable `.bgra8Unorm`, CAMetalLayer colorspace sRGB; intermediate `.rgba16Float`.
Размер — полный native pixel viewport, не сниженный render scale. `.metallib` загружается через
`makeDefaultLibrary(bundle: Bundle(for: ...))` **из framework**, не Bundle.main. Metal/Swift outputs
получают `SourceManifest.json` с SHA-256. Публикуется исходник и сборка, готовый бинарник не коммитится.

## 5. Ресурсы, IOSurface и ошибки

Три CPU input slots (28 Float uniforms, до 240 Float history) и по одному GPU cache на каждый.
Слот отмечается занятым до `draw()` и освобождается при неотправленном кадре или main callback
завершённого compositor. Нет бесконечного семафорного ожидания main. Nil drawable не отправляет
маски и отменяет кадр. Drawable не сохраняется в долгоживущем property.

Для каждого из трёх mask workers — до двух IOSurface источников, BGRA8 premultiplied с выровненным
stride 256. CPU lock/clear/raster/unlock; повторное использование только после completed/error
соответствующего GPU command. Если поверхность занята/недоступна — неизменяемый CGImage snapshot
fallback. Gaussian выполняет Core Image с прежним color space, blur radius и transforms.
`cacheIntermediates=false` — принятое поведение динамической маски.

Источник — полоса 180 pt без обрезания существующей эллиптической геометрии. Финальное окно
вывода включает max blur, breath/drift и запас; при проверенном viewport 1170×2532 три output
маски стали 1170×1368. Это **не уменьшение разрешения или blur**: вне окна маска тождественно
прозрачна; compositor смещает координату по origin и не читает вне покрытия. При resize window
пересчитывается, небезопасная поддержка переводит в full-size fallback. Сэкономлено 32 685 120 байт
логического payload трёх FP16 textures; это не прямое обещание такого же снижения RSS/footprint.

Сохраняются и другие ранее созданные pipeline/ресурсы базового пути, даже если fused distortion
обходится без отдельного draw. Финальная передача не удаляет их и не оптимизирует заново.

Фатальная GPU ошибка фиксируется первой, новые кадры останавливаются без auto restart.
Временная недоступность ресурсов отменяет кадр и допускает одну новую попытку через явный
`resumeRendering()`; нет фонового бесконечного allocation loop. При неудачном resize старые
ресурсы сохраняются, но кадр с несовпадающим viewport не отправляется. При background сначала
приостанавливается input/display link, затем дожидаются **scheduling**, не completion, последних
масок/композиции и отдельной caption queue. В штатный каждый кадр это ожидание не добавлено.

## 6. Анимация, прогресс и данные UI

`GradientSession` — public, но не thread-safe actor; ей владеют main/один последовательный executor.
UIKit контроллер используется на main actor. Timestamp — один домен `Date.timeIntervalSinceReferenceDate`;
`systemUptime` применяется для метрик/probe dt, не подставляется вместо animation time.
Display link preferred 60 (range 30…60); MTKView isPaused=true и рисуется явно один раз на tick.
Это целевая cadence, а не гарантия actual 60 FPS. При пропуске кадра фаза считается по времени,
не добавлением фиксированного frame step.

Свайп: began/moved → session.dragChanged → point/history/energy/progress. End/cancel → dragEnded;
idle подавлен при активном пальце/settings, возобновляется через 0,42 с после release/settings.
Release delay/fade 0,30/0,82 с, history life 1,8 с; детали целевого поведения — DESIGN.md.
Progress increments каждый имеют easing 0,48 с; reset presentation 0,35 с. Нет tap-only V3.

`GradientRenderFrame` даёт UI: `progress` (target, 0…1), `time`, `dark`, `yellow`,
`uniforms`, `history`, `distortion`. `uniforms[2]` — интерполированный rendered progress;
счётчик в текущей V4 округляет `frame.progress*100`, нельзя путать их с процентом реальной операции.
`onFrame` вызывается на tick и **не подтверждает**, что кадр уже был физически показан.
Метрики presentedTime и GPU duration имеют другую семантику.

### Uniform ABI (28 Float, не новый публичный контракт интеграции)

| Индексы | Значение |
|---|---|
| 0,1 | viewport width,height в points |
| 2 | интерполированный progress |
| 3 | legacy tapPulse=0 |
| 4…7 | текущая и предыдущая normalized point |
| 8,9 | legacy swipePulse/swipeStrength=0; живой свайп идёт через history/distortion |
| 10 | elapsed от reset |
| 11…17 | progressSpeed=.150, fillGain/waveStrength/waveSpread/topBloom/whiteCore/blueDepth=1 |
| 18…22 | dragWave=0, shockStrength=.62, shockInteraction=1, shockTrail=.74, waveCount=2 |
| 23,24 | themeStrength Dark=1/Light=0, Yellow color index=3 |
| 25,26,27 | idleActivity, idleElapsed, history Float count |

Segment ABI: `[fromX,fromY,toX,toY,age,intensity]` повторяется до 40 раз.
Shader-bound uniforms/history не являются API КриптоПро и не должны редактироваться host ради progress.

## 7. Реальный публичный Swift API и UIKit containment

```swift
import UIKit
import GradientsKit

// На main actor. Не создаёт новый сетевой/криптографический процесс.
let gradient = try GradientViewController(theme: .yellowDark, initialProgress: 0)
parent.addChild(gradient)
gradient.view.frame = parent.view.bounds
gradient.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
parent.view.addSubview(gradient.view)
gradient.didMove(toParent: parent)
gradient.theme = .yellowLight
// Callbacks не должны замыкать gradient/parent сильным циклом.
gradient.onSettings = { /* host представляет свои настройки */ }
gradient.onFrame = { frame in /* наблюдение за frame.progress, не CryptoPro completion */ }
// gradient.reset(animated: true)
// gradient.pauseRendering(); gradient.resumeRendering()
```

Контроллер сам доставляет свайпы в session; нельзя отправлять те же события второй раз.
Для своего clock-driven session существует `init(session:dark:size:)` и `GradientSession(at:initialProgress:)`,
`dragChanged`, `dragEnded`, `reset`, `setSettingsVisible`, `frame(at:size:origin:dark:)`,
`targetProgress`. Изменение theme не создаёт новую session и не обнуляет progress.
`settingsVisible` нужно синхронизировать при собственном popup, как это делает Demo.
Счётчики `renderStatistics`, `beginPerformanceMeasurement/recordPerformanceInput/performanceReport`
уже присутствуют; финальная передача не добавляет новый публичный API.

**Интеграционный разрыв:** есть initialProgress и доступ только для чтения targetProgress,
но нет внешнего setter фактического progress и отключения demo gesture progress через public API.
Для продукта с КриптоПро разработчики должны отдельно определить канал реального прогресса,
отмены/ошибки/completion и согласовать адаптер. Не считать приведённый UIKit пример готовой интеграцией КриптоПро.
Не выдумывать методы конечной библиотеки и не заменять текущий алгоритм без согласования.

## 8. Цвета и параметры эффектов

`YellowColors.json` — build-time, строгая схема, RGB 0…1. Разрешены decimal literal или деление
decimal literal. `source_colors.py` сохраняет исходные выражения, раздельно привязывает Dark/Light
и компилирует CPU `GradientYellowColors.swift` с CGFloat без per-frame conversion.
Дефолтные настройки до optimized overlays дают исходный точный compiler input. При изменении
shared role binder создаёт отдельную тему только там, где нужен независимый цвет.
Полный список и defaults — DESIGN.md §10. Публичного runtime palette API нет.

Можно менять RGB MAIN, CONTACT включая скрытые hue/diffuse operands, trail, halo, mask tint/base,
Light caption tint. Это сохраняет spatial support, но итоговая яркость и оттенок после нелинейной
математики могут измениться — нужна визуальная проверка. Нельзя обещать, что один RGB изменит
все роли одновременно: trail имеет отдельные цвета, Dark/Light независимы.

Shape/движение определяют `qaMainPose*`, density/physical fields и `YellowWaveProfile.inc`.
Glow/передачу света — `sharedIdleContact`, `idleContactLight`, Yellow readouts и SUBSTRATE FIX;
blur — `GradientMaskRenderer`, exclusion масок — `v2ReadabilityMask`. Это **не** конфигурация цветов.
Не менять эти коэффициенты, gamma, Blue reference constants, alpha profile или порядок blending.

## 9. Сборка и доставка host-приложению

См. команды README. Один repo, без submodules и внешних пакетов. Файлы обязательного compiler input
перечислены в source-manifest.json. Build не читает Git, старые проекты, результаты тестов или /tmp.
Все входы package-relative. Полный чистый экспорт комплекта проверяется unsigned для generic iOS.
Конфигурация OptimizedRelease нужна и SDK, и Demo; смена scheme на базовый проект теряет оптимизации.

Для host: добавить текущий DeviceComparison project в workspace, target GradientsKit в зависимости,
framework в Embed & Sign; обеспечить выбор OptimizedRelease/OptimizedDebug для этой зависимости.
Системные frameworks: UIKit/CoreText, Foundation/CoreGraphics, Metal/MetalKit, CoreImage, IOSurface.
Нет SwiftUI в active SDK, SPM, готового XCFramework, бинарного dependency manager.
Для распространения по архитектурам device/simulator нужна отдельная согласованная упаковка;
не объявлять iPhone-only проект готовой универсальной binary distribution.

Зафиксированные два локальных dirty `.pbxproj` исходной машины не были активным Optimized build
и **не перенесены**. В финальном активном проекте изменён только общий signing config: пустой
credential-free `Signing.xcconfig` опционально включает игнорируемый LocalSigning. Это устраняет
ошибку сборки чистого checkout при отсутствии личного файла, не меняя compiler flags или исходники.

## 10. Проверки и известные границы

Доказательства предыдущих прогонов и их границы — RESULTS.md. Не обновлять эталоны под этот пакет.
724 финальных кадра и 168 масок проверены против предыдущего optimized кандидата; это не 724
полных UIKit screenshot и не новое доказательство исходной SwiftUI byte identity.
Текущая подготовка повторяет только compiler-input identity и сборку перенесённого комплекта;
FPS/thermal/GPU сценарии не запускаются заново, если бинарный shader/Swift inputs совпадают.

Работа на физическом iPhone, performance по всем размерам, длительный нагрев, дальнейшая привязка
КриптоПро, accessibility/Reduce Motion/Dynamic Type, privacy manifest/required-reason API и лицензия
распространения требуют отдельной проверки/решений владельца продукта. SDK не содержит выдуманного
privacy declaration или license grant. GPU+TSan Simulator не считается доказанным сценарием.

## 11. Точные опорные операции масок и CONTACT

Для восстановления дизайна не заменяйте три Dark-маски одной общей тенью. Их исходные размеры
в points при progress p: widths [252+20p, 204+14p, 226+18p], heights
[118+8p, 92+6p, 78+5p]; scale/breath/sx/sy и drift применяются затем в исходном порядке.
Центр привязан к counter.midX, counter.midY-18. Первые два clipped ellipses имеют radial CGGradient,
третий — tint alpha 0,22. Первая маска: alpha [.86, .72+(.62+.30p)*.10, .34+.12p, 0],
вторая [.46,.46,0]; цвета/последовательность black/tint — в исходном GradientMaskRenderer.
Gaussian radius [38,30,42]*scale*breath. Не заменять CI Gaussian на другой kernel без проверки.

После Dark backing применяются readability exclusion и premultiplied маски a,b,d в порядке:

    c.rgb = a.rgb + c.rgb*(1-a.a)
    c.rgb = b.rgb*c.rgb + c.rgb*(1-b.a)
    c.rgb = d.rgb + c.rgb - d.rgb*c.rgb

Это normal → multiply → screen при существующем premultiplied соглашении. Mask ROI меняет только
координаты и гарантированно нулевое покрытие, а не формулы. Перестановка операций меняет картинку.

Общий CONTACT: coverage=clamp(mainDensity,0,1), intersection=coverage*idleDensity,
frontReaction=intersection*(1-coverage). sharedIdleContact сохраняет исходное разбиение плотности.
Dark — положительная световая реакция с прежним saturation/hue readout. Light — оригинальная
пигментная композиция, contact peak и SUBSTRATE FIX (Shared/YellowLightSubstrate.inc). Ни эти
операции, ни blue reference luminance не являются доступной пользователю настройкой цвета.
