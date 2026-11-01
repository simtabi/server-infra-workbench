#!/usr/bin/env bash
# examples/_shared/ploi-script.sh - print src/shell/deploy/ploi-deploy.sh with its SETTINGS block replaced by an
# example's ploi-deploy.settings.sh: the text you paste into Ploi (Site -> Deploy script). Offline, no secrets.
#
#   examples/_shared/ploi-script.sh examples/symfony/ploi-deploy.settings.sh > /tmp/deploy.txt
#   examples/_shared/ploi-script.sh --check FILE    also `bash -n` the result and require each setting once
# Why: one maintained deploy script, one small settings file per app. Copying the whole script per app would
# fork it; a fix in ploi-deploy.sh then reaches no app.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/src/shell/deploy/ploi-deploy.sh"
check=0
[ "${1:-}" = --check ] && { check=1; shift; }
settings="${1:-}"
case "$settings" in ""|-h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;; esac
[ -f "$settings" ] || { echo "ploi-script: no $settings" >&2; exit 2; }
grep -q '^# ---- SETTINGS ---' "$SCRIPT" || { echo "ploi-script: no SETTINGS marker in $SCRIPT" >&2; exit 1; }

assemble() { # the script up to the marker, the settings (minus the shellcheck line), the script from the end rule
  awk -v f="$settings" '
    /^# ---- SETTINGS ---/ { print; while ((getline l < f) > 0) if (l !~ /^# shellcheck /) print l; skip = 1; next }
    skip && /^# -{20,}$/ { skip = 0 }
    !skip { print }' "$SCRIPT"
}

if [ "$check" -eq 0 ]; then assemble; exit 0; fi
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
assemble > "$out"
bash -n "$out" || { echo "ploi-script: $settings: the assembled script does not parse" >&2; exit 1; }
bad=0
for k in SITE_DOMAIN PRESET DEPLOY_BRANCH; do
  n="$(grep -cE "^$k=" "$out" || true)"
  [ "$n" -eq 1 ] || { echo "ploi-script: $settings: $k set $n times (want 1)" >&2; bad=1; }
done
# every setting the example uses must be one the script knows
# the variables the settings file sets (sourced in a clean shell: it is plain assignments) vs the script's own
# shellcheck disable=SC2016  # the inner script expands in the clean shell
vars_of() { env -i bash --norc --noprofile -c 'a="$(compgen -v)"; . "$1" > /dev/null; compgen -v | grep -vxF "$a" | grep -vx a' _ "$1"; }
known="$(sed -n '/^# ---- SETTINGS ---/,/^# -\{20,\}$/p' "$SCRIPT" > "$out.s" && vars_of "$out.s")"; rm -f "$out.s"
while IFS= read -r k; do
  printf '%s\n' "$known" | grep -qx "$k" || { echo "ploi-script: $settings: $k is not a ploi-deploy.sh setting" >&2; bad=1; }
done < <(vars_of "$settings")
[ "$bad" -eq 0 ] && echo "ploi-script: $(basename "$(dirname "$settings")"): ok ($(wc -l < "$out" | tr -d ' ') lines)"
exit "$bad"
