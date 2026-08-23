#!/bin/bash
# verify-manifest.sh — проверяет что update-manifest.json синхронизирован с git tree.
# Использование: bash scripts/verify-manifest.sh
# Exit 0 = манифест актуален. Exit 1 = рассинхрон (показывает diff).
#
# Запускает generate-manifest.sh во временный файл и сравнивает с текущим.
# НЕ изменяет update-manifest.json (read-only, безопасен для CI).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$SCRIPT_DIR/update-manifest.json"
GENERATOR="$SCRIPT_DIR/generate-manifest.sh"

PYTHON_OS=$(python3 -c 'import os; print(os.name)')
python_native_path() {
    if [ "$PYTHON_OS" = "nt" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        printf '%s\n' "$1"
    fi
}
PY_MANIFEST=$(python_native_path "$MANIFEST")

if [ ! -f "$GENERATOR" ]; then
    echo "ERROR: generate-manifest.sh не найден: $GENERATOR"
    exit 2
fi

if [ ! -f "$MANIFEST" ]; then
    echo "ERROR: update-manifest.json не найден: $MANIFEST"
    exit 2
fi

# Сохраняем текущий манифест (read-only backup)
BACKUP=$(mktemp)
cp "$MANIFEST" "$BACKUP"

TMP_MANIFEST=$(mktemp)
GENERATOR_LOG=$(mktemp)
cleanup() {
    cp "$BACKUP" "$MANIFEST"
    rm -f "$BACKUP" "$TMP_MANIFEST" "$GENERATOR_LOG"
}
trap cleanup EXIT

# Сохраняем версию из текущего манифеста (generate-manifest.sh берёт из CHANGELOG)
CURRENT_VERSION=$(MANIFEST_PATH="$PY_MANIFEST" python3 -c '
import json
import os
with open(os.environ["MANIFEST_PATH"], encoding="utf-8") as source:
    print(json.load(source)["version"])
')

# Создаём временный манифест через generate-manifest.sh
PY_TMP_MANIFEST=$(python_native_path "$TMP_MANIFEST")

# Генерируем новый манифест во временный файл
if ! bash "$GENERATOR" >"$GENERATOR_LOG" 2>&1; then
    echo "ERROR: generate-manifest.sh завершился с ошибкой" >&2
    cat "$GENERATOR_LOG" >&2
    exit 2
fi

# Копируем сгенерированный манифест во временный файл
cp "$MANIFEST" "$TMP_MANIFEST"

# Восстанавливаем версию в сгенерированном (CHANGELOG может быть "Unreleased")
TMP_MANIFEST_PATH="$PY_TMP_MANIFEST" \
CURRENT_VERSION="$CURRENT_VERSION" \
python3 -c '
import json
import os
with open(os.environ["TMP_MANIFEST_PATH"], encoding="utf-8") as f:
    data = json.load(f)
data["version"] = os.environ["CURRENT_VERSION"]
with open(os.environ["TMP_MANIFEST_PATH"], "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
'

# Восстанавливаем оригинальный манифест (generate-manifest.sh его перезаписал)
cp "$BACKUP" "$MANIFEST"

# Сравниваем backup с сгенерированным
if diff -q "$BACKUP" "$TMP_MANIFEST" >/dev/null 2>&1; then
    echo "✅ manifest-verify: update-manifest.json синхронизирован с git tree"
    exit 0
else
    echo "❌ manifest-verify: update-manifest.json НЕ синхронизирован с git tree"
    echo ""
    echo "Diff (current vs generated):"
    diff -u "$BACKUP" "$TMP_MANIFEST" || true
    echo ""
    echo "→ Перегенерируйте манифест: bash generate-manifest.sh"
    echo "→ Проверьте diff: git diff update-manifest.json"
    echo "→ Закоммитьте изменения"
    exit 1
fi
