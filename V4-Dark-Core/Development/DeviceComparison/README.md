# Актуальная финальная V4 — схема V4 Optimized

Текущий исходный кандидат `1b3c287`: оба ускорения (индивидуальные mask ROI, Dark route),
заполнение 9–10 с из `9eb2ecc`, source colors и прежние оптимизации сохранены.
Соседний `../../GradientsKit-V4` находится внутри V4-Optimized, не в старой V4 из корня Git.
Открывайте `V4DeviceComparison.xcodeproj`, выбирайте V4 Optimized / OptimizedRelease.
V4 Reference, V4 Precalc и V4 Combined — прежние контрольные варианты, не текущая передача.

Полная инструкция: [корневой README](../../README.md).
Архитектура и все build flags: [TECHNICAL.md](../../Documentation/TECHNICAL.md).
Измерения/границы: [RESULTS.md](../../Documentation/RESULTS.md).

`Signing.xcconfig` не содержит Team и опционально подключает игнорируемый LocalSigning.xcconfig.
Для generic-iOS unsigned build файл с личными настройками не нужен. Не коммитите его, сертификаты,
provisioning или UDID. `Signing.example.xcconfig` показывает формат.

Обычная схема не включает benchmark/telemetry. PhysicalRunMonitor действует только при явно
указанных тестовых переменных; финальная подготовка не запускает их и не ставит приложение.
Compiler inputs генерируются в DERIVED_FILE_DIR из соседнего GradientsKit-V4 и текущих *.py overlays;
они все входят в исходный комплект. Не копируйте только базовую папку SDK вместо всей передачи.
