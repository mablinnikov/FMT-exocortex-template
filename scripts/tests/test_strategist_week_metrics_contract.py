#!/usr/bin/env python3
"""Regression contract for scheduled Strategist weekly metrics."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def test_session_prep_defers_missing_week_review() -> None:
    prompt = read("roles/strategist/prompts/session-prep.md")
    assert "ожидает Week Review" in prompt
    assert "НЕ вычисляй X/Y самостоятельно" in prompt
    assert "собрать коммиты самостоятельно (fallback)" not in prompt


def test_week_review_owns_and_checks_denominator() -> None:
    prompt = read("roles/strategist/prompts/week-review.md")
    assert "Знаменатель Y = количество уникальных строк РП" in prompt
    assert "а не максимальное значение колонки `#`" in prompt
    assert "Y совпадает с числом строк" in prompt
    assert "замени весь placeholder" in prompt


def test_week_review_log_has_no_fixed_weekday() -> None:
    runner = read("roles/strategist/scripts/strategist.sh")
    assert 'log "Scheduled: running week review"' in runner
    assert 'log "Sunday: running week review"' not in runner
