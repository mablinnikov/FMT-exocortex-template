#!/usr/bin/env python3
"""Validate staged IWE DayPlan, WeekPlan, and WeekReport artifacts."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


DAY_PLAN_RE = re.compile(r"^current/DayPlan.*\.md$")
WEEK_PLAN_RE = re.compile(r"^current/WeekPlan.*\.md$")
WEEK_REPORT_RE = re.compile(r"^current/WeekReport.*\.md$")


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-c", f"safe.directory={repo.as_posix()}", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return result.stdout


def staged_paths(repo: Path) -> list[str]:
    return [
        line.replace("\\", "/")
        for line in git(
            repo, "diff", "--cached", "--name-only", "--diff-filter=ACMR"
        ).splitlines()
        if line.strip()
    ]


def staged_text(repo: Path, relative: str) -> str:
    return git(repo, "show", f":{relative}")


def section_line_count(lines: list[str], heading: re.Pattern[str]) -> int:
    inside = False
    count = 0
    for line in lines:
        if not inside and heading.search(line):
            inside = True
            count += 1
            continue
        if inside and re.match(r"^##\s+", line):
            break
        if inside:
            count += 1
    return count


def section_text(lines: list[str], heading: re.Pattern[str]) -> str:
    inside = False
    selected: list[str] = []
    for line in lines:
        if not inside and heading.search(line):
            inside = True
            continue
        if inside and re.match(r"^##\s+", line):
            break
        if inside:
            selected.append(line)
    return "\n".join(selected)


def mandatory_wps_configured(repo: Path) -> bool:
    config = repo.parent / "memory" / "day-rhythm-config.yaml"
    if not config.is_file():
        return False

    lines = config.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        match = re.match(r"^mandatory_daily_wps:\s*(.*?)\s*$", line)
        if not match:
            continue
        inline = match.group(1).strip().lower()
        if inline:
            return inline not in {"[]", "{}", "null", "~", "false"}
        for nested in lines[index + 1 :]:
            if nested and not nested[0].isspace():
                break
            if re.match(r"^\s+-\s+\S", nested):
                return True
        return False
    return False


def validate_day_plan(repo: Path, relative: str) -> list[str]:
    text = staged_text(repo, relative)
    lines = text.splitlines()
    issues: list[str] = []

    required_sections = (
        r"План на сегодня|Plan for Today|Today.s Plan",
        r"Календарь|Calendar",
        r"IWE за ночь|IWE Overnight",
        r"Разбор заметок|Notes Review",
        r"Итоги вчера|Yesterday",
    )
    for section in required_sections:
        if not re.search(section, text):
            issues.append(f"DayPlan: отсутствует секция «{section}»")

    headings = sum(
        1 for line in lines if re.match(r"^##\s+", line) or re.match(r"^\s*<summary>", line)
    )
    if headings < 3:
        issues.append(f"DayPlan: найдено секций {headings}, требуется не менее 3")

    if section_line_count(lines, re.compile(r"Календарь|Calendar")) < 3:
        issues.append("DayPlan: секция календаря пустая или слишком короткая")

    if "Наработки Scout" in text:
        scout = section_text(lines, re.compile(r"Наработки Scout"))
        if not re.search(r"наход|capture|статус|нет|find|disabled|not configured", scout, re.IGNORECASE):
            issues.append("DayPlan: секция «Наработки Scout» присутствует, но не содержит результата")

    has_multiplier = re.search(r"~[0-9]+(?:\.[0-9]+)?x", text)
    multiplier_disabled = re.search(r"мультипликатор.*(?:не считаю|не наст)", text, re.IGNORECASE)
    if not has_multiplier and not multiplier_disabled:
        issues.append("DayPlan: нет мультипликатора «~N.Nx» или отметки, что он не рассчитывается")

    if not re.search(r"~[0-9]+(?:\.[0-9]+)?\s*[hч]\s+РП", text):
        issues.append("DayPlan: бюджет дня не соответствует формату «~Xч РП / ~Yч физ»")

    if mandatory_wps_configured(repo) and not re.search(r"mandatory", text, re.IGNORECASE):
        issues.append("DayPlan: не отражена обязательная проверка mandatory_daily_wps")

    day_plans = sorted((repo / "current").glob("DayPlan *.md"))
    if len(day_plans) > 1 and not re.search(r"carry.over|carry_over", text, re.IGNORECASE):
        issues.append("DayPlan: отсутствует carry-over из предыдущего дня")

    return issues


def validate_week_plan(repo: Path, relative: str) -> list[str]:
    lines = staged_text(repo, relative).splitlines()
    headings = sum(
        1 for line in lines if re.match(r"^##\s+", line) or re.match(r"^\s*<summary>", line)
    )
    if len(lines) > 80 and headings < 3:
        return [f"WeekPlan: {len(lines)} строк, но найдено только {headings} структурных секций"]
    return []


def validate_week_report(repo: Path, relative: str) -> list[str]:
    if "Итоги" not in staged_text(repo, relative):
        return ["WeekReport: отсутствует секция «Итоги»"]
    return []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--staged", action="store_true", help="validate the Git index")
    args = parser.parse_args()

    if not args.staged:
        parser.error("only --staged mode is supported")

    repo = args.repo.resolve()
    try:
        paths = staged_paths(repo)
        day_plans = sorted(path for path in paths if DAY_PLAN_RE.match(path))
        week_plans = sorted(path for path in paths if WEEK_PLAN_RE.match(path))
        week_reports = sorted(path for path in paths if WEEK_REPORT_RE.match(path))

        issues: list[str] = []
        if day_plans:
            issues.extend(validate_day_plan(repo, day_plans[-1]))
        if week_plans:
            issues.extend(validate_week_plan(repo, week_plans[-1]))
        if week_reports:
            issues.extend(validate_week_report(repo, week_reports[-1]))
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"PROTOCOL ARTIFACT: проверка не выполнена: {error}", file=sys.stderr)
        return 1

    if issues:
        print("PROTOCOL ARTIFACT: проверка не пройдена:", file=sys.stderr)
        for issue in issues:
            print(f"  - {issue}", file=sys.stderr)
        return 1

    if day_plans or week_plans or week_reports:
        print("PROTOCOL ARTIFACT: staged-артефакты прошли проверку")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
