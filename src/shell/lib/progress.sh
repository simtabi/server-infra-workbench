# shellcheck shell=bash
# progress.sh - spinner, bar, ETA and elapsed time for long steps, on stderr so stdout stays parseable.
# Embedded verbatim in the DB manager between the "progress.sh" markers (it is uploaded as one file);
# tests/shell/smoke-progress.sh fails when the two copies drift.
#
#   VSW_PROGRESS  auto (default: animate when stderr is a terminal, plain lines otherwise) | tty | plain | off
#   VSW_QUIET=1   no progress output at all (tools map --quiet to this); NO_COLOR=1 drops colour
#
#   progress_step "label"                  "==> [3/7] label" when PROGRESS_TOTAL is set, plus total elapsed
#   progress_run  "label" cmd [args...]    run cmd with a spinner + elapsed; returns cmd's exit code.
#                                          tty: output is captured and shown only on failure (or VSW_VERBOSE=1);
#                                          plain: output passes through (cron logs keep it). cmd runs in a
#                                          background subshell so `set -e` still applies inside it; use it
#                                          for work whose result is on disk or in containers, not in variables.
#   progress_bar  i n "label"              bar + percent + elapsed + ETA (plain: one line per 10%)
#   progress_wait "label" TIMEOUT_S INTERVAL_S cmd [args...]   poll cmd until it succeeds; 1 on timeout
# >>> progress.sh
PROGRESS_T0="${PROGRESS_T0:-$(date +%s)}" PROGRESS_N=0 PROGRESS_BAR_T0="" PROGRESS_BAR_DEC=-1
progress_mode() {
  [ "${VSW_QUIET:-0}" = 1 ] && { echo off; return; }
  case "${VSW_PROGRESS:-auto}" in
    tty|plain|off) echo "$VSW_PROGRESS" ;;
    *) if [ -t 2 ] && [ "${TERM:-dumb}" != dumb ]; then echo tty; else echo plain; fi ;;
  esac
}
progress_fmt() { local s="$1"; if [ "$s" -ge 3600 ]; then printf '%d:%02d:%02d' $((s / 3600)) $((s % 3600 / 60)) $((s % 60)); else printf '%d:%02d' $((s / 60)) $((s % 60)); fi; }
progress_col() { # progress_col 32 text: colour only on a terminal without NO_COLOR
  if [ -z "${NO_COLOR:-}" ] && [ "$(progress_mode)" = tty ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi
}
progress_step() {
  local m; m="$(progress_mode)"; [ "$m" = off ] && return 0
  PROGRESS_N=$((PROGRESS_N + 1))
  local n=""; [ -n "${PROGRESS_TOTAL:-}" ] && n="[$PROGRESS_N/$PROGRESS_TOTAL] "
  printf '%s %s%s  (%s)\n' "$(progress_col 36 '==>')" "$n" "$1" "$(progress_fmt $(($(date +%s) - PROGRESS_T0)))" >&2
}
progress_run() {
  local label="$1" m t0 pid rc=0 log="" i=0 f="|/-\\"; shift; m="$(progress_mode)"; t0="$(date +%s)"
  if [ "$m" = tty ]; then
    log="$(mktemp "${TMPDIR:-/tmp}/vsw-progress.XXXXXX")"
    "$@" >"$log" 2>&1 </dev/null & pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s %s  %s ' "${f:i++%4:1}" "$label" "$(progress_fmt $(($(date +%s) - t0)))" >&2; sleep 0.2
    done
    wait "$pid" || rc=$?; printf '\r\033[K' >&2
  else
    [ "$m" = plain ] && printf '  ..    %s\n' "$label" >&2
    "$@" </dev/null & pid=$!; wait "$pid" || rc=$?
  fi
  local e; e="$(progress_fmt $(($(date +%s) - t0)))"
  if [ "$rc" = 0 ]; then [ "$m" = off ] || printf '  %s  %s  (%s)\n' "$(progress_col 32 'done')" "$label" "$e" >&2
  else [ "$m" = off ] || printf '  %s  %s  (%s, exit %s)\n' "$(progress_col 31 'FAIL')" "$label" "$e" "$rc" >&2; fi
  if [ -n "$log" ]; then { [ "$rc" != 0 ] || [ "${VSW_VERBOSE:-0}" = 1 ]; } && sed 's/^/        /' "$log" | tail -n 40 >&2; rm -f "$log"; fi
  return "$rc"
}
progress_bar() {
  local i="$1" n="$2" label="${3:-}" m now el eta="" pct w=24 fill; m="$(progress_mode)"; [ "$m" = off ] && return 0
  [ "$n" -gt 0 ] 2>/dev/null || return 0
  now="$(date +%s)"; { [ -z "$PROGRESS_BAR_T0" ] || [ "$i" -eq 0 ]; } && { PROGRESS_BAR_T0="$now"; PROGRESS_BAR_DEC=-1; }
  [ "$i" -gt "$n" ] && i="$n"
  pct=$((i * 100 / n)) el=$((now - PROGRESS_BAR_T0))
  [ "$i" -gt 0 ] && [ "$i" -lt "$n" ] && eta=" eta $(progress_fmt $((el * (n - i) / i)))"
  if [ "$m" = tty ]; then
    fill=$((i * w / n)); printf '\r  [%s%s] %3d%% %d/%d %s  %s%s\033[K' "$(printf '%*s' "$fill" '' | tr ' ' '#')" \
      "$(printf '%*s' $((w - fill)) '' | tr ' ' '-')" "$pct" "$i" "$n" "$label" "$(progress_fmt "$el")" "$eta" >&2
    [ "$i" -eq "$n" ] && printf '\n' >&2
  elif [ $((pct / 10)) -ne "$PROGRESS_BAR_DEC" ]; then
    PROGRESS_BAR_DEC=$((pct / 10)); printf '  %3d%% %d/%d %s  %s%s\n' "$pct" "$i" "$n" "$label" "$(progress_fmt "$el")" "$eta" >&2
  fi
  return 0
}
progress_wait() {
  local label="$1" to="$2" iv="$3" m t0 i=0 f="|/-\\"; shift 3; m="$(progress_mode)"; t0="$(date +%s)"
  [ "$m" = plain ] && printf '  ..    waiting: %s (up to %ss)\n' "$label" "$to" >&2
  while ! "$@" >/dev/null 2>&1; do
    if [ $(($(date +%s) - t0)) -ge "$to" ]; then
      [ "$m" = tty ] && printf '\r\033[K' >&2
      [ "$m" = off ] || printf '  %s  %s  (timed out after %s)\n' "$(progress_col 31 'FAIL')" "$label" "$(progress_fmt "$to")" >&2
      return 1
    fi
    [ "$m" = tty ] && printf '\r  %s %s  %s / %s ' "${f:i++%4:1}" "$label" "$(progress_fmt $(($(date +%s) - t0)))" "$(progress_fmt "$to")" >&2
    sleep "$iv"
  done
  [ "$m" = tty ] && printf '\r\033[K' >&2
  [ "$m" = off ] || printf '  %s  %s  (%s)\n' "$(progress_col 32 'done')" "$label" "$(progress_fmt $(($(date +%s) - t0)))" >&2
  return 0
}
# <<< progress.sh
