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

# Генерируем новый манифест во временный файл.
# 2026-08-22 (Codex peer-review): было `|| true` — падение генератора
# глоталось, и сравнение ниже могло пройти на СТАРОМ манифесте (fail-open в
# проверке, заявленной fail-closed). Теперь любой отказ генератора = ошибка
# проверки; оригинальный манифест восстанавливаем перед выходом.
if ! bash "$GENERATOR" >"$GENERATOR_LOG" 2>&1; then
    cp "$BACKUP" "$MANIFEST"
    echo "❌ manifest-verify: generate-manifest.sh завершился с ошибкой — проверка невозможна (fail-closed)"
    cat "$GENERATOR_LOG" >&2
    exit 1
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
with open(os.environ["TMP_MANIFEST_PATH"], "w", encoding="utf-8", newline="\n") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
'

# Восстанавливаем оригинальный манифест (generate-manifest.sh его перезаписал)
cp "$BACKUP" "$MANIFEST"

# 2026-08-22 (external report, live 10-file deletion): deprecated_files must
# never intersect the delivered set OR the git-tracked tree — update.sh would
# delete files the canon still ships with every fresh clone. generate-manifest
# filters this at write time; this check fails closed on a bad committed one.
DEP_CONFLICTS=$(python3 - "$MANIFEST" <<'PYCHECK'
import json, subprocess, sys
m = json.load(open(sys.argv[1]))
delivered = {e['path'] for e in m.get('files', [])}
# 2026-08-22 (Codex peer-review): git ls-files без проверки кода возврата —
# при сбое git множество tracked молча становилось пустым, и проверка
# «deprecated ∩ дерево» деградировала fail-open. Теперь сбой git = сбой проверки.
r = subprocess.run(['git', 'ls-files'], capture_output=True, text=True)
if r.returncode != 0:
    sys.exit('git ls-files failed: ' + r.stderr.strip())
tracked = set(r.stdout.splitlines())
bad = [e['path'] for e in m.get('deprecated_files', []) if e.get('path') in delivered or e.get('path') in tracked]
print('\n'.join(bad))
PYCHECK
)
if [ -n "$DEP_CONFLICTS" ]; then
    echo "❌ manifest-verify: deprecated_files пересекается с поставкой/деревом git:"
    printf '  %s
' $DEP_CONFLICTS
    echo "→ Либо файл больше не deprecated (убери запись), либо удали его из дерева (git rm)"
    exit 1
fi

# 2026-08-23 (v0.38.7 матрица, находка 4): сторож, который доставляется без
# своего обязательного файла данных, на установке из манифеста падает — CI
# этого не видел, потому что работает в полном чекауте. Парные поставки
# объявлены явно; каждая пара либо доставляется целиком, либо целиком нет.
PAIRED_DELIVERY="scripts/check-python-resolver-contract.sh=scripts/tests/fixtures/python-resolver-baseline.txt"
for pair in $PAIRED_DELIVERY; do
    tool="${pair%%=*}"; datafile="${pair#*=}"
    # Обе стороны пары считаем по files[] (доставляемое), не по всему JSON:
    # инструмент, осознанно выведенный из поставки, делает пару вакуумной,
    # а не ложно-нарушенной.
    t=$(python3 - "$MANIFEST" "$tool" <<'PYCHK'
import json, sys
m = json.load(open(sys.argv[1]))
print(sum(1 for e in m.get('files', []) if e['path'] == sys.argv[2]))
PYCHK
)
    d=$(python3 - "$MANIFEST" "$datafile" <<'PYCHK'
import json, sys
m = json.load(open(sys.argv[1]))
print(sum(1 for e in m.get('files', []) if e['path'] == sys.argv[2]))
PYCHK
)
    if [ "$t" -ge 1 ] && [ "$d" -eq 0 ]; then
        echo "❌ manifest-verify: $tool доставляется без обязательного $datafile (парная поставка нарушена)"
        exit 1
    fi
done

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
