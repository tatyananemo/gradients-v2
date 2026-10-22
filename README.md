# Gradients V2

Рабочее iOS-приложение на SwiftUI + Metal, отдельное от оригинального production.

## Запуск в Xcode

1. Откройте `GradientsV2.xcodeproj`.
2. Выберите общую схему **222** и iPhone Simulator с iOS 17.0 или новее.
3. Нажмите **Run** (`⌘R`). Приложение появится как **Gradients V2**.
4. В настройках приложения выберите светлую/тёмную тему и синий/жёлтый цвет.

Проверено с Xcode 26.3 и iPhone 14 Simulator на iOS 18.6. Для компиляции шейдеров должен быть установлен Metal Toolchain. Внешних пакетов и секретов для запуска в Simulator не требуется; подпись для этой сборки отключена. Для физического устройства потребуется настроить подпись своей командой в Xcode.

Сборка из Terminal:

```sh
xcodebuild -project GradientsV2.xcodeproj -scheme 222 \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/GradientsV2DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

## Сохранённая версия

- Все четыре темы: **Blue Dark**, **Blue Light**, **Yellow Dark**, **Yellow Light**.
- Утверждённые MAIN, Blue CONTACT и SUBSTRATE FIX, текущие Yellow CONTACT.
- Текущие цвета, геометрия, анимации, тайминги, непрерывные свайпы и автоматическая idle-волна.
- Сохранение выбранной темы и исправленный переключатель настроек.
- Постоянная градиентная подложка под нижней подписью в обеих Dark: нижние 30% экрана, чёрный от alpha 0 сверху до 0.3 снизу, без переключений и обводки букв.
- Нижний текст во всех темах: «Устанавливаем защищенное соединение. Водите пальцем в разных частях экрана».

Bundle ID: `com.local.gradients.v2`. Он отличается от оригинального production `com.local.gradientinstall`; приложения устанавливаются одновременно.

## Файлы проекта

- `_22App.swift` — точка входа.
- `GradientInstallView.swift` — текущий интерфейс, настройки и взаимодействия.
- `LiquidSpecBackground.metal` — компилируемая библиотека шейдеров всех четырёх тем.
- `ShaderSources/` — исходные модули шейдеров; их текущая композиция находится в `LiquidSpecBackground.metal`. Файлы `.source` отдельно в target не добавляются.
- `Assets.xcassets/` — ресурсы приложения.
- `GradientsV2.xcodeproj/` — проект и общая схема запуска.

Репозиторий содержит исходники. Старые QA, отчёты, видео, скриншоты, готовые `.app`, DerivedData, данные Simulator и персональные настройки Xcode исключены через `.gitignore`.
