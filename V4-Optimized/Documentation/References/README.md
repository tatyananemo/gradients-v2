# Передаваемые утверждённые визуальные материалы

Все PNG скопированы **без изменения байтов** из уже просмотренных материалов, новых рендеров,
видео и скриншотов нет. Исходные имена, SHA-256 и shader inputs — в manifest.json.
Это визуальные референсы, не замена и не обновление GPU-эталонов Development/Validation.

## Пять стадий, одинаковая фаза CONTACT

| Прогресс | Dark | Light |
|---|---|---|
| 0% | [Dark](dark-000-contact-phase-1.65.png) | [Light](light-000-contact-phase-1.65.png) |
| 33% | [Dark](dark-033-contact-phase-1.65.png) | [Light](light-033-contact-phase-1.65.png) |
| 63% | [Dark](dark-063-contact-phase-1.65.png) | [Light](light-063-contact-phase-1.65.png) |
| 80% | [Dark](dark-080-contact-phase-1.65.png) | [Light](light-080-contact-phase-1.65.png) |
| 100% | [Dark](dark-100-contact-phase-1.65.png) | [Light](light-100-contact-phase-1.65.png) |

Native Mac compositor, 1170×2532, без UIKit процента/кнопок/Light caption layer.
Источник — original side принятого сравнения v4-precalc-visual-review-20261028, фаза idle 1,65 с.
Они показывают исходный утверждённый дизайн, **не новый capture `2f12367`**. Ранее принятому optimized
пути допускали визуальную оценку разницы до 1/255; исторические численные goldens не менялись.

## Idle при 63%

Индекс имени — индекс момента, не секунды:

| Имя phase | Фактическое idleTime | Dark | Light |
|---|---:|---|---|
| 0 | 0,0 с | [Dark](dark-063-idle-phase-0.png) | [Light](light-063-idle-phase-0.png) |
| 2 | 0,8 с | [Dark](dark-063-idle-phase-2.png) | [Light](light-063-idle-phase-2.png) |
| 5 | 2,1 с | [Dark](dark-063-idle-phase-5.png) | [Light](light-063-idle-phase-5.png) |
| 7 | 2,999 с | [Dark](dark-063-idle-phase-7.png) | [Light](light-063-idle-phase-7.png) |

## Полный UI

`swiftui-yellow-{dark,light}-{030,060,080}-contact.png` — шесть исторических утверждённых
SwiftUI V2 full-screen screenshots из baseline dd5bb02. Их SHA проверены по замороженному
full-screen-baseline.json. Это образец композиции/текста/контролов до миграции, **не заявление
о полной побайтовой идентичности UIKit или новый тест на iPhone**. 30/60% здесь не подменяют
33/63% в серии выше. Цветовые сравнения выполняют при совпадающих state/time/viewport.

Для точного движения и условий наложения используйте DESIGN.md, зафиксированные inputs и
исходники; один PNG не определяет период, инерцию или физическое frame pacing.
