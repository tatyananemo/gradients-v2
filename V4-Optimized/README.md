# GradientsKit V4 — финальная передача

UIKit + Metal UI биодатчика, **Yellow Dark / Yellow Light**, на основе проверенного
`2f123671b49d6dd139a3dc3cb7b72caa7f6d772a`. Ветка передачи: `delivery/v4-final-2f12367`.
Это фиксация текущего результата, а не заявление о достижении 60 FPS.

- [Целевая дизайн-спецификация](Documentation/DESIGN.md): внешний вид, состояния, жесты, ограничения текущей версии.
- [Техническая документация](Documentation/TECHNICAL.md): архитектура, API, ресурсы, интеграционные границы.
- [Результаты и открытые вопросы](Documentation/RESULTS.md).
- [Визуальные референсы](Documentation/References/README.md) — существующие утверждённые изображения, без новых рендеров.
- [Файлы и контрольные суммы](Documentation/source-manifest.json).

## Что открывать

**Актуальная оптимизированная V4:** `Development/DeviceComparison/V4DeviceComparison.xcodeproj`,
схема **V4 Optimized**, Release-конфигурация **OptimizedRelease** (Debug — OptimizedDebug).
Схема запускается без LLDB, по умолчанию Yellow Dark / 0%, без автосвайпов и измерителя.
Название приложения — V4 Optimized; bundle ID — `com.local.gradients.v4.compare.precalc`.
Запуск на собственном устройстве выполняйте сознательно: этот ID заменяет установленную V4 Precalc/Optimized.
Сборка из команд ниже ничего не устанавливает и не запускает.

**Не используйте для финальной версии** старые схемы V4 Reference / Precalc / Combined,
`Development/UIKitDemo/GradientsUIKitV4.xcodeproj` или `GradientsKit-V4/GradientsKit.xcodeproj`:
они сохранены для исходной реализации и проверок, но не включают все оптимизации `2f12367`.
Вложенный `GradientsKit-V4/README.md` также сохранён как историческая инструкция базового SDK;
для финальной передачи приоритет имеют этот README и Documentation/TECHNICAL.md.

## Комплект и зависимости

```text
GradientsKit-V4/             исходные Swift/Metal-модули, .inc, цвета и базовые composers
Development/DeviceComparison/  обязательные overlays, кэш предрасчёта, актуальный Xcode project
Development/UIKitDemo/       один исходник Demo, компонентные/UI-тесты; не копия SDK
Development/Validation/      исторические неизменяемые эталоны и инструменты доказательства
Documentation/              дизайн, техника, результаты, референсы и provenance
Tools/                      проверка полноты и воспроизводимая unsigned-сборка передачи
```

Передавайте **весь checkout этой ветки**, сохраняя относительные пути. Папка `GradientsKit-V4`
сама по себе собирает базовую V4, а не оптимизированную `2f12367`. Не удаляйте Development/DeviceComparison:
часть действующих Metal-алгоритмов находится в его сборочных overlays. Это известная граница упаковки.
Другие локальные V2/V3, временные каталоги и установленный Simulator для сборки не нужны.
Исторические проверки Git-эталонов требуют полного clone, не shallow/ZIP; обычная сборка работает и из ZIP.

Нужны macOS, Xcode с iOS SDK и Metal Toolchain, выбранный через `xcode-select`, Python 3
(`/usr/bin/python3` Command Line Tools). Проверено Xcode 26.3 (17C529), deployment target iOS 17.0+.
Сторонних пакетов/подмодулей нет. Metal Toolchain при необходимости устанавливается из Xcode → Settings → Components.

## Сборка без устройства, Simulator и подписи

Из корня репозитория, в выбранную новую папку вне checkout:

```sh
python3 -B Tools/verify_delivery.py
python3 -B Tools/build_release.py --derived-data /tmp/v4-delivery-release
python3 -B Tools/build_release.py --derived-data /tmp/v4-delivery-debug --configuration OptimizedDebug
```

Release script проверяет идентичность compiler input, собирает SDK + Demo для generic iOS,
проверяет размер `default.metallib` ≤500 000 байт и сохранённый SHA-256 проверенного артефакта.
Результат: `<derived-data>/Build/Products/OptimizedRelease-iphoneos/GradientsKit.framework/`;
Demo — `GradientsV4Comparison.app`, библиотека также вложена в её Frameworks.
Не складывайте размеры двух копий одной metallib.

Эквивалентная команда Xcode:

```sh
xcodebuild -project Development/DeviceComparison/V4DeviceComparison.xcodeproj \
  -scheme 'V4 Optimized' -configuration OptimizedRelease \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/v4-delivery-release \
  CODE_SIGNING_ALLOWED=NO build
```

Для device-запуска выберите свой Team в Xcode либо создайте игнорируемый
`Development/DeviceComparison/LocalSigning.xcconfig` с `DEVELOPMENT_TEAM = YOUR_TEAM_ID`.
Общий `Signing.xcconfig` подключает его опционально. Сертификаты, provisioning и личный Team не поставляются.
Не меняйте алгоритмы или compiler flags ради подписи. При необходимости восстановить Xcode project:
`python3 -I -B Development/DeviceComparison/create_project.py`.

## Исходные цвета

Один файл: [`GradientsKit-V4/Configuration/YellowColors.json`](GradientsKit-V4/Configuration/YellowColors.json).
Секции `dark` / `light` независимы; значения — строки исходных выражений Float/CGFloat, не HEX.
Например, для будущего согласованного изменения только ядра Dark:

```json
"contactCore": ["1.0", "220.0 / 255.0", "45.0 / 255.0"]
```

Это **пример**, в поставке остаётся `221.0 / 255.0`. После изменения пересоберите SDK и согласуйте
новый визуал. Проверки Tools/verify_delivery.py и Tools/build_release.py намеренно фиксируют
исходные defaults 2f12367: после согласованной смены цвета они сообщат о расхождении.
Для новой палитры используйте приведённую прямую команду xcodebuild; не перезаписывайте
эталоны или manifest, чтобы скрыть изменение. JSON читается только сборкой. Нет runtime-палитры, setPalette, новых passes или per-frame uploads.
Не меняйте Blue reference, gamma, маски, яркость или геометрию вместо цветовых ролей. Полный список ролей — в DESIGN.md.

## Использование

Добавьте **актуальный** DeviceComparison Xcode project в workspace host-приложения,
свяжите target GradientsKit и Embed & Sign framework, выбирайте OptimizedRelease/OptimizedDebug
при сборке зависимости. Не подключайте второй одноимённый framework из базового проекта.
Пример UIKit containment и точные ограничения прогресса — в TECHNICAL.md.
SPM/XCFramework пока не поставляются. КриптоПро не входит в комплект: он контролирует фактическое
завершение; существующая демонстрационная модель увеличивает прогресс свайпами и ещё не имеет
публичного setter для внешнего прогресса. Контракт с конечным продуктом нужно согласовать отдельно.

## Текущий статус

Release metallib **491 804 байта** (0,491804 МБ); исходники Swift/Metal **5 391 строка**
по указанному в RESULTS.md правилу подсчёта. iPhone 14: Dark 45,2–45,5 FPS / Light 57,9 FPS
в коротких свайп-прогонах со старта 63%. Длительный нагрев этой версии не подтверждён как устранённый.
Результаты Mac не являются доказательством 60 FPS на iPhone. См. RESULTS.md перед интеграцией.
