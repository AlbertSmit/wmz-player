#!/bin/bash
# skin-sweep.sh — launch a batch of skins and record crashes and script errors.
#
#   ./scripts/skin-sweep.sh [skins-dir] [count]
#   PANEL=plView ./scripts/skin-sweep.sh        # panel to open (default)
#   PANEL= ./scripts/skin-sweep.sh              # no panel at all
#
# The app runs its own click hooks internally; this script never moves the pointer.

set -u

DIR="${1:-$HOME/Downloads/windowsmediaplayerskinscollection}"
COUNT="${2:-25}"
PANEL="${PANEL-plView}"
SETTLE="${SETTLE:-4}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${WMZ_APP:-$ROOT/dist/WMZPlayer.app/Contents/MacOS/WMZPlayer}"

[[ "$COUNT" =~ ^[0-9]+$ ]] || COUNT=25
[[ -x "$APP" ]] || { echo "skin-sweep: no app at $APP" >&2; exit 1; }
[[ -d "$DIR" ]] || { echo "skin-sweep: no skins directory at $DIR" >&2; exit 1; }

TMP="${TMPDIR:-/tmp}"
LOGS="$(mktemp -d "${TMP%/}/skin-sweep.XXXXXX")"
SUMMARY="${TMP%/}/skin-sweep-$(date +%Y%m%d-%H%M%S).txt"
trap 'rm -rf "$LOGS"' EXIT

shopt -s nullglob
SKINS=("$DIR"/*.wmz)
shopt -u nullglob
(( ${#SKINS[@]} )) || { echo "skin-sweep: no .wmz files in $DIR" >&2; exit 1; }
BATCH=("${SKINS[@]:0:COUNT}")
(( ${#BATCH[@]} )) || { echo "skin-sweep: count must be at least 1" >&2; exit 1; }

# Unique script errors, with the timestamp / pid / view prefix stripped.
script_errors() {
  grep -F 'script error' "$1" 2>/dev/null \
    | sed -E -e 's/^.*script error in [^:]+: //' -e 's/^.*script error: //' \
    | awk '!seen[$0]++'
}

printf '%-34.34s %-5s %-6s %s\n' "SKIN" "ALIVE" "ERRORS" "FIRST ERROR" | tee "$SUMMARY"

crashed=0 with_errors=0 clean=0
for skin in "${BATCH[@]}"; do
  name="$(basename "$skin" .wmz)"
  log="$LOGS/$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_').log"

  pkill -x WMZPlayer 2>/dev/null || true
  args=("$skin" --headless)
  [[ -n "$PANEL" ]] && args+=(--panel "$PANEL")
  "$APP" "${args[@]}" >"$log" 2>&1 &
  pid=$!

  sleep "$SETTLE"
  if kill -0 "$pid" 2>/dev/null; then
    alive=yes
    kill "$pid" 2>/dev/null
  else
    alive=no
    crashed=$((crashed + 1))
  fi
  wait "$pid" 2>/dev/null

  errs="$(script_errors "$log")"
  nerr=0 first="—"
  if [[ -n "$errs" ]]; then
    nerr="$(printf '%s\n' "$errs" | wc -l | tr -d ' ')"
    first="$(printf '%s\n' "$errs" | head -n 1 | cut -c1-90)"
    with_errors=$((with_errors + 1))
  fi
  [[ "$alive" == yes && "$nerr" -eq 0 ]] && clean=$((clean + 1))

  printf '%-34.34s %-5s %-6s %s\n' "$name" "$alive" "$nerr" "$first" | tee -a "$SUMMARY"
done

printf '\n%d skins: %d crashed, %d with script errors, %d clean\n' \
  "${#BATCH[@]}" "$crashed" "$with_errors" "$clean" | tee -a "$SUMMARY"

echo "Summary: $SUMMARY"
