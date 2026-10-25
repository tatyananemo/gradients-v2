# GradientsKit V4 — Yellow

Самостоятельная UIKit + Metal-версия из стабильного `5847060` (`stabilization/gradientskit-sdk`). Экспериментальные изменения не включены. В приложении и публичном API доступны только **Yellow Dark** и **Yellow Light**. При первом запуске — Yellow Dark.

## Запуск

1. Откройте `UIKitDemo/GradientsUIKitV4.xcodeproj` в Xcode.
2. Выберите scheme **GradientsUIKitV4**, конфигурацию Debug или Release и iPhone Simulator с iOS 17+.
3. Запустите приложение **GradientsKit V4**. Для сборки только SDK выберите **GradientsKit**.

Demo bundle ID: `com.local.gradients.v4.uikit`; SDK: `com.local.gradients.v4.kit`. Они не совпадают с production, V2 или V3. Выбор Light/Dark сохраняется обычной настройкой Demo; выбора цвета нет. Управление — непрерывные свайпы, без механики тапов V3.

Формулы Metal, MAIN, CONTACT, SUBSTRATE FIX, маски, Gaussian blur, смешивание, разрешение, подпись и поведение перенесены без изменений. Общая Metal-библиотека сохранена целиком, включая вычисления в файлах `ApprovedBlue` и `ContactFields`: удаление по названию небезопасно и не относится к этой задаче. Синие темы не доступны через публичный API или Demo.

`UIKitComponent` — SDK без SwiftUI. `Validation/ReferenceV2` — неизменённые исходники старого SwiftUI-эталона, только для регрессионных проверок; они не входят в V4 targets. Исторические материалы Validation сохранены как история, их capture/video/HTML-инструменты для V4 не запускались. Для текущей проверки используйте:

```sh
python3 -B Validation/validate.py --no-images --output /tmp/v4-gpu-check
python3 -B Validation/UIKitMigration/validate_session.py
python3 -B Validation/UIKitMigration/validate_presentation.py
python3 -B Validation/UIKitMigration/validate_masks.py --accepted-uikit
python3 -B Validation/Performance/validate_mask_reuse.py
```

Эталоны и допуски не перезаписываются. Полная каноническая библиотека проверяется всеми 216 прежними GPU-выходами, включая 108 выходов Yellow. Поведение публичного V4 API и оба режима проверяются unit/UI-тестами проекта. Удержание, release, idle, reset и скорость progress сохранены. Simulator не заменяет проверку производительности на физическом iPhone.

Проект воспроизводимо генерируется `python3 -I -B Scripts/create_uikit_project.py`. Сборки и `default.metallib` создаются в DerivedData; внешние исходные папки V2/V3/refactor не требуются. Локальная Git-история включена независимо, remotes отсутствуют; ничего не опубликовано.
