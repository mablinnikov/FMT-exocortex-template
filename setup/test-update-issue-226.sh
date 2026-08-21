#!/bin/bash
# test-issue-226.sh — end-to-end smoke test for the 3 update.sh fixes (issue #226)
#
# Runs the REAL update.sh against a sandboxed SCRIPT_DIR/WORKSPACE_DIR, with a
# curl shim serving fixture "upstream" content instead of hitting GitHub.
#
# Scenario A (defect 1 + defect 3): workspace CLAUDE.md conflicts on merge.
#   Assert: hook + memory files still delivered, commit still happens,
#   update.sh exits non-zero (EXIT_CONFLICT=49), branch guard skips commit
#   on a non-default branch.
# Scenario B (defect 2): rerun with SCRIPT_DIR already at upstream version
#   (TOTAL_CHANGES=0) but workspace missing a hook file.
#   Assert: repair-pass fires even on the "всё актуально" early-exit path.
#
# Usage:
#   bash setup/test-update-issue-226.sh
#   KEEP=1 bash setup/test-update-issue-226.sh   # keep /tmp dir for inspection

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE_SH_REAL="$(dirname "$SELF_DIR")/update.sh"
TEST_ROOT="${ISSUE_226_WORKSPACE:-/tmp/iwe-issue-226-test-$$}"
FAKE_HOME="$TEST_ROOT/fake-home"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

mkdir -p "$TEST_ROOT" "$FAKE_HOME"

# ------------------------------------------------------------------
# Fixture: fake "upstream" tree (what curl will serve)
# ------------------------------------------------------------------
UPSTREAM="$TEST_ROOT/upstream"
mkdir -p "$UPSTREAM/.claude/hooks"

cat > "$UPSTREAM/CLAUDE.md" <<'EOF'
# Template CLAUDE.md

## 1. Platform section

Upstream v2 content.
EOF

cat > "$UPSTREAM/.claude/hooks/dummy-hook.sh" <<'EOF'
#!/bin/bash
echo "dummy hook v2"
EOF

mkdir -p "$UPSTREAM/memory"
cat > "$UPSTREAM/memory/dummy-memo.md" <<'EOF'
# Dummy memo v2
EOF

python3 -c "
import hashlib
import json
from pathlib import Path

root = Path('$UPSTREAM')
def entry(path):
    return {'path': path, 'sha256': hashlib.sha256((root / path).read_bytes()).hexdigest()}

manifest = {
    'schema_version': 2,
    'version': '0.99.0-test-226',
    'files': [
        entry('CLAUDE.md'),
        entry('.claude/hooks/dummy-hook.sh'),
        entry('memory/dummy-memo.md'),
    ],
    'deprecated_files': [],
}
with open('$UPSTREAM/update-manifest.json', 'w') as f:
    json.dump(manifest, f)
"

# ------------------------------------------------------------------
# Fixture: SCRIPT_DIR (local FMT-exocortex-template copy) — "old" state
# ------------------------------------------------------------------
SCRIPT_DIR="$TEST_ROOT/repo/FMT-exocortex-template"
mkdir -p "$SCRIPT_DIR/.claude/hooks" "$SCRIPT_DIR/.claude/lib" "$SCRIPT_DIR/scripts/lib" "$SCRIPT_DIR/memory"
cp "$UPDATE_SH_REAL" "$SCRIPT_DIR/update.sh"
cp "$SELF_DIR/../.claude/lib/frontmatter.sh" "$SCRIPT_DIR/.claude/lib/frontmatter.sh"
cp "$SELF_DIR/../scripts/lib/common.sh" "$SCRIPT_DIR/scripts/lib/common.sh"
chmod +x "$SCRIPT_DIR/update.sh"

cat > "$SCRIPT_DIR/CLAUDE.md" <<'EOF'
# Template CLAUDE.md

## 1. Platform section

Upstream v1 content (old).
EOF
cp "$SCRIPT_DIR/CLAUDE.md" "$SCRIPT_DIR/.claude.md.base"

WORKSPACE_DIR="$TEST_ROOT/repo"

# Workspace CLAUDE.md: user edited the SAME line the upstream also changed → real conflict
cat > "$WORKSPACE_DIR/CLAUDE.md" <<'EOF'
# Template CLAUDE.md

## 1. Platform section

Upstream v1 content (old).

## 9. My custom section

Pilot's own text, must survive.
EOF
sed_inplace() { sed -i '' "$@" 2>/dev/null || sed -i "$@"; }
sed_inplace 's/Upstream v1 content (old)\./User edited this exact line locally./' "$WORKSPACE_DIR/CLAUDE.md"
cp "$SCRIPT_DIR/CLAUDE.md" "$WORKSPACE_DIR/.claude.md.base"

git -C "$SCRIPT_DIR" init -q
git -C "$SCRIPT_DIR" config user.email t@t; git -C "$SCRIPT_DIR" config user.name t
git -C "$SCRIPT_DIR" add -A; git -C "$SCRIPT_DIR" commit -q -m init
# Simulate the reported scenario: HEAD sits on a contributor PR branch, not main.
git -C "$SCRIPT_DIR" checkout -q -b some-pr-branch

# ------------------------------------------------------------------
# curl shim: intercepts raw.githubusercontent.com/<REPO>/<BRANCH>/<path>
# ------------------------------------------------------------------
SHIM_DIR="$TEST_ROOT/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/curl" <<SHIMEOF
#!/bin/bash
# WP-546 Ф2 (main 8112b1a) switched update.sh's batch download from one
# "curl -o dest url" per file to a single "curl --parallel -K configfile"
# call (url/output pairs live inside the config file, not argv) — this shim
# originally only understood the single-file shape, so every batch call
# fell through with url="" out="", hit the else branch below and exited 22
# for the WHOLE batch. Found live: 9/19 scenarios in this file failing on
# real CI after that merge (Scenario A/C/E), traced to exactly this gap.
simulate_one_transfer() {
    local u="\$1" o="\$2"
    local rel="\${u#*/main/}"
    if [ "\$rel" = "update.sh" ]; then
        cp "$SCRIPT_DIR/update.sh" "\$o"
    elif [ "\$rel" = "update-manifest.json" ]; then
        cp "$UPSTREAM/update-manifest.json" "\$o"
    else
        local src="$UPSTREAM/\$rel"
        [ -f "\$src" ] && cp "\$src" "\$o" || return 22
    fi
}

url="" out="" cfgfile=""
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
    case "\${args[i]}" in
        http*) url="\${args[i]}" ;;
        -o) out="\${args[i+1]}" ;;
        -K) cfgfile="\${args[i+1]}" ;;
    esac
done

if [ -n "\$cfgfile" ]; then
    # -K batch mode (download_batch()): url/output come in pairs, one per
    # line, no shell metacharacters expected — parsed as plain text, never
    # eval'd. Real curl --parallel --remove-on-error keeps going after one
    # transfer fails and lets the others still land, so a missing upstream
    # file here skips just that pair, not the whole batch (matches
    # simulate_one_transfer's per-file "no source -> no output" contract) —
    # but the shim still reports the batch as failed overall (had_error) if
    # anything in it didn't make it, same as real curl's own exit code.
    had_error=0
    pending_url=""
    # The '|| [ -n LINE ]' guard below: read returns non-zero on the
    # final line of a file with no trailing newline, which would otherwise
    # skip that line's pair entirely and silently under-report a failure —
    # today's config always ends in \n (download_batch's own printf appends
    # it, update.sh) so this doesn't currently fire, but the loop shouldn't
    # quietly depend on that (cold-context review).
    while IFS= read -r line || [ -n "\$line" ]; do
        case "\$line" in
            'url = '*)
                [ -n "\$pending_url" ] && had_error=1  # unpaired url before this one
                pending_url=\$(printf '%s' "\$line" | sed -e 's/^url = "//' -e 's/"\$//')
                ;;
            'output = '*)
                if [ -z "\$pending_url" ]; then
                    had_error=1  # output with no preceding url — malformed pair
                else
                    pending_out=\$(printf '%s' "\$line" | sed -e 's/^output = "//' -e 's/"\$//')
                    simulate_one_transfer "\$pending_url" "\$pending_out" || had_error=1
                    pending_url=""
                fi
                ;;
        esac
    done < "\$cfgfile"
    [ -n "\$pending_url" ] && had_error=1  # trailing url with no output line
    exit "\$had_error"
fi

# Single-file mode (Step 0 self-update, manifest fetch — unchanged).
simulate_one_transfer "\$url" "\$out"
exit \$?
SHIMEOF
chmod +x "$SHIM_DIR/curl"

# ------------------------------------------------------------------
# Scenario A: run update.sh --yes on the non-default branch with a conflict
# ------------------------------------------------------------------
echo "--- Scenario A: CLAUDE.md conflict + non-default branch ---"
HEAD_A_BEFORE=$(git -C "$SCRIPT_DIR" rev-parse HEAD)
set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-a.log" 2>&1
RC_A=$?
set -e

if [ "$RC_A" -eq 49 ]; then
    pass "A: update.sh exits with EXIT_CONFLICT(49), not a silent success"
else
    fail "A: expected exit 49, got $RC_A"
fi

if [ -f "$WORKSPACE_DIR/.claude/hooks/dummy-hook.sh" ] && grep -q "v2" "$WORKSPACE_DIR/.claude/hooks/dummy-hook.sh"; then
    pass "A: hook file still delivered to workspace despite CLAUDE.md conflict (defect 1)"
else
    fail "A: hook file was NOT delivered — defect 1 regression"
fi

CLAUDE_SLUG="$(echo "$WORKSPACE_DIR" | tr '/' '-')"
MEM_DST="$FAKE_HOME/.claude/projects/$CLAUDE_SLUG/memory/dummy-memo.md"
mkdir -p "$(dirname "$MEM_DST")"  # this dir must pre-exist for propagation per update.sh's own guard
# re-run only if propagation skipped it because dir didn't exist yet — check log for that path instead
if grep -q "dummy-memo" "$TEST_ROOT/out-a.log"; then
    pass "A: memory file propagation attempted (dummy-memo.md referenced in output)"
else
    fail "A: memory file propagation never attempted"
fi

if grep -q "конфликтов" "$TEST_ROOT/out-a.log"; then
    pass "A: conflict is reported to the user"
else
    fail "A: no conflict message found in output"
fi

if grep -qE "^\s*-\s*/.*CLAUDE\.md$" "$TEST_ROOT/out-a.log"; then
    pass "A: conflicted file path listed in final summary"
else
    fail "A: conflicted file path missing from final summary"
fi

if grep -q "Изменения оставлены незакоммиченными" "$TEST_ROOT/out-a.log"; then
    pass "A: updater explicitly leaves applied files uncommitted"
else
    fail "A: updater did not explain the no-autocommit contract"
fi

if [ "$HEAD_A_BEFORE" = "$(git -C "$SCRIPT_DIR" rev-parse HEAD)" ] && \
   [ -z "$(git -C "$SCRIPT_DIR" diff --cached --name-only)" ]; then
    pass "A: updater created no commit and changed no staged entries"
else
    fail "A: updater changed history or the user's index"
fi

if [ -f "$SCRIPT_DIR/.update-incomplete" ] && grep -q 'Обновление завершилось не полностью' "$TEST_ROOT/out-a.log"; then
    pass "A: conflict leaves an explicit incomplete-update marker"
else
    fail "A: conflict did not preserve/report incomplete update state"
fi

# ------------------------------------------------------------------
# Scenario B: SCRIPT_DIR already at upstream version (TOTAL_CHANGES=0),
# workspace hook file missing (simulates a prior interrupted run).
# ------------------------------------------------------------------
echo "--- Scenario B: repair-pass on the 'всё актуально' path ---"
git -C "$SCRIPT_DIR" checkout -q main 2>/dev/null || git -C "$SCRIPT_DIR" checkout -q -b main
cp "$UPSTREAM/CLAUDE.md" "$SCRIPT_DIR/CLAUDE.md"
cp "$SCRIPT_DIR/CLAUDE.md" "$SCRIPT_DIR/.claude.md.base"
cp "$UPSTREAM/.claude/hooks/dummy-hook.sh" "$SCRIPT_DIR/.claude/hooks/dummy-hook.sh"
cp "$UPSTREAM/memory/dummy-memo.md" "$SCRIPT_DIR/memory/dummy-memo.md"
cp "$UPSTREAM/update-manifest.json" "$SCRIPT_DIR/update-manifest.json"
rm -f "$WORKSPACE_DIR/.claude/hooks/dummy-hook.sh"
# Resolve the workspace CLAUDE.md conflict so it doesn't confuse this scenario
cp "$UPSTREAM/CLAUDE.md" "$WORKSPACE_DIR/CLAUDE.md"
cp "$UPSTREAM/CLAUDE.md" "$WORKSPACE_DIR/.claude.md.base"
git -C "$SCRIPT_DIR" add -A; git -C "$SCRIPT_DIR" commit -q -m "simulate: already at upstream version"

set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-b.log" 2>&1
RC_B=$?
set -e

if grep -q "Всё актуально" "$TEST_ROOT/out-b.log"; then
    pass "B: update.sh correctly reports 'всё актуально' (TOTAL_CHANGES=0)"
else
    fail "B: expected 'всё актуально' branch, output was:"; cat "$TEST_ROOT/out-b.log" >&2
fi

if [ -f "$WORKSPACE_DIR/.claude/hooks/dummy-hook.sh" ]; then
    pass "B: missing hook file was repaired even on the early-exit path (defect 2)"
else
    fail "B: hook file was NOT repaired — defect 2 regression (repair-pass unreachable)"
fi

if [ "$RC_B" -eq 0 ]; then
    pass "B: exit code 0 (no conflicts in this scenario)"
else
    fail "B: expected exit 0, got $RC_B"
fi

if [ ! -e "$SCRIPT_DIR/.update-incomplete" ]; then
    pass "B: successful recovery removes the incomplete-update marker"
else
    fail "B: incomplete-update marker survived a successful recovery"
fi

# ------------------------------------------------------------------
# Scenario C: same version and paths, changed content hash.
# --check --fast must detect it; full check must reject a bad payload hash.
# ------------------------------------------------------------------
echo "--- Scenario C: manifest content hashes (#378) ---"
printf '#!/bin/bash\necho "dummy hook v3"\n' > "$UPSTREAM/.claude/hooks/dummy-hook.sh"
python3 - "$UPSTREAM/update-manifest.json" "$UPSTREAM/.claude/hooks/dummy-hook.sh" <<'PY'
import hashlib
import json
import sys

manifest_path, content_path = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
digest = hashlib.sha256(open(content_path, "rb").read()).hexdigest()
for entry in manifest["files"]:
    if entry["path"] == ".claude/hooks/dummy-hook.sh":
        entry["sha256"] = digest
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY

PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT_DIR/update.sh" --check --fast > "$TEST_ROOT/out-c-fast.log" 2>&1
if grep -q "Состав манифеста изменился" "$TEST_ROOT/out-c-fast.log"; then
    pass "C: --check --fast detects a content-only change at the same version/path"
else
    fail "C: --check --fast missed a content-only manifest change"
fi

python3 - "$UPSTREAM/update-manifest.json" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
for entry in manifest["files"]:
    if entry["path"] == ".claude/hooks/dummy-hook.sh":
        entry["sha256"] = "0" * 64
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY

PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT_DIR/update.sh" --check > "$TEST_ROOT/out-c-integrity.log" 2>&1 || true
if grep -q "sha256 не совпадает" "$TEST_ROOT/out-c-integrity.log" && \
   grep -q "Проверка неполная" "$TEST_ROOT/out-c-integrity.log"; then
    pass "C: full check rejects a downloaded file that does not match manifest sha256"
else
    fail "C: payload integrity mismatch was not surfaced as an incomplete check"
fi

# ------------------------------------------------------------------
# Scenario D: owner:user drift is reported even when no file is in the
# current NEW_FILES/UPDATED_FILES list (#375).
# ------------------------------------------------------------------
echo "--- Scenario D: owner:user memory drift (#375) ---"
# Restore a valid, unchanged remote manifest/payload first.
cp "$UPSTREAM/.claude/hooks/dummy-hook.sh" "$SCRIPT_DIR/.claude/hooks/dummy-hook.sh"
python3 - "$UPSTREAM/update-manifest.json" "$UPSTREAM" <<'PY'
import hashlib
import json
import pathlib
import sys
manifest_path, root = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
for entry in manifest["files"]:
    entry["sha256"] = hashlib.sha256((pathlib.Path(root) / entry["path"]).read_bytes()).hexdigest()
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
cp "$UPSTREAM/update-manifest.json" "$SCRIPT_DIR/update-manifest.json"
mkdir -p "$(dirname "$MEM_DST")"
cat > "$MEM_DST" <<'EOF'
---
owner: user
---
Pilot-owned content that intentionally differs.
EOF

PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-d.log" 2>&1 || true
if grep -q "owner: user, НЕ обновлён, но шаблонная версия отличается" "$TEST_ROOT/out-d.log" && \
   grep -q 'Сверьте: diff' "$TEST_ROOT/out-d.log"; then
    pass "D: owner:user drift is visible with a comparison command on an unchanged run"
else
    fail "D: owner:user drift remained silent outside the changed-files list"
fi

# ------------------------------------------------------------------
# Scenario E: a genuine change (memo v2 → v3) lands alongside a manifest
# entry whose fetch fails (WP-529 Ф2). Before this fix, TOTAL_CHANGES>0
# meant the run applied the fetched files and stamped the local manifest as
# fully updated, leaving the failed file silently on the old version.
# ------------------------------------------------------------------
echo "--- Scenario E: partial fetch failure must abort, not partially apply (WP-529) ---"
printf '# Dummy memo v3\n' > "$UPSTREAM/memory/dummy-memo.md"
python3 - "$UPSTREAM/update-manifest.json" "$UPSTREAM" <<'PY'
import hashlib
import json
import pathlib
import sys
manifest_path, root = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
for entry in manifest["files"]:
    if entry["path"] == "memory/dummy-memo.md":
        entry["sha256"] = hashlib.sha256(
            (pathlib.Path(root) / entry["path"]).read_bytes()
        ).hexdigest()
# A manifest entry with no matching file under $UPSTREAM — the curl shim
# exits 22 for it, landing it in SKIPPED_DOWNLOAD.
manifest["files"].append({"path": "memory/never-fetched.md", "sha256": "0" * 64})
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
MEMO_BEFORE=$(cat "$SCRIPT_DIR/memory/dummy-memo.md")
MANIFEST_HASH_BEFORE=$(sha256sum "$SCRIPT_DIR/update-manifest.json" | cut -d' ' -f1)

set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-e.log" 2>&1
RC_E=$?
set -e

if [ "$RC_E" -eq 2 ]; then
    pass "E: update.sh exits with EXIT_NETWORK(2) on a partial fetch failure"
else
    fail "E: expected exit 2, got $RC_E"
fi

if grep -q "Обновление остановлено" "$TEST_ROOT/out-e.log"; then
    pass "E: abort is reported to the user with a clear reason"
else
    fail "E: no abort message found in output"
fi

if [ "$(cat "$SCRIPT_DIR/memory/dummy-memo.md")" = "$MEMO_BEFORE" ]; then
    pass "E: the file that WOULD have changed was left untouched (no partial apply)"
else
    fail "E: dummy-memo.md was updated despite the aborted run — partial apply regression"
fi

if [ "$(sha256sum "$SCRIPT_DIR/update-manifest.json" | cut -d' ' -f1)" = "$MANIFEST_HASH_BEFORE" ]; then
    pass "E: local update-manifest.json was not stamped as updated"
else
    fail "E: local manifest changed despite the aborted run"
fi

echo ""
echo "============================================"
echo "  Results: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
echo "============================================"
[ "$FAIL_COUNT" -eq 0 ]
