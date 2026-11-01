#!/usr/bin/env bash
# Offline tests for src/shell/lib/progress.sh (and the copy embedded in the DB manager).
# shellcheck disable=SC2015,SC2016,SC2209  # test one-liners; the bash -c bodies are literal
set -euo pipefail
cd "$(dirname "$0")/../.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
unset NO_COLOR SIW_QUIET SIW_PROGRESS SIW_VERBOSE SIW_COMPAT_NOTED VSW_QUIET VSW_PROGRESS VSW_VERBOSE
P=src/shell/lib/progress.sh M=src/shell/db/docker-db-server-manager.sh
S() { bash -c 'set -euo pipefail; source "$0"; '"$1" "$P"; }   # S '<body>' with progress.sh loaded

SIW_PROGRESS=plain S 'progress_run "copy" echo hello' >"$T/o" 2>"$T/e"
grep -qx hello "$T/o" && grep -q '\.\.    copy' "$T/e" && grep -q 'done  copy  (0:0' "$T/e" && ok "plain: output passes through, start + done lines on stderr" || fail "plain run"
SIW_PROGRESS=plain S 'progress_run "boom" sh -c "exit 7"' >/dev/null 2>"$T/e" && fail "exit code lost" || rc=$?
[ "${rc:-0}" = 7 ] && grep -q 'FAIL  boom.*exit 7' "$T/e" && ok "run returns the command's exit code and says FAIL" || fail "rc"
SIW_PROGRESS=plain S 'f(){ false; echo after; }; progress_run "errexit" f' >"$T/o" 2>/dev/null && fail "set -e ignored" || true
! grep -q after "$T/o" && ok "set -e still applies inside a wrapped function" || fail "errexit"
SIW_PROGRESS=tty NO_COLOR=1 S 'progress_run "quiet ok" echo secret-ish' >"$T/o" 2>"$T/e"
[ ! -s "$T/o" ] && ! grep -q 'secret-ish' "$T/e" && grep -q 'done  quiet ok' "$T/e" && ! grep -q $'\033\\[3' "$T/e" && ok "tty: output captured on success; NO_COLOR drops colour" || fail "tty ok"
SIW_PROGRESS=tty S 'progress_run "loud" sh -c "echo why-it-failed; exit 3"' >/dev/null 2>"$T/e" || true
grep -q '        why-it-failed' "$T/e" && grep -q $'\033\\[31mFAIL' "$T/e" && ok "tty: captured output replayed on failure, in colour" || fail "tty fail"
SIW_QUIET=1 S 'progress_step x; progress_run "q" echo out; progress_bar 1 2 y' >"$T/o" 2>"$T/e"
[ ! -s "$T/e" ] && grep -qx out "$T/o" && ok "SIW_QUIET=1: no progress output, command output kept" || fail "quiet"
SIW_PROGRESS=plain S 'PROGRESS_TOTAL=3; progress_step one; progress_step two' 2>"$T/e"
grep -q '==> \[1/3\] one' "$T/e" && grep -q '==> \[2/3\] two' "$T/e" && ok "step counter [i/n] with elapsed" || fail "step"
SIW_PROGRESS=plain S 'for i in $(seq 0 40); do progress_bar "$i" 40 rows; done' 2>"$T/e"
[ "$(wc -l < "$T/e" | tr -d ' ')" = 11 ] && grep -q ' 50% 20/40 rows' "$T/e" && grep -q '100% 40/40 rows' "$T/e" && ok "plain bar: one line per 10%" || { cat "$T/e"; fail "bar"; }
SIW_PROGRESS=tty S 'progress_bar 0 4 x; PROGRESS_BAR_T0=$(( $(date +%s) - 10 )); progress_bar 2 4 x; progress_bar 4 4 x' 2>"$T/e"
grep -q '\[############------------\]  50% 2/4 x  0:10 eta 0:10' "$T/e" && ok "tty bar: fill, percent, elapsed and ETA" || { cat -v "$T/e"; fail "eta"; }
if SIW_PROGRESS=plain S 'progress_wait "never" 1 1 false' 2>"$T/e"; then fail "wait timeout"; fi
grep -q 'timed out after 0:01' "$T/e" && ok "wait: times out with FAIL" || fail "wait"
SIW_PROGRESS=plain S 'n=0; c(){ [ -f "$1" ]; }; (sleep 1; touch "$0.x") & progress_wait "file" 10 1 c "$0.x"; rm -f "$0.x"' 2>"$T/e" && grep -q 'done  file' "$T/e" && ok "wait: returns when the check passes" || fail "wait ok"
VSW_QUIET=1 S 'progress_run "q" echo out; echo "Q=$SIW_QUIET"' >"$T/o" 2>"$T/e"
grep -qx 'Q=1' "$T/o" && [ "$(grep -c 'VSW_QUIET is deprecated, use SIW_QUIET' "$T/e")" = 1 ] && ! grep -q 'done  q' "$T/e" && ok "pre-rename VSW_QUIET still works, with one deprecation notice" || fail "VSW_ fallback"
SIW_PROGRESS=plain VSW_PROGRESS=off S 'progress_run "p" true; bash -c "source \"$0\"; true" "$0"' >/dev/null 2>"$T/e"
grep -q 'done  p' "$T/e" && [ "$(grep -c 'deprecated' "$T/e")" = 1 ] && ok "SIW_* wins over VSW_*; a nested tool does not repeat the notice" || { cat "$T/e"; fail "SIW_ precedence"; }
SP() { bash -c 'TOOL=t; . src/shell/lib/common.sh; siw_path "$0/var/log/server-infra-workbench"' "$T/r"; }
mkdir -p "$T/r/var/log"; n1="$(SP)"; mkdir -p "$T/r/var/log/vps-server-workbench"; n2="$(SP)"; mkdir -p "$T/r/var/log/server-infra-workbench"; n3="$(SP)"
[ "$n1" = "$T/r/var/log/server-infra-workbench" ] && [ "$n2" = "$T/r/var/log/vps-server-workbench" ] && [ "$n3" = "$n1" ] \
  && ok "siw_path: new dir, or the pre-rename one while only that exists" || fail "siw_path: $n1 $n2 $n3"
[ "$(sed -n '/^# >>> progress.sh/,/^# <<< progress.sh/p' "$P")" = "$(sed -n '/^# >>> progress.sh/,/^# <<< progress.sh/p' "$M")" ] \
  && ok "the DB manager's embedded copy matches lib/progress.sh" || fail "embedded progress.sh drifted: copy lib/progress.sh between the markers in the manager"
echo "smoke-progress: all $pass checks passed"
