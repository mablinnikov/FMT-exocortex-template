#!/usr/bin/env bash
# PreToolUse:Bash guard — blocks irreversible operations: git (staging, history,
# push/reset/clean), filesystem (rm -rf outside temp paths), prod DB (psql
# DROP/TRUNCATE/DELETE without WHERE), GitHub repo deletion. Exit 2 = block.
set -euo pipefail

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -z "$CMD" ] && exit 0
CWD=$(jq -r '.cwd // .tool_input.cwd // empty' 2>/dev/null || true)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WORKSPACE_ROOT="$(cd "$HOOK_DIR/../.." && pwd -P)"

block() {
  echo "BLOCKED: $1" >&2
  exit 2
}

# Bypass: только из реального шелла пилота (тот же контракт, что secret-leak-block.sh —
# хук читает свой процессный env, не текст команды, агент не может выставить это сам себе).
# Строгое сравнение с "1" (не -n) — та же несогласованность в secret-leak-block.sh
# (там -n) допустима для существующего кода, но не стоит копировать её в новый
# (пир-ревью Codex, WP-544 Ф1, 20.08): -n пропустил бы CC_ALLOW_DESTRUCTIVE_INPUT=0 как bypass.
[ "${CC_ALLOW_DESTRUCTIVE_INPUT:-}" = "1" ] && exit 0

# #362: a top-level `cd` persists between Bash calls in Claude Code. Strip
# quoted spans before detecting command segments; `(cd ... && ...)` remains
# allowed because the opening parenthesis is not a top-level separator.
if CMD_SCAN="$CMD" perl -e '
  my $s=$ENV{"CMD_SCAN"};
  $s =~ s/'"'"'[^'"'"']*'"'"'/ Q /g;
  $s =~ s/"(?:\\.|[^"\\])*"/ Q /g;
  exit($s =~ /(?:^|[;&|]\s*)cd\s+/ ? 0 : 1);
'; then
  block "верхнеуровневый cd запрещён: используй git -C <path>, абсолютный путь или (cd <path> && ...)."
fi

if [ -n "$CWD" ]; then
  CWD_PHYSICAL=$(cd "$CWD" 2>/dev/null && pwd -P || printf '%s' "$CWD")
  if [ "$CWD_PHYSICAL" != "$WORKSPACE_ROOT" ] && \
     echo "$CMD" | grep -qE "(^|[[:space:]\"'])(\\.claude/|scripts/|memory/)"; then
    block "root-relative path вызван из cwd=$CWD_PHYSICAL; используй абсолютный путь от $WORKSPACE_ROOT."
  fi
fi

git_segment() {
  # Print every normalised shell segment where `git <global-opts> <subcmd>` is
  # the command being executed, one segment per line. A regex over the raw
  # command saw `git reset` inside a quoted argument of another program as an
  # actual Git command, hence the tokeniser instead of a pattern.
  #
  # WP-544 Ф1, 22.08: the scanner used to split only on [;&|(){}`], so a newline
  # was an ordinary character. A multi-line script collapsed into ONE segment,
  # its first word decided everything, and `set -e` / `P=...` / `then` in front
  # of the real command made the guard silent (`git -C "$P" add -A` on line 3
  # went through). Newlines and shell keywords are handled here; heredoc bodies
  # are skipped because they are data for another program, not commands. This
  # is a concrete DP.FM.077 case: a detector claimed the whole command class
  # while inspecting only the first shell segment.
  local subcmd="$1"
  SUBCMD="$subcmd" CMD_SCAN="$CMD" perl -e '
    sub words {
      my ($text) = @_;
      my (@out, $word, $quote) = ();
      for (my $i = 0; $i < length($text); $i++) {
        my $char = substr($text, $i, 1);
        if (defined $quote) {
          if ($char eq "\\" && $quote eq q{"} && $i + 1 < length($text)) {
            $word .= substr($text, ++$i, 1);
          } elsif ($char eq $quote) {
            undef $quote;
          } else {
            $word .= $char;
          }
        } elsif ($char eq q{"} || $char eq chr(39)) {
          $quote = $char;
        } elsif ($char eq "\\" && $i + 1 < length($text)) {
          $word .= substr($text, ++$i, 1);
        } elsif ($char =~ /\s/) {
          push @out, $word if length $word;
          $word = q{};
        } else {
          $word .= $char;
        }
      }
      push @out, $word if length $word;
      return @out;
    }

    sub inspect_segment {
      my ($segment) = @_;
      my @tokens = words($segment);
      return unless @tokens;
      my $i = 0;
      while ($i < @tokens) {
        # Prefixes that keep the real command further right: env assignments,
        # command wrappers and the shell keywords that open a compound list
        # (`if git ...`, `; then git ...`, `; do git ...`).
        if ($tokens[$i] =~ /^[A-Za-z_][A-Za-z0-9_]*=/ ||
            $tokens[$i] =~ /^(?:command|env|nohup|time|sudo|exec|builtin)$/ ||
            $tokens[$i] =~ /^(?:if|elif|while|until|then|else|do|!)$/) {
          $i++;
        } else {
          last;
        }
      }
      return unless $i < @tokens && $tokens[$i] eq "git";
      my $start = $i++;
      while ($i < @tokens) {
        if ($tokens[$i] =~ /^-C$/ || $tokens[$i] =~ /^--(?:git-dir|work-tree)$/ || $tokens[$i] =~ /^-c$/) {
          $i += 2;
        } elsif ($tokens[$i] =~ /^--(?:git-dir|work-tree)=/ || $tokens[$i] =~ /^-c/) {
          $i++;
        } else {
          last;
        }
      }
      return unless $i < @tokens && $tokens[$i] eq $ENV{"SUBCMD"};
      my $out = join(" ", @tokens[$start .. $#tokens]);
      $out =~ tr/\n\r/  /;
      print $out, "\n";
    }

    my $sq = chr(39);
    my $text = $ENV{"CMD_SCAN"};
    my $len = length($text);
    my ($segment, $quote) = (q{}, undef);
    my @heredocs = ();
    my $i = 0;
    while ($i < $len) {
      my $char = substr($text, $i, 1);
      if (defined $quote) {
        $segment .= $char;
        if ($char eq "\\" && $quote eq q{"} && $i + 1 < $len) {
          $segment .= substr($text, ++$i, 1);
        } elsif ($char eq $quote) {
          undef $quote;
        }
        $i++;
        next;
      }
      if ($char eq q{"} || $char eq $sq) {
        $quote = $char;
        $segment .= $char;
        $i++;
        next;
      }
      if ($char eq "\\" && $i + 1 < $len) {
        # Line continuation glues two physical lines into one command.
        if (substr($text, $i + 1, 1) eq "\n") { $i += 2; next; }
        $segment .= substr($text, $i, 2);
        $i += 2;
        next;
      }
      # Heredoc: remember the delimiter, drop the body at the next newline.
      # Without this a document that merely quotes a forbidden command
      # (`cat > doc <<EOF ... EOF`) would be read as that command.
      if ($char eq "<" && substr($text, $i, 2) eq "<<" && substr($text, $i, 3) ne "<<<") {
        my $rest = substr($text, $i + 2);
        my $marker_len = 0;
        $marker_len++ if substr($rest, $marker_len, 1) eq "-";
        $marker_len++ while substr($rest, $marker_len, 1) =~ /[ \t]/;
        my ($delim, $end);
        my $marker_quote = substr($rest, $marker_len, 1);
        if ($marker_quote eq q{"} || $marker_quote eq $sq) {
          $end = index($rest, $marker_quote, $marker_len + 1);
          if ($end >= 0) {
            $delim = substr($rest, $marker_len + 1, $end - $marker_len - 1);
            $marker_len = $end + 1;
          }
        } elsif (substr($rest, $marker_len) =~ /^((?:\\.|[A-Za-z0-9_.\/-])+)/) {
          $delim = $1;
          $marker_len += length($1);
        }
        my $after = substr($rest, $marker_len, 1);
        if (defined $delim && ($after eq q{} || $after =~ /[ \t\r\n;|&<>]/)) {
          $delim =~ s/\\(.)/$1/g;
          push @heredocs, $delim;
          $i += 2 + $marker_len;
          $segment .= " ";
          next;
        }
      }
      if ($char eq "\n" && @heredocs) {
        inspect_segment($segment);
        $segment = q{};
        $i++;
        for my $delim (@heredocs) {
          while ($i < $len) {
            my $nl = index($text, "\n", $i);
            my $line = $nl < 0 ? substr($text, $i) : substr($text, $i, $nl - $i);
            $i = $nl < 0 ? $len : $nl + 1;
            last if $line =~ /^[ \t]*\Q$delim\E[ \t]*\r?$/;
          }
        }
        @heredocs = ();
        next;
      }
      if ($char =~ /[;&|(){}\n\r]/ || $char eq q{`}) {
        inspect_segment($segment);
        $segment = q{};
        $i++;
        next;
      }
      $segment .= $char;
      $i++;
    }
    inspect_segment($segment);
  '
}

is_git_subcmd() {
  [ -n "$(git_segment "$1")" ]
}

# git push --force / -f (allow the safe --force-with-lease)
PUSH_SEGMENT=$(git_segment push)
if [ -n "$PUSH_SEGMENT" ]; then
  PUSH_FORCE_SCAN=$(echo "$PUSH_SEGMENT" | sed -E 's/--force-with-lease(=[^[:space:]]*)?//g')
  if echo "$PUSH_FORCE_SCAN" | grep -qE -- '(^|[[:space:]])(--force([[:space:]]|=|$)|-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$))'; then
    block "git push --force запрещён. Используй --force-with-lease или согласуй с владельцем (CLAUDE.md §2)."
  fi
fi

# A hard reset is safe only when it cannot discard tracked work or local history:
# the tree must be clean and the target must contain the current HEAD. This still
# blocks resets that rewind a branch or erase uncommitted changes, while allowing
# a no-loss fast-forward reset used to repair a stale mirror.
reset_is_non_destructive() {
  local segment="$1" repo="${CWD:-$PWD}" target="" hard=false
  set -- $segment
  [ "${1:-}" = "git" ] || return 1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) repo="${2:-}"; shift 2 ;;
      --git-dir|--work-tree|-c) shift 2 ;;
      --git-dir=*|--work-tree=*|-c*) shift ;;
      *) break ;;
    esac
  done
  [ "${1:-}" = "reset" ] || return 1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --hard) hard=true ;;
      --) shift; [ $# -eq 1 ] || return 1; target="$1"; break ;;
      -*) ;;
      *) [ -z "$target" ] || return 1; target="$1" ;;
    esac
    shift
  done
  [ "$hard" = true ] && [ -n "$target" ] || return 1
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$repo" diff --quiet || return 1
  git -C "$repo" diff --cached --quiet || return 1
  git -C "$repo" merge-base --is-ancestor HEAD "$target" 2>/dev/null
}

# git reset --hard. git_segment prints one line per matching segment, and
# reset_is_non_destructive parses a single segment, so check them one by one.
RESET_SEGMENTS=$(git_segment reset)
while IFS= read -r RESET_SEGMENT; do
  [ -n "$RESET_SEGMENT" ] || continue
  echo "$RESET_SEGMENT" | grep -qE -- '(^|[[:space:]])--hard([[:space:]]|$)' || continue
  if reset_is_non_destructive "$RESET_SEGMENT"; then continue; fi
  block "git reset --hard запрещён (теряет незакоммиченное). Используй git stash."
done <<< "$RESET_SEGMENTS"

# git clean with delete flags (-f/-d/-x)
CLEAN_SEGMENT=$(git_segment clean)
if [ -n "$CLEAN_SEGMENT" ] && echo "$CLEAN_SEGMENT" | grep -qE -- '(^|[[:space:]])-[a-zA-Z]*[dfx]'; then
  block "git clean -fdx запрещён (удаляет неотслеживаемые файлы). Согласуй с владельцем."
fi

# git add -A/--all/-u/--update/bare-dot (I7, WP-458: AR.216 жил только в rule-engine.sh
# check_git_staged_only(), которая никогда не диспатчилась ни на одно живое событие —
# реальная защита срабатывала только на commit (install-hooks.sh Check 8), уже после
# стейджа. Здесь — фактический PreToolUse барьер, до того как чужие файлы попадут в индекс.
# WP-544 Ф1 Д5, 21.08: перенесено из личной установки, где было с 17.07 — устраняет
# расхождение версий хука между личной установкой и этим шаблоном.)
ADD_SEGMENT=$(git_segment add)
if [ -n "$ADD_SEGMENT" ]; then
  if echo "$ADD_SEGMENT" | grep -qE -- '(^|[[:space:]])(-A|--all|-u|--update)([[:space:]]|$)'; then
    block "git add -A/--all/-u/--update запрещён — подхватывает файлы других агентов (CLAUDE.md §Git Staging). Стейдж конкретные пути: git add <path>."
  fi
  if echo "$ADD_SEGMENT" | grep -qE -- '(^|[[:space:]])\.([[:space:]]|$)'; then
    block "git add . запрещён — подхватывает файлы других агентов (CLAUDE.md §Git Staging). Стейдж конкретные пути: git add <path>."
  fi
fi

# rm с одновременным recursive (-r/-R/--recursive) и force (-f/--force), в любом
# сочетании флагов (слитных или раздельных) — вне временных/scratch-путей, где это
# штатная уборка (пир-сессия с Codex, WP-544 Ф1, 20.08).
if echo "$CMD" | grep -qE '(^|[[:space:]])rm([[:space:]]|$)' \
  && echo "$CMD" | grep -qE -- '(^|[[:space:]])(-[^[:space:]]*[rR][^[:space:]]*|--recursive)([[:space:]]|$)' \
  && echo "$CMD" | grep -qE -- '(^|[[:space:]])(-[^[:space:]]*f[^[:space:]]*|--force)([[:space:]]|$)' \
  && ! echo "$CMD" | grep -qE '(/tmp/|/scratchpad/|\.claude/worktrees/)'; then
  block "rm -r -f (в любом сочетании флагов) вне /tmp, scratchpad или worktree запрещён — удаление необратимо. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# psql: DROP/TRUNCATE — необратимая потеря структуры/данных.
if echo "$CMD" | grep -qiE '\bpsql\b' && echo "$CMD" | grep -qiE '\b(DROP[[:space:]]+(TABLE|SCHEMA|DATABASE)|TRUNCATE)\b'; then
  block "DROP/TRUNCATE через psql запрещён — необратимая потеря данных. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# psql: DELETE FROM без WHERE в том же операторе (эвристика: сегмент до ближайшего
# ';' или конца строки — не защищает от WHERE в другом statement той же команды).
if echo "$CMD" | grep -qiE '\bpsql\b' \
  && echo "$CMD" | grep -qiE 'DELETE[[:space:]]+FROM' \
  && ! echo "$CMD" | grep -qiE 'DELETE[[:space:]]+FROM[^;]*[[:space:]]WHERE([[:space:]]|$)'; then
  block "DELETE FROM без WHERE через psql запрещён — удалит всю таблицу. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# удаление репозитория на GitHub — необратимо.
if echo "$CMD" | grep -qE '\bgh[[:space:]]+repo[[:space:]]+delete\b'; then
  block "gh repo delete запрещён — необратимо. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

exit 0
