# Feature Requests & Feedback Analysis

## Summary
Собрано из 3 Reddit постов (r/iOSProgramming, r/Xcode, r/swift). Общий тон крайне положительный — пользователи отмечают чистый UI и реальную пользу (освобождено 6-100GB).

---

## Bugs (Critical - Fix First)

| Bug | Reporter | Priority |
|-----|----------|----------|
| Показывает максимум 4 приложения в симуляторе, даже если установлено больше | friguron | High |
| Сортировка по "last launch" не работает корректно | xyrer | High |
| Иконки в сайдбаре разной ширины (особенно visionOS), текст не выровнен | Same-Appointment-285 | Medium |

---

## High Priority Features (Valuable)

### 1. Удаление отдельных приложений внутри симулятора
**Запросил:** friguron
**Суть:** Сейчас приложения только отображаются, но нельзя удалить конкретное приложение из симулятора
**Почему ценно:** Часто нужно очистить данные одного приложения без удаления всего симулятора. Core функциональность для dev workflow.

### 2. Reveal Documents/Caches/Container приложения
**Запросил:** physical_dude
**Суть:** Кнопки для быстрого открытия Documents, Caches и других папок контейнера приложения
**Почему ценно:** Разработчики постоянно ищут базы данных, UserDefaults, файлы кэша для дебага. Сейчас это сложно — контейнеры называются UUID'ами.

### 3. Loading spinner на каждую строку при удалении
**Запросил:** Same-Appointment-285
**Суть:** Spinner в правом верхнем углу легко пропустить. Нужен индикатор на самой строке, которая удаляется.
**Почему ценно:** Простое UX улучшение, пользователь понимает что происходит.

### 4. Select All / Delete All внутри версии iOS
**Запросил:** DaddyDontTakeNoMess
**Суть:** Возможность удалить все симуляторы внутри одной версии iOS (например, все iOS 17 устройства). Кнопка на уровне папки/группы.
**Почему ценно:** Частый сценарий — вышла iOS 18, хочу удалить все iOS 16 симуляторы разом.

---

## Medium Priority Features

### 5. Проверить полноту удаления симуляторов
**Запросил:** cristi_baluta
**Суть:** Размер показывается маленький. Возможно удаляются только данные симулятора, но не сам симулятор (runtime), который весит несколько GB.
**Действие:** Проверить логику удаления. Уточнить в UI что именно удаляется.

---

## Low Priority (Can Ignore)

### Поддержка старых версий macOS
**Запросил:** anosidium
**Почему игнорируем:** Apple заставляет разработчиков использовать новые версии macOS. Target аудитория и так на свежих системах.

### Авто-удаление старых симуляторов при скачивании новых
**Запросил:** Life-Purpose-9047
**Почему игнорируем:** Слишком автоматизировано и рискованно. Пользователь должен контролировать что удаляется.

### Open Source
**Запросил:** velvethead
**Почему игнорируем:** Опционально. Можно рассмотреть позже, но не влияет на функциональность.

---

## Already Implemented (Just Educate Users)

| Feature | Status |
|---------|--------|
| Multi-select для удаления нескольких симуляторов | ✅ Работает через Shift/Command |

---

## Positive Feedback Highlights

- "THIS IS A CORE FUNCIONALITY XCODE ITSELF SHOULD HAVE" — friguron
- "really slick, well done" — Same-Appointment-285
- "UI is super clean and easy to understand" — ThrosProvoni
- "Beautiful UI" — pookiebryceyoung
- "saved 16GB" — liquidsmk
- "Worth maybe $10" — xyrer
- "9.5/10" — friguron

---

## Recommended Implementation Order

1. **Fix bugs first** — максимум 4 приложения, сортировка, иконки
2. **Delete individual apps** — самый запрашиваемый feature
3. **Reveal container folders** — высокая ценность для devs
4. **Loading spinner per row** — быстрый UX win
5. **Select All per iOS version** — удобство
