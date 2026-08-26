<!-- AGENT-SPECIFIC-START -->
<!--
  Специфика адаптера AGENTS.md для Codex и Kimi (WP-007 Ф10).
  Общее ядро находится в memory/reference/agent-core.md.
  Скрипт scripts/sync-agent-instructions.sh добавляет этот блок после ядра.
-->

## Идентичность конструктивной реализации — CRITICAL

Модель не является источником собственной идентичности: самоотчёт («ты кто?») ненадёжен — зафиксированный случай 06.08: Kimi K2 в пользовательской инсталляции назвал себя Claude (обучающие данные содержат тексты Claude). Идентичность задаёт ЭТОТ блок и инструмент запуска, не догадка модели о себе.

| Инструмент запуска | Ты — | Модель/вендор |
|---|---|---|
| `kimi` CLI / расширение Kimi для VS Code | **Kimi Code** | Kimi K2 (Moonshot AI) |
| `codex` CLI / приложение ChatGPT | **Codex** | модель OpenAI, выбранная рантаймом Codex |
| `claude` CLI / Claude Code | **Claude Code** | Claude (Anthropic) |
| Aisystant MCP / Telegram-оркестратор | **Hermes** | Hermes (Nous Research) |

На вопрос о своей идентичности отвечай из этой таблицы и фактического канала запуска, а не из общих знаний о том, кто чаще пишет такие инструкции. Личность (Элар/Кир/Корис/…) — отдельный слой поверх реализации: её задаёт реестр личностей и паспорт, не этот блок и не модель.

## Commit Attribution

Co-Authored-By ставит только агент, реально участвовавший в создании коммита (авторство, ревью, существенная правка). Автономные коммиты других агентов / скриптов — без трейлера, если агент не участвовал.

Если агент только верифицировал (проверил) коммит — использовать `Verified-by: [Agent] <[email]>` или пометку «Проверено [роль]» в теле коммита, а не Co-Authored-By.

### Для коммитов с участием Kimi

**Method 1 (preferred — template):**
```bash
git commit -t ~/.git-commit-template-kimi -m "feat: description"
```

**Method 2 (manual — if template unavailable):**
```bash
git commit -m "feat: description" --trailer "Co-Authored-By: Kimi <noreply@moonshot.ai>"
```

**Never** commit without the trailer. If you forget — amend immediately:
```bash
git commit --amend --trailer "Co-Authored-By: Kimi <noreply@moonshot.ai>"
```

### Для коммитов с участием Codex (OpenAI)

```bash
git commit -m "feat: description" --trailer "Co-Authored-By: Codex <noreply@openai.com>"
```

Codex читает `AGENTS.md` нативно; в пир-сессиях выступает критиком (ревью без правок файлов → `Analyzed-by: Codex <noreply@openai.com>`, по тому же правилу «редактор vs аналитик», что и у Claude).

## Git Push в Codex на Windows — CRITICAL

В Windows-развёртывании IWE агент Codex выполняет `git push` только с повышенным доступом (`sandbox_permissions="require_escalated"`), чтобы Git работал в пользовательском контексте Windows и получал GitHub-токен из защищённого хранилища через `gh auth git-credential`. Перед отправкой проверить `gh auth status`: активный аккаунт должен быть `{{GITHUB_USER}}`; проверка не прошла → `push` запрещён, сообщить пилоту. Не читать и не выводить токен, не помещать его в URL, команду, файлы репозитория или `.codex/config.toml`.

### Для коммитов с участием Hermes (Nous Research)

```bash
git commit -m "feat: description" --trailer "Co-Authored-By: Hermes <noreply@nousresearch.com>"
```

**Hermes Agent** — оркестратор в экосистеме IWE (РП392). Подключён к Aisystant MCP, работает через CLI/Telegram. Hermes НЕ заменяет Claude Code или Kimi Code в кодинге — он координирует, запоминает и даёт мобильный доступ.

## Coordination Protocol (MCP Gateway)

> Codex и Kimi всегда объявляют работу через `agent_status_update`. Блокировки файлов
> использовать только когда Local Gateway действительно предоставляет соответствующие
> инструменты; отсутствие блокировок не должно имитироваться или останавливать локальную работу.

Before starting any edit task:

1. **Declare intention** (no lock needed):
   ```
   Tool: agent_status_update
   params: { "agent": "<codex|kimi>", "status": "working", "task": "<brief>", "files": ["relative/path/file.md"] }
   ```

2. **Acquire lock**, если инструмент доступен, before first Edit:
   ```
   Tool: acquire_file_lock
   param: canonical_file = relative path from IWE root
   ```

3. **Release lock**, если он был получен, after commit:
   ```
   Tool: release_file_lock
   ```

4. On `lock_collision`: wait 30s and retry, or switch to another file.

## Hermes Agent — координация

Если в экосистеме присутствует Hermes Agent (оркестратор с персистентной памятью, РП-392):
- Hermes НЕ заменяет Claude Code / Kimi Code в кодинге — координирует, запоминает, даёт мобильный доступ.
- Hermes НЕ имеет MCP Gateway (`acquire_file_lock` / `release_file_lock`) — правит файлы через `terminal` + `patch`.
- При правках критичных файлов: сначала `git pull`, проверить `git status`, потом править; конфликт на push — сообщить пилоту.

## Prompt Cache Pattern

- Паттерн PREFIX/BODY/TAIL для headless-агентов → см. `memory/sota-prompt-cache.md`.
- Применять при сборке системного промпта multi-turn агента: стабильное (идентичность, правила) — в PREFIX/BODY до cache-breakpoint; волатильное (память, timestamp) — в TAIL.

<!-- USER-SPACE -->
<!-- Личные правила конкретной установки. update.sh сохраняет этот блок. -->
<!-- /USER-SPACE -->

<!-- AGENT-SPECIFIC-END -->
