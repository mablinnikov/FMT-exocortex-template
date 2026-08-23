"""Regression coverage for destructive-guard shell segments (DP.FM.077)."""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
DESTRUCTIVE_GUARD = ROOT / ".claude" / "hooks" / "destructive-guard.sh"
BASH = shutil.which("bash")


def run_guard(command: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [BASH, str(DESTRUCTIVE_GUARD)],
        input=json.dumps({"tool_input": {"command": command}, "cwd": str(ROOT)}),
        capture_output=True,
        text=True,
        check=False,
    )


@pytest.mark.skipif(not BASH or not shutil.which("jq"), reason="guard requires bash and jq")
@pytest.mark.parametrize(
    "command",
    (
        "git -C /tmp/repo add -A",
        'set -e\nP="/tmp/repo"\ngit -C "$P" add -A',
        "printf ready; git add --all",
        "true && git add -u",
        "false || git add --update",
        "printf x | git add .",
    ),
)
def test_destructive_guard_blocks_bulk_add_in_every_shell_segment(command: str):
    result = run_guard(command)

    assert result.returncode == 2, result.stdout + result.stderr
    assert "git add" in result.stderr


@pytest.mark.skipif(not BASH or not shutil.which("jq"), reason="guard requires bash and jq")
@pytest.mark.parametrize(
    "command",
    (
        "printf '%s' 'git add -A'",
        'printf "%s" "git add --all"',
        "cat <<'EOF'\ngit add -u\nEOF",
    ),
)
def test_destructive_guard_ignores_bulk_add_in_data(command: str):
    result = run_guard(command)

    assert result.returncode == 0, result.stdout + result.stderr
