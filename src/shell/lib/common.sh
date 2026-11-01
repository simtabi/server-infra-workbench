# shellcheck shell=bash disable=SC2153  # TOOL is set by each tool before sourcing
# common.sh - shared helpers for the server tools (server/*, web/diagnose).
# The tools embed nothing from here at run time on a server: `--host` copies the tool AND this file.
# Every tool: plan first, confirm (--yes, typed "yes", or a typed name on prd), lock, audit log, backups.
#
#   VSW_SYSROOT   prefix for every file the tools read or write (tests point it at a temp dir)
#   VSW_LOG_DIR   audit log dir (default /var/log/vps-server-workbench)
#   VSW_TTY       where typed confirmations are read from (default /dev/tty; tests use a file)
#   VSW_LOCK_DIR  lock dir (default /run/lock)
#   VSW_PROGRESS / VSW_QUIET / NO_COLOR  progress output (lib/progress.sh, loaded below)

# shellcheck source=src/shell/lib/progress.sh
. "$(dirname "${BASH_SOURCE[0]}")/progress.sh"

R="${VSW_SYSROOT:-}"
YES="${YES:-0}" DRY="${DRY:-0}"
c_ok=0 c_warn=0 c_fail=0 c_todo=0

die()  { printf '!! %s\n' "$*" >&2; exit "${CODE:-1}"; }
say()  { printf '%s\n' "$*"; }
ok()   { c_ok=$((c_ok + 1));     printf '  ok    %s\n' "$*"; }
warn() { c_warn=$((c_warn + 1)); printf '  warn  %s\n' "$*"; }
bad()  { c_fail=$((c_fail + 1)); printf '  FAIL  %s\n' "$*"; }
todo() { c_todo=$((c_todo + 1)); printf '  todo  %s\n' "$*"; }
why()  { printf '        why: %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
mute() { "$@" >/dev/null; }   # stdout off, errors still shown (progress_run "label" mute cmd)

audit() { # audit <outcome> <details...>; never logs values, only what was done
  local d="${VSW_LOG_DIR:-$R/var/log/vps-server-workbench}"
  { mkdir -p "$d" && chmod 700 "$d"; } 2>/dev/null || return 0
  printf '%s tool=%s by=%s host=%s outcome=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TOOL" \
    "${SUDO_USER:-$(id -un)}" "$(hostname 2>/dev/null || echo '?')" "$1" "${*:2}" >> "$d/audit.log" 2>/dev/null || true
}

lock() { # one run at a time per tool; mkdir is atomic everywhere (no flock on macOS)
  LOCK="${VSW_LOCK_DIR:-$R/run/lock}/vsw-$TOOL.lock"
  mkdir -p "$(dirname "$LOCK")" 2>/dev/null || true
  if ! mkdir "$LOCK" 2>/dev/null; then
    local pid; pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then die "another $TOOL run (pid $pid) holds $LOCK"; fi
    rm -rf "$LOCK"; mkdir "$LOCK" || die "cannot take $LOCK"
  fi
  echo $$ > "$LOCK/pid"; trap 'rm -rf "$LOCK"' EXIT
}

confirm() { # confirm "<what>" [typed-word]; --yes skips the plain prompt, never the typed word
  local what="$1" word="${2:-}" tty="${VSW_TTY:-/dev/tty}" reply=""
  # /dev/tty can exist and be readable yet fail to open without a controlling terminal (ssh without -t,
  # cron, CI): test that it opens, so a plan-only run ends with the clean message instead of a shell error
  { : < "$tty"; } 2>/dev/null || tty=/nonexistent
  if [ -n "$word" ]; then
    { [ -r "$tty" ] && printf 'Type %s to %s: ' "$word" "$what" > /dev/stderr && IFS= read -r reply < "$tty"; } || true
    [ "$reply" = "$word" ] && return 0
    audit not-confirmed "$what"; CODE=3 die "not confirmed (expected the typed word '$word')"
  fi
  [ "$YES" = 1 ] && return 0
  { [ -r "$tty" ] && printf '%s? Type yes: ' "$what" > /dev/stderr && IFS= read -r reply < "$tty"; } || true
  [ "$reply" = yes ] && return 0
  audit not-confirmed "$what"; CODE=3 die "not confirmed (type yes, or pass --yes)"
}

backup() { # backup FILE -> FILE.bak.<ts> (mode 600); prints the path
  [ -e "$1" ] || return 0
  local b; b="$1.bak.$(date +%Y%m%d%H%M%S)"
  (umask 077; cp -p "$1" "$b") && chmod 600 "$b" && printf '        backup: %s\n' "$b"
}

write_file() { # write_file PATH MODE < content ; atomic, keeps a backup when the content changes
  local f="$1" mode="$2" tmp; mkdir -p "$(dirname "$f")"
  tmp="$(mktemp "$(dirname "$f")/.vsw.XXXXXX")"; cat > "$tmp"; chmod "$mode" "$tmp"
  if [ -f "$f" ] && cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 0; fi
  backup "$f"; mv "$tmp" "$f"
}

remote() { # remote HOST TOOL_PATH ARGS... : copy the tool + lib (common, progress) over ssh, run with sudo, clean up
  # (REMOTE_EXTRA=(files) are copied next to the tool, e.g. a tool it calls;
  #  REMOTE_NOTTY=1 runs without a tty and with sudo -n, so stdout can be captured)
  local host="$1" tool="$2"; shift 2
  local here rdir q="" a; here="$(dirname "$tool")/../lib/common.sh"
  [[ "$host" =~ ^[A-Za-z0-9@._:-]+$ ]] || die "bad --host: $host"
  for a in "$@"; do q+=" $(printf '%q' "$a")"; done
  rdir="$(ssh "$host" 'umask 077; mktemp -d')" || die "ssh $host failed"
  # shellcheck disable=SC2029  # expanding locally is the point
  ssh "$host" "mkdir -p '$rdir/tool' '$rdir/lib'" || die "ssh $host failed"
  scp -q "$tool" "$host:$rdir/tool/" || die "scp to $host failed"
  scp -q "$here" "$host:$rdir/lib/common.sh" || die "scp to $host failed"
  scp -q "$(dirname "$here")/progress.sh" "$host:$rdir/lib/progress.sh" || die "scp to $host failed"
  for a in "${REMOTE_EXTRA[@]+"${REMOTE_EXTRA[@]}"}"; do scp -q "$a" "$host:$rdir/tool/" || die "scp to $host failed"; done
  local t=-t s=sudo; [ "${REMOTE_NOTTY:-0}" = 1 ] && { t=-T; s="sudo -n"; }
  # shellcheck disable=SC2029
  ssh "$t" "$host" "$s bash '$rdir/tool/$(basename "$tool")'$q; rc=\$?; rm -rf '$rdir'; exit \$rc"
}

summary() { printf '\n%s: %d ok, %d warn, %d fail, %d to change\n' "$TOOL" "$c_ok" "$c_warn" "$c_fail" "$c_todo"; }

ploi_managed() { [ -d "$R/home/ploi" ] || [ -d "$R/etc/ploi" ] || [ -f "$R/root/.ploi" ]; }
