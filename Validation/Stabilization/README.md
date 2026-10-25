# GradientsKit: стабилизация UIKit + Metal

Ветка `stabilization/gradientskit-sdk`. Эталон `3a719cc`; откат — `stabilization/gradientskit-approved-20261025`. Оригинальные V2, V3, production, SwiftUI-эталон, Core и канонические Metal-модули не изменены. Защищённые хеши: V2 15/15, production 9/9, V3 15/15. Исходное незакоммиченное `.agents/` содержит пользовательские скиллы и сохранено отдельно от исходников.

## Подтверждённые исправления

1. Устаревший GPU-результат подложки мог примениться после смены темы: ключ теперь инвалидируется до проверки busy. До исправления тест получал blue вместо yellow.
2. Скрытый/неактивный компонент продолжал готовить маски, прерванный жест оставался активным. SDK самостоятельно учитывает app/scene, видимость, detach и исчезновение; пауза закрывает жест существующим dragEnded. Пустые и субпиксельные bounds не создают недопустимые текстуры.
3. При дробных bounds маски округлялись вниз, drawable вверх. Размеры теперь совпадают; при эталонных целых размерах результат побайтово прежний.
4. reset(animated: false) не отменял уже начатую анимацию цифр. Теперь явный сброс без анимации немедленный; обычный reset остаётся 0,35 с.
5. Bounds могли измениться до UIKit layout-pass: маски 781×1689 сочетались с drawable 750×1334. Layout ресурсов синхронизируется перед построением/рендером кадра, без изменения формул геометрии.

## Измерения Simulator

Mac M3 Pro, iPhone 14 / iOS 18.6, 1170×2532. Короткий прогон 20 с; длинный 75 с после 3 с warmup: idle → 61 с непрерывного ввода → hold → release → idle. Дополнительно 75 с чистого idle. Длинные данные сняты до последней синхронизации viewport, при неизменном viewport 390×844; итоговый короткий прогон повторён после неё.

**FPS здесь — частота GPU-completion callback, а не физически измеренная частота экрана.** CPU — подготовка кадра; GPU — суммарная работа команд масок/композиции. Задержка — последний полученный/синтетический ввод → callback, не камера touch-to-display. [Ограничения Metal Simulator](https://developer.apple.com/documentation/metal/developing-metal-apps-that-run-in-simulator).

| Тема | FPS long / final short | Кадр p95 / p99, мс | CPU / GPU mean, мс | Ввод p95 / p99, мс | DisplayLink / slots |
|---|---:|---:|---:|---:|---:|
| Blue Dark | 59.89 / 59.84 | 19.03 / 20.05 | 7.29 / 2.68 | 34.09 / 35.54 | 8 / 0 |
| Yellow Dark | 59.87 / 59.89 | 19.70 / 21.09 | 7.08 / 2.79 | 34.80 / 35.91 | 6 / 3 |
| Blue Light | 59.44 / 59.43 | 17.76 / 22.88 | 0.39 / 0.23 | 29.41 / 29.82 | 0 / 38 |
| Yellow Light | 59.99 / 59.97 | 19.06 / 19.90 | 0.36 / 0.19 | 33.29 / 33.81 | 0 / 0 |

| Тема | RSS peak, МиБ | Footprint peak, МиБ | RSS конец − начало, МиБ | Main CPU, % одного ядра |
|---|---:|---:|---:|---:|
| Blue Dark | 130.5 | 33.6 | -0.1 | 25.7 |
| Yellow Dark | 134.6 | 34.3 | -0.0 | 25.3 |
| Blue Light | 116.7 | 18.6 | +1.4 | 6.4 |
| Yellow Light | 118.9 | 18.6 | -3.5 | 6.1 |

За эти 75 с нет устойчивого роста RSS; это не доказательство отсутствия всех утечек. currentAllocatedSize у реального MTLDevice возвращает 0 в Simulator и не использован как реальный размер GPU-памяти. Метрики сами ограничены 6000 значениями на ключ. Ошибок GPU-проходов и незавершённых команд при экспорте — 0.

В долгом прогоне p95 ввода выше короткого на 4–9 мс; монотонный тренд отдельно не доказан, отсутствие роста задержки не заявляется. Очередь SDK ограничена тремя слотами. Blue Light: GPU work ~0,23 мс, callback после GPU p99 ~56,36 мс, max ~129,30 мс, доставка callback→main p99 ~0,18 мс; остаются 38 slot skips. Не введены дополнительные буферы/задержки, не возвращена отклонённая ранняя выдача слотов. Абсолютно стабильные 60 FPS не подтверждены.

CPU Time Profiler снят для всех тем: Dark — CG radial, memcpy/memset и CI upload/render; Light — UIKit/обычная подготовка. Metal System Trace записан: работа отражается через SimMetalHost/SimRenderServer, а не как GPU физического iPhone. Данные трасс в `/tmp/gradients-stabilization-instruments/`.

## Проверки и границы

- Debug/Release: финальные 23 компонентных проверки, отдельный CI-контроль запускается отдельно (обычный план: 24 теста, 1 skip). Реальные UI-тесты всех четырёх тем прошли; длинный стресс 243,859 с включает 30-секундный свайп в каждой теме, быстрые/обратные/краевые движения, два касания, hold, release, Home/resume, 100% и reset.
- Реальный уход в Settings посреди активного свайпа проверен отдельно в Debug и Release: процесс остаётся runningBackground, возвращается, не наращивает progress без нового движения и принимает новый свайп. В блоке генератора событий допускалась только ожидаемая отмена инъекции системой; все функциональные assertions вне него обязательны.
- GPU Validation: 72 состояния / 216 raw outputs побайтово идентичны; 60 принятых масок без отличий; дополнительно 108 сравнений повторного использования ресурсов без отличий. Эталоны и допуски не менялись. Отдельный compute-adapter контроль вновь дал 71/72 точных состояния: 1 компонент Blue Dark 60% CONTACT t=2.1 отличается на 0,00006103515625, как до аудита; формулы не изменялись.
- Core: 931 событие, 1385 точных проверок, 5540 сравнений uniform/history. Отрисовка при 30/60/120 Гц не меняет progress; лимит 5,85 п.п./с сохранён с исходным начальным кредитом 1,3 п.п. Удержание не кредитует непрерывное движение, reset и release/idle прежние.
- Жизненный цикл: скрытие своего/родительского view, detach/reattach, manual pause, app/scene inactive, повторное создание и смена bounds проверены. Для непрозрачных перекрытий без UIKit appearance/visibility-событий хосту следует явно использовать pauseRendering/resumeRendering.
- Два экземпляра: независимые session, history, buffers, intermediate/mask textures и пауза. Общие только device/потокобезопасная queue/неизменяемые pipelines. Явная передача одного GradientSession двум контроллерам намеренно разделит сессию; стандартные init создают разные.
- 12 циклов создания/уничтожения: weak controller, MTKView и mask owner освобождаются. Это проверка конкретных владельцев, не глобальный heap/GPU leak detector.
- ASan: окончательные 23 проверки прошли. TSan: два изолированных 22-case прогона и отдельный CI-контроль прошли; полный финальный GPU-прогон нестабилен и падает в __tsan::MetaMap::AllocBlock → malloc → MTLSimOperation/CI. CPU-only 4 теста, включая сбор метрик из восьми потоков, прошли. Отчётов data race не было; полной TSan-проверки рендера и отсутствия гонок не заявляем. [Назначение и ограничения санитайзеров](https://developer.apple.com/documentation/xcode/diagnosing-memory-thread-and-crash-issues-early).
- Четыре новых crash reports этого аудита относятся исключительно к TSan-сборкам: 02:37 и автоматические перезапуски XCTest 13:40–13:41, с libclang_rt.tsan_iossim_dynamic. Обычные сборки/ASan на этих сценариях не падали. Предыдущий запрещённый shared-buffer texture path не возвращён.
- Leaks: ошибка VMUTaskMemoryScanner (инструмент сообщил, что не инициализирован libmalloc); отдельный host leaks остановлен после 45 с ожидания. Граф утечек не получен. Это остаётся необходимой проверкой на совместимом runtime/устройстве.
- iPhone SE 375×667 @2× и Pro Max 440×956 @3×: 23 компонентных + 3 базовых UI-теста, все темы. На Pro Max дополнительно Dark system appearance, Increase Contrast и максимальный content_size; настройки восстановлены. Формулы/пропорции не подгонялись под новые размеры.
- Самостоятельный arm64 iOS GradientsKit собран без demo; прямых SwiftUI/UIHosting/Bundle.main/UserDefaults-зависимостей нет. Metal library принадлежит framework, install name @rpath. UIViewController — @MainActor, GradientSession требует одного serial owner.

## Решения перед production SDK

1. **Нужен контракт runtime-ошибок.** Pipeline/library/device ошибки init передаются через throws, но поздние texture/buffer/CGContext аллокации содержат force unwrap. Отказ при memory pressure не инжектировался; это риск, не воспроизведённое обычное падение. Предлагается отдельно согласовать onError + остановку/повтор рендера либо throwing prepare/resize. Публичные сигнатуры самостоятельно не менялись.
2. **Доступность — продуктовые решения.** Инструкция/проценты/контролы есть в native accessibility tree; VoiceOver с реальным screen reader и доступный сценарий свайпов не проверены. Dynamic Type не масштабирует утверждённые 17/64 pt; Reduce Motion не отключает утверждённые волны/анимации. Визуальные адаптации не вводились. Маленький toolbar-контейнер и произвольный safe-area/nav layout не являются утверждённым дизайном.
3. **Физическое устройство.** Не проверены реальные 60/120 Гц, touch-to-photon, GPU memory/thermal behavior, background GPU policy и длительный многочасовой soak iPhone. Simulator/host RSS не заменяют эти проверки.

## Локальные коммиты

- `4fd42dd Freeze approved UIKit baseline for SDK stabilization`
- `182ba7f Discard in-flight caption samples when the theme changes`
- `5e5bfe8 Suspend hidden and inactive SDK rendering and cancel interrupted input`
- `fc898c8 Match Dark mask texture extents to fractional drawable bounds`
- `480d20f Exercise SDK isolation and lifetime with opt-in long-run diagnostics`
- `b4925c2 Cancel pending digit animation for an explicit nonanimated reset`
- `fa2d3bd Isolate sanitizer controls and record complete GPU and memory diagnostics`
- `7f6081e Synchronize drawable layout before rendering a changed viewport`
- `9c30985 Verify OS cancellation of an active native swipe and recovery`

Ничего не отправлено на GitHub. Видео, PNG-скриншоты и HTML-отчёты не создавались. Источники чисел: соседние JSON; полные журналы — `/tmp/gradients-stabilization-*.log`. Неизменённая SwiftUI V2 остаётся эталоном для ручного сравнения.
