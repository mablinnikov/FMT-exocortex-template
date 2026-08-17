#!/bin/bash
# Пользовательское расширение IWE: проверка формата номеров РП перед Close.
# update.sh сохраняет extensions/*.checks.*.md.

set -eu

IWE_WORKSPACE="${IWE_WORKSPACE:-${WORKSPACE_DIR:-${IWE_ROOT:-}}}"
if [ -z "$IWE_WORKSPACE" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    IWE_WORKSPACE="$(dirname "$SCRIPT_DIR")"
fi

GOVERNANCE_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
CHECKER="$IWE_WORKSPACE/$GOVERNANCE_REPO/scripts/check-wp-number-format.py"

if [ ! -f "$CHECKER" ]; then
    echo "WP FORMAT: обязательная проверка не найдена: $CHECKER"
    exit 1
fi

PYTHON_BIN=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" --version >/dev/null 2>&1; then
        PYTHON_BIN="$candidate"
        break
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    echo "WP FORMAT: Python не найден — Close заблокирован."
    exit 1
fi

"$PYTHON_BIN" "$CHECKER" --repo "$IWE_WORKSPACE/$GOVERNANCE_REPO"
