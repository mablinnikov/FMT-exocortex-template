#!/usr/bin/env bash
# routing: utility  deterministic=true
# see WP-394 Ф4.2, WP-007 Ф10, DP.SC.159
# sync-agent-instructions.sh — генерация агентских адаптеров из общего ядра
#
# Канонические входы:
#   memory/reference/agent-core.md — блок AGENT-CORE (общие инструкции)
#   CLAUDE.md                      — оболочка и специфика Claude Code
#   AGENTS-agent-blocks.md         — общая специфика Codex/Kimi
#
# Производные файлы:
#   CLAUDE.md — общий блок заменяется между AGENT-CORE-INLINE markers
#   AGENTS.md — полная регенерация: header + core + agent blocks
#
# Codex не поддерживает произвольный include из AGENTS.md: он собирает цепочку
# файлов по каталогам. Поэтому ядро встраивается физически, а размер проверяется
# против стандартного project_doc_max_bytes=32768.
# Документация: https://learn.chatgpt.com/docs/agent-configuration/agents-md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1

CORE_MD="$IWE_ROOT/memory/reference/agent-core.md"
CLAUDE_MD="$IWE_ROOT/CLAUDE.md"
BLOCKS_MD="$IWE_ROOT/AGENTS-agent-blocks.md"
OUT_MD="$IWE_ROOT/AGENTS.md"
HERMES_DIR="${HERMES_RUNTIME_DIR:-$HOME/.hermes}"
AGENTS_MAX_BYTES="${AGENTS_MAX_BYTES:-32768}"
SYNC_AGENT_BACKUPS="${SYNC_AGENT_BACKUPS:-0}"

MODE="dry-run"
WITH_HERMES=0
for arg in "$@"; do
  case "$arg" in
    --force)       MODE="force" ;;
    --check)       MODE="check" ;;
    --with-hermes) WITH_HERMES=1 ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -36
      exit 0 ;;
    *) echo "Неизвестный аргумент: $arg (см. --help)" >&2; exit 2 ;;
  esac
done

for file in "$CORE_MD" "$CLAUDE_MD" "$BLOCKS_MD"; do
  if [ ! -f "$file" ]; then
    echo "[ERROR] Источник не найден: $file" >&2
    exit 1
  fi
done

require_marker_pair() {
  local file="$1" start="$2" end="$3"
  local start_count end_count
  start_count=$(grep -cE "^[[:space:]]*${start}[[:space:]]*$" "$file" || true)
  end_count=$(grep -cE "^[[:space:]]*${end}[[:space:]]*$" "$file" || true)
  if [ "$start_count" -ne 1 ] || [ "$end_count" -ne 1 ]; then
    echo "[ABORT] $file: ожидалась ровно одна пара markers $start / $end." >&2
    exit 3
  fi
}

require_marker_pair "$CORE_MD" '<!-- AGENT-CORE-START -->' '<!-- AGENT-CORE-END -->'
require_marker_pair "$CLAUDE_MD" '<!-- AGENT-CORE-INLINE-START -->' '<!-- AGENT-CORE-INLINE-END -->'
require_marker_pair "$BLOCKS_MD" '<!-- AGENT-SPECIFIC-START -->' '<!-- AGENT-SPECIFIC-END -->'

extract_core() {
  awk '
    /^[[:space:]]*<!-- AGENT-CORE-START -->[[:space:]]*$/ { grab=1; next }
    /^[[:space:]]*<!-- AGENT-CORE-END -->[[:space:]]*$/   { grab=0 }
    grab { print }
  ' "$CORE_MD"
}

extract_blocks() {
  awk '
    /^[[:space:]]*<!-- AGENT-SPECIFIC-START -->[[:space:]]*$/ { grab=1; next }
    /^[[:space:]]*<!-- AGENT-SPECIFIC-END -->[[:space:]]*$/   { grab=0; next }
    grab {
      if ($0 ~ /^<!--/) { incomment=1 }
      if (incomment) { if ($0 ~ /-->/) { incomment=0 }; next }
      print
    }
  ' "$BLOCKS_MD"
}

build_agents() {
  cat <<'HEADER'
# AGENTS.md

> **Сгенерировано `scripts/sync-agent-instructions.sh` (WP-007 Ф10). НЕ РЕДАКТИРОВАТЬ ВРУЧНУЮ.**
> Общее ядро → `memory/reference/agent-core.md`. Агент-специфика Codex/Kimi → `AGENTS-agent-blocks.md`.

HEADER
  extract_core
  echo
  extract_blocks
}

build_claude() {
  awk -v core_file="$CORE_MD" '
    BEGIN {
      grab=0
      while ((getline line < core_file) > 0) {
        if (line ~ /^[[:space:]]*<!-- AGENT-CORE-START -->[[:space:]]*$/) { grab=1; continue }
        if (line ~ /^[[:space:]]*<!-- AGENT-CORE-END -->[[:space:]]*$/)   { grab=0; continue }
        if (grab) core[++core_count]=line
      }
      close(core_file)
    }
    /^[[:space:]]*<!-- AGENT-CORE-INLINE-START -->[[:space:]]*$/ {
      print
      for (i=1; i<=core_count; i++) print core[i]
      skip=1
      next
    }
    /^[[:space:]]*<!-- AGENT-CORE-INLINE-END -->[[:space:]]*$/ {
      skip=0
      print
      next
    }
    !skip { print }
  ' "$CLAUDE_MD"
}

GENERATED_AGENTS="$(build_agents)"
GENERATED_CLAUDE="$(build_claude)"
AGENTS_BYTES=$(printf '%s\n' "$GENERATED_AGENTS" | wc -c)
if [ "$AGENTS_BYTES" -gt "$AGENTS_MAX_BYTES" ]; then
  echo "[ABORT] AGENTS.md: $AGENTS_BYTES bytes > Codex limit $AGENTS_MAX_BYTES." >&2
  exit 4
fi

is_equal() {
  local file="$1" generated="$2"
  [ -f "$file" ] && diff -q <(printf '%s\n' "$generated") "$file" >/dev/null 2>&1
}

show_diff() {
  local label="$1" file="$2" generated="$3"
  if is_equal "$file" "$generated"; then
    echo "$label: актуален"
  else
    echo "--- $label: текущий → сгенерированный ---"
    diff -u "$file" <(printf '%s\n' "$generated") || true
  fi
}

case "$MODE" in
  check)
    drift=0
    if ! is_equal "$OUT_MD" "$GENERATED_AGENTS"; then
      echo "[DRIFT] AGENTS.md расходится с общим ядром и агентскими блоками." >&2
      drift=1
    fi
    if ! is_equal "$CLAUDE_MD" "$GENERATED_CLAUDE"; then
      echo "[DRIFT] CLAUDE.md расходится с общим ядром." >&2
      drift=1
    fi
    [ "$drift" -eq 0 ] || exit 1
    echo "Синхронизация: OK (CLAUDE.md и AGENTS.md соответствуют общему ядру; AGENTS.md=${AGENTS_BYTES}B)"
    ;;
  dry-run)
    echo "=== sync-agent-instructions.sh: dry-run ==="
    echo "IWE_ROOT: $IWE_ROOT"
    show_diff "AGENTS.md" "$OUT_MD" "$GENERATED_AGENTS"
    show_diff "CLAUDE.md" "$CLAUDE_MD" "$GENERATED_CLAUDE"
    echo "AGENTS.md: ${AGENTS_BYTES}/${AGENTS_MAX_BYTES} bytes"
    ;;
  force)
    if [ "$SYNC_AGENT_BACKUPS" = "1" ]; then
      [ -f "$OUT_MD" ] && cp "$OUT_MD" "$OUT_MD.bak"
      [ -f "$CLAUDE_MD" ] && cp "$CLAUDE_MD" "$CLAUDE_MD.bak"
    fi
    printf '%s\n' "$GENERATED_AGENTS" > "$OUT_MD"
    printf '%s\n' "$GENERATED_CLAUDE" > "$CLAUDE_MD"
    agents_lines=$(awk 'END { print NR }' "$OUT_MD")
    claude_lines=$(awk 'END { print NR }' "$CLAUDE_MD")
    echo "Записано: $OUT_MD ($agents_lines строк, ${AGENTS_BYTES}B)"
    echo "Записано: $CLAUDE_MD ($claude_lines строк)"
    ;;
esac

if [ "$WITH_HERMES" -eq 1 ]; then
  if [ ! -d "$HERMES_DIR" ]; then
    echo "[WARN] --with-hermes: каталог $HERMES_DIR не найден — persona.md пропущен." >&2
  elif [ "$MODE" = "force" ]; then
    PERSONA="$HERMES_DIR/persona.md"
    [ -f "$PERSONA" ] && cp "$PERSONA" "$PERSONA.bak"
    {
      echo "# Hermes Persona — IWE Core (generated by sync-agent-instructions.sh)"
      echo
      echo "> Общее ядро IWE. Hermes-специфика находится в рантайме Hermes."
      echo
      extract_core
    } > "$PERSONA"
    echo "Записано: $PERSONA"
  else
    echo "[INFO] --with-hermes активен, но persona.md пишется только с --force."
  fi
fi
