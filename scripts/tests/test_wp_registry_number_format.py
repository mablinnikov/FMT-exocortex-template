"""Регрессия формата номера в WP-REGISTRY и производном active-wp."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CHECK_FORMAT = ROOT / "scripts" / "check-wp-format.py"
BUILD_ACTIVE = ROOT / "scripts" / "build-active-wp.py"


def registry_text(*rows: str) -> str:
    return (
        "| # | P | Название | Ст | Репо | Бюджет |\n"
        "|---|---|---|---|---|---|\n"
        + "".join(f"{row}\n" for row in rows)
    )


def run_check(registry: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(CHECK_FORMAT), str(registry), *args],
        env={**os.environ, "PYTHONIOENCODING": "utf-8"},
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )


def test_linter_rejects_prefixed_and_padded_numbers(tmp_path: Path):
    registry = tmp_path / "WP-REGISTRY.md"
    registry.write_text(
        registry_text(
            "| WP-8 | P3 | Префикс | ⏳ | DS-strategy | 1h |",
            "| 009 | P3 | Паддинг | ⏳ | DS-strategy | 1h |",
            "| ~~WP-007~~ | ~~P3~~ | ~~Закрытый~~ | ✅ | ~~DS-strategy~~ | 1h |",
            "| 10 | P3 | Канонический | ⏳ | DS-strategy | 1h |",
        ),
        encoding="utf-8",
    )

    result = run_check(registry, "--exit-nonzero")

    assert result.returncode == 1
    assert "ID (формат номера):              3 нарушений" in result.stdout


def test_linter_fix_normalizes_number_cells(tmp_path: Path):
    registry = tmp_path / "WP-REGISTRY.md"
    registry.write_text(
        registry_text(
            "| WP-8 | P3 | Префикс | ⏳ | DS-strategy | 1h |",
            "| 009 | P3 | Паддинг | ⏳ | DS-strategy | 1h |",
            "| ~~WP-007~~ | ~~P3~~ | ~~Закрытый~~ | ✅ | ~~DS-strategy~~ | 1h |",
        ),
        encoding="utf-8",
    )

    assert run_check(registry, "--fix").returncode == 0
    content = registry.read_text(encoding="utf-8")
    assert "| 8 |" in content
    assert "| 9 |" in content
    assert "| ~~7~~ |" in content
    assert run_check(registry, "--exit-nonzero").returncode == 0


def test_linter_ignores_status_legend(tmp_path: Path):
    registry = tmp_path / "WP-REGISTRY.md"
    registry.write_text(
        (
            "| Эмодзи | Статус | Что значит |\n"
            "|---|---|---|\n"
            "| ✅ | done | Завершён, артефакт принят |\n\n"
            + registry_text("| 8 | P3 | Канонический | ⏳ | DS-strategy | 1h |")
        ),
        encoding="utf-8",
    )

    result = run_check(registry, "--exit-nonzero")

    assert result.returncode == 0, result.stdout + result.stderr
    assert "T2 (форматирование done-строк): 0 нарушений" in result.stdout


def test_builder_normalizes_legacy_number_but_deep_check_reports_source(tmp_path: Path):
    governance = tmp_path / "DS-strategy"
    (governance / "docs").mkdir(parents=True)
    (governance / "current").mkdir()
    (governance / "inbox" / "WP-008").mkdir(parents=True)
    (governance / "archive" / "wp-contexts" / "WP-007").mkdir(parents=True)
    (governance / "docs" / "WP-REGISTRY.md").write_text(
        registry_text(
            "| WP-8 | P3 | Активный | ⏳ | DS-strategy | 1h |",
            "| ~~WP-7~~ | ~~P3~~ | ~~Закрытый~~ | ✅ | ~~DS-strategy~~ | 1h |",
        ),
        encoding="utf-8",
    )
    env = {
        **os.environ,
        "IWE_ROOT": str(tmp_path),
        "IWE_GOVERNANCE_REPO": "DS-strategy",
        "PYTHONIOENCODING": "utf-8",
    }

    build = subprocess.run(
        [sys.executable, str(BUILD_ACTIVE)], env=env, capture_output=True, text=True, encoding="utf-8"
    )
    assert build.returncode == 0, build.stdout + build.stderr
    active = (governance / "current" / "active-wp.md").read_text(encoding="utf-8")
    assert "| 8 | P3 | Активный" in active
    assert "| ~~7~~ | ~~P3~~ | ~~Закрытый~~" in active
    assert "| WP-8 |" not in active
    assert "| ~~WP-7~~ |" not in active

    deep = subprocess.run(
        [sys.executable, str(BUILD_ACTIVE), "--deep-check"],
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    assert deep.returncode == 1
    assert "неканонический номер" in deep.stderr
