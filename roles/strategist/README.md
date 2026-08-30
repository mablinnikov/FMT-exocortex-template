# Стратег (R1)

> **Модуль шаблона:** `roles/strategist/` в [FMT-exocortex-template](../../README.md)
> **Роль:** R1 Стратег — планирование и отслеживание (DP.D.033 §7, DP.ROLE.001)

Роль Стратег автоматизирует операционное планирование: утренние планы, вечерние итоги и недельные обзоры. В Codex-развёртывании единственный исполнитель — Codex CLI.

---

## Архитектура: Промпты → Стратег → Результаты

```
FMT-exocortex-template/              DS-strategy/ (отдельный репо)
  roles/strategist/                     current/
    prompts/                              WeekPlan W{N}.md
      add-wp.md                           ~~WeekReport W{N}.md~~ (deprecated → секция «Итоги W{N}» в WeekPlan)
      check-plan.md                       DayPlan YYYY-MM-DD.md
      evening.md                        docs/
    scripts/                              Strategy.md
      strategist.sh                       Dissatisfactions.md
  memory/                              inbox/
    protocol-open.md  (← day-plan)       WP-{N}-*.md (контексты задач)
    protocol-close.md (← day-close)    archive/
```

> **Примечание:** исполняемые промпты остаются в шаблоне как платформенный код. Пользовательские планы и результаты живут в DS-strategy. `day-plan` и `day-close` также опираются на канонические протоколы `memory/protocol-open.md` и `memory/protocol-close.md`.

**Потоки данных:**
- Промпты (PLATFORM) → `prompts/` (3 базовых) + `memory/protocol-*.md`
- Результаты (PERSONAL) → DS-strategy/ (отдельный приватный репо, не затрагивается обновлениями)
- Входные данные: MEMORY.md, MAPSTRATEGIC.md (из каждого репо), WakaTime

---

## Два режима работы

| | Операционный (реализован) | Стратегический (реализован) |
|---|---|---|
| **Что делает** | Планирует, отслеживает, отчитывается | Помогает осознать НЭП, выбрать методы |
| **Горизонт** | День → неделя | Неделя → месяц → год |
| **Взаимодействие** | Фоновый Codex (session-prep) + интерактивный Codex (strategy-session) | Глубоко интерактивный |

---

## Сценарии

| # | Сценарий | Промпт | Триггер | Статус |
|---|----------|--------|---------|--------|
| 1 | Подготовка к сессии | `prompts/session-prep.md` | Утро `strategy_day` (фоновый запуск) | В шаблоне |
| 1b | Сессия стратегирования | `.agents/skills/iwe-strategy-session` | Вручную (интерактив) | В шаблоне |
| 2 | План на день | `memory/protocol-open.md` | Утро вне `strategy_day` + вручную | В шаблоне |
| 3 | Вечерний итог | `prompts/evening.md` | Вручную | В шаблоне |
| 4 | Итоги недели | `prompts/week-review.md` | По недельному расписанию | В шаблоне |
| 5 | Добавить РП | `prompts/add-wp.md` | Вручную | В шаблоне |
| 6 | Проверить задачу (WP Gate) | `prompts/check-plan.md` | WP Gate | В шаблоне |
| 7 | Закрытие дня | `memory/protocol-close.md` | Вручную | В шаблоне |
| 8 | Обзор заметок | `prompts/note-review.md` | По необходимости | В шаблоне |

---

## Расписание

| Время | День | Сценарий | Задание |
|-------|------|----------|---------|
| Утро | `strategy_day` | `session-prep` (фоновый запуск) | `Strategist Morning` |
| Утро | Остальные дни | `day-plan` | `Strategist Morning` |
| 11:00 | Суббота (Windows, по умолчанию) | `week-review` | `Strategist WeekReview` |

На Windows сначала подготовьте runtime и проверьте будущие задания без регистрации:

```powershell
.\setup-codex.ps1 -PrepareStrategist
.\setup\install-windows-tasks.ps1 -WhatIf
```

Запуск без `-WhatIf` меняет системное расписание и выполняется только после явного решения пользователя. По умолчанию Стратег не отправляет изменения в GitHub и не посылает уведомления: он создаёт только изолированные локальные коммиты. Уведомления включаются отдельно через `IWE_STRATEGIST_NOTIFY=true`.

На macOS и Linux остаются штатные launchd/systemd-установщики. Без расписания Стратег запускается вручную.

## Установка

```bash
./install.sh          # Установить launchd/systemd задания (macOS/Linux)

# Ручной запуск
./scripts/strategist.sh morning           # session-prep в strategy_day, иначе day-plan
./scripts/strategist.sh evening           # вечерний итог
./scripts/strategist.sh week-review       # итоги недели
./scripts/strategist.sh strategy-session  # сессия стратегирования (интерактив)
./scripts/strategist.sh day-close         # закрытие дня
./scripts/strategist.sh note-review       # обзор заметок
```
