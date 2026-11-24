# Biosensor Contest для iOS 26

Конкурсное UIKit-приложение с утверждённым [V4-Yellow-Core](../README.md). В светлой теме используется оптимизированный Light из `d62ae67`, в тёмной — Yellow Dark с жёлтым центром касания `#FFDD2D`. Обе схемы запускаются в Release.

## Требования

- macOS и Xcode 26.3 с компонентом **Metal Toolchain**. Для сборки требуется системный `/usr/bin/python3` версии 3.9 или новее.
- Физический iPhone с iOS 26.0 или новее. Прототип проверялся на iPhone 14 с iOS 26.7.
- Mac с Apple Silicon для Simulator. Установите iOS 26 Simulator Runtime в **Xcode → Settings → Components**. Прототип проверялся в iOS 26.3 Simulator.

## Открытие проекта

Клонируйте репозиторий с веткой `packaging/v4-yellow-core` или распакуйте ZIP этой ветки целиком. В `V4-Yellow-Core/Biosensor-Contest-iOS26` откройте `BiosensorContest.xcodeproj`. Проект берёт SDK из родительской папки `V4-Yellow-Core` и генерирует утверждённые Swift/Metal-входы при сборке. Сохраните структуру этой папки при переносе проекта.

| Назначение | Схема Xcode | Имя на экране «Домой» | Bundle ID по умолчанию |
| --- | --- | --- | --- |
| Физический iPhone | **Biosensor Contest** | Biosensor Contest | `com.local.gradients.biosensor.contest` |
| Simulator 1 | **Biosensor Contest** | Biosensor Contest 1 | `com.local.gradients.biosensor.contest.sim1` |
| Simulator 2 | **Biosensor Contest 2** | Biosensor Contest 2 | `com.local.gradients.biosensor.contest.sim2` |

На iPhone и в Simulator 1 инструкция — «Устанавливаем защищенное соединение. Водите пальцем в разных частях экрана». В Simulator 2 текст отображается с фиксированными переносами.

```text
Создаем уникальный ключ
для подписи. Водите пальцем
в разных частях экрана
```

## Запуск на iPhone

1. Подключите и разблокируйте iPhone. При первом подключении подтвердите доверие к Mac. Если Xcode попросит, включите **Developer Mode** на iPhone.
2. В Xcode выберите target **Biosensor Contest → Signing & Capabilities**. Оставьте **Automatically manage signing** включённым и выберите свою **Team**. Если ваша команда не может зарегистрировать исходный Bundle ID, укажите уникальный идентификатор для конфигурации iPhone.
3. Выберите схему **Biosensor Contest**, назначение с именем своего iPhone и **Product → Run** (⌘R). При запуске с иконки отображается первый текст.

## Запуск в Simulator

1. Выберите один и тот же iPhone Simulator с iOS 26 как назначение сборки.
2. Запустите схему **Biosensor Contest** через **Product → Run**. Она установит **Biosensor Contest 1**.
3. Запустите схему **Biosensor Contest 2** на том же Simulator. Обе версии будут доступны с экрана «Домой» одновременно.

## Проверка интерфейса

- Тема выбирается в **Настройки → Экран и яркость** на iPhone и автоматически применяется к биосенсору. В Simulator также можно переключить системный Appearance через **Features → Toggle Appearance**.
- Свайп пальцем увеличивает прогресс. Крестик сбрасывает прогресс до 0% и очищает след касания. Биосенсор сразу готов к новому свайпу.
- У всех трёх сборок жёлтая иконка «100%». Статус-бар и Home Indicator рисует iOS.
