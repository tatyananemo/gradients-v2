# V4: подготовка сравнения на iPhone

Открыть `V4DeviceComparison.xcodeproj`. Этот проект находится только в экспериментальной ветке. Он читает утверждённые исходники `GradientsKit-V4`, но не записывает изменения в SDK или основной Demo.

| Схема | Run | Название на телефоне | Bundle ID |
|---|---|---|---|
| V4 Reference | ReferenceRelease, без LLDB | V4 Reference | com.local.gradients.v4.compare.reference |
| V4 Precalc | PrecalcRelease, без LLDB | V4 Precalc | com.local.gradients.v4.compare.precalc |

Обе версии используют один существующий `UIKitDemo/AppDelegate.swift`, одинаковые жесты, Core-состояние, прогресс, idle, подпись, маски, IOSurface и UIKit. Схемы задают одинаковые начальные Dark / 0%; дополнительных контролов и автоматического benchmark при обычном запуске нет. Текущая установленная Demo имеет другой bundle ID и не перезаписывается.

## Что меняется только в тестовой сборке

Build phase генерирует в `DERIVED_FILE_DIR` Metal, GPU-конфигурацию и два Swift-файла рендера. Reference копирует утверждённую реализацию. Precalc использует побайтово тот же Metal-исходник, который прошёл визуальное сравнение:

- SHA-256 Reference Metal: `6543c25f9bf24ccd7b58cd8e08e8711f599c97e9dcdcfdf0d3ae60714e713bea`.
- SHA-256 Precalc Metal: `06145e07ae6d8723e81a17741ec48905637e8365e8816fce35a39e797adb2e06`.
- function constant 101 = **3** у `prototypePrepareAxes` и `prototypeComputeBackground`.
- function constant 101 = **0** у compositor и caption probe: этим путям нужен исходный расчёт без кэша.
- Distortion и vertex не требуют этого function constant.

Предрасчёт и background кодируются в одном command buffer, последовательно, с отслеживаемыми Metal-ресурсами. На каждый из трёх in-flight слотов выделяется отдельный private-буфер. При 1170×2532 это 128 968 байт на слот, 386 904 байта суммарно (около 378 КиБ), без новых текстур. На каждом кадре буфер полностью заполняется в используемых диапазонах; остаток истории вне её текущего count не читается.

Кэши создаются вместе с новой парой текстур. При отказе новая группа не публикуется, старая сохраняется, и несовпадающие размеры не используются. Уже отправленные команды удерживают свои ресурсы при resize. Nil drawable отменяет кадр до предрасчёта; in-flight слот освобождается существующим путём. Фатальные/временные ошибки и обработка background остаются исходными. Нет GPU-ожиданий, новых CPU bitmap-копий или переустройства IOSurface-пула.

## Сборка и подпись

Deployment target — iOS 17+, проект предназначен для физического iPhone (`iphoneos`). Run обеих схем — обычный Release (`-O`) без отладчика; `MTL_FAST_MATH` сохранён. Публичные Swift-интерфейсы A/B совпадают.

Локальный Personal Team берётся из `LocalSigning.xcconfig`. Этот файл исключён из Git. При переносе проекта можно скопировать `Signing.example.xcconfig` в `LocalSigning.xcconfig` и выбрать свой Team. Проверенные здесь `.app` собраны с `CODE_SIGNING_ALLOWED=NO`; подпись и provisioning для новых bundle ID выполняются перед разрешённой установкой. Установка и запуск на iPhone/Simulator на этом этапе не выполнялись.

После отдельного разрешения на устройство: выбрать соответствующую схему и iPhone 14; подписать и установить A/B. Для визуального сравнения полностью завершать предыдущую версию, давать телефону остыть, использовать одинаковые яркость и режим питания. В обеих версиях выбрать одинаковую тему, сбросить прогресс и сравнить 15–20 секунд idle, затем одинаковые свайпы/hold/release/reset. Повторить для Light. При запуске с домашнего экрана тема может сохраниться отдельно для каждого приложения: её нужно проверить в существующих настройках.

Для одинакового автоматизированного сценария уже существующий Demo поддерживает `GRADIENTS_DIAGNOSTICS=1`, `GRADIENTS_BENCHMARK=1`, `GRADIENTS_BENCHMARK_DURATION=20`, `GRADIENTS_BENCHMARK_IDLE_ONLY=1`; эти параметры **не включены** в обычных схемах. Не включать их без согласования контрольного запуска.

## Проверки подготовки

- A/B SDK + Demo: Debug и Release для generic iOS — build passed.
- Компонентные/UI bundles: Debug/Release — build-for-testing passed; не выполнялись на устройстве.
- 5 CPU-контрактов новой интеграции, включая mock-ресурсы в `-Onone`/`-O`, passed.
- Исходные проверки цветов (5), GPU-resource safety (2), поведения и reset в Debug/Release passed.
- Исходная неизменённая версия: 216 исторических GPU-выходов + 108 Yellow, 72 adapters и 168 mask/reuse comparisons passed на Mac.
- Оптимизированная интеграция: настоящий runtime cache helper дал те же 132 пары композиций, что были просмотрены (528 raw comparisons: BGRA8 и диагностический RGBA16F для A/B).
- GPU Mac: 36 точных сравнений трёх in-flight слотов, повторного использования и resize с освобождением старого владельца passed.
- Эталоны не обновлялись. Кандидат не объявляется pixel-exact относительно исходной V4: использован ранее просмотренный результат с разницей до 1/255 в BGRA8.

Подробные логи текущей подготовки: `/private/tmp/v4-device-build-20261028/`. Это не подтверждение плавности, температуры или 60 FPS на iPhone. На первом разрешённом запуске остаётся проверить создание precompiled pipeline на A15, реальный UIKit, frame pacing, thermal и память.

Генерация проекта: `python3 -B Development/DeviceComparison/create_project.py`. Код SDK не копируется в поддерживаемые исходники эксперимента; изменённые Swift/Metal-файлы создаются только сборкой. `.app`, DerivedData, подпись и результаты тестов в Git не включаются.

## Combined device candidate

`V4 Combined` / `CombinedDebug` / `CombinedRelease` collects the existing source
color configuration (54863da), verified lazy Dark/8×8 changes (9368500 ancestry),
reviewed axis/frame precalculation with proper pipeline specialization, and the
finite mask-domain trial (8094673). No rejected local-mask or extra-idle-cache
trial participates. Bundle ID `com.local.gradients.v4.compare.combined` is distinct
from production, V4, Reference and Precalc. Reference/Precalc settings stay unchanged.
`V4_MASK_DOMAIN=1` is the default only for Combined; source colors remain in
`GradientsKit-V4/Configuration/YellowColors.json`, consumed at build time.
Combined's compiler-input manifest, Release metallib and public interface match
the previously checked Precalc + finite-domain build. Existing differential bounds
remain: final BGRA8 ≤1/255; raw masks are not exact. No new performance claim is made.
Generic-iOS Debug and signed Release and seven CPU preparation contracts pass.
No app is installed/launched as part of preparation; a physical-device comparison
and a 60-FPS/thermal claim still require explicit authorization and measurement.
