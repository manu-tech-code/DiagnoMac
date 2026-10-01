#!/bin/zsh
# Measures a DiagnoMac build the way the PR tables report it: average CPU, energy
# impact and idle wake-ups per second over a window, and the memory footprint at the end.
#   scripts/measure.sh <DiagnoMac.app> <page|menubar> [seconds]
#   scripts/measure.sh build/DerivedData/Build/Products/Release/DiagnoMac.app battery
# A page is an Area raw value (overview, battery, performance, apps…); menubar starts
# without a window, like a login launch. The first 25 seconds (the scan) aren't counted.
set -euo pipefail
APP="${1:?usage: scripts/measure.sh <app> <page|menubar> [seconds]}"
MODE="${2:?page or menubar}"
SECS="${3:-30}"

ROOT="${0:A:h:h}"
COUNTER="$ROOT/build/window-count"
[[ -x "$COUNTER" ]] || swiftc -O "$ROOT/scripts/window-count.swift" -o "$COUNTER"

# A launch sometimes comes up without its window; retry rather than measure a windowless app.
for attempt in 1 2 3; do
  pkill -x DiagnoMac 2>/dev/null || true
  # Wait for the previous copy to finish quitting first.
  for _ in {1..50}; do pgrep -x DiagnoMac >/dev/null || break; sleep 0.2; done
  # Through LaunchServices: a binary run directly isn't registered with its bundle and gets no windows.
  if [[ "$MODE" == menubar ]]; then
    open -n "$APP" --args -menuBarOnly
  else
    open -n "$APP" --args -openPage "$MODE"
  fi
  sleep 5
  PID=$(pgrep -n -x DiagnoMac)
  [[ "$MODE" == menubar || "$("$COUNTER" "$PID")" -gt 0 ]] && break
  echo "no window on attempt $attempt, retrying" >&2
done
sleep 20

SAMPLES=$((SECS / 5 + 1))
top -l "$SAMPLES" -s 5 -pid "$PID" -stats pid,cpu,idlew,power 2>/dev/null \
  | awk -v pid="$PID" -v secs="$SECS" '
      $1 == pid { n++; gsub(/\+|-/, "", $3)
                  if (n == 1) { first = $3; next }        # top'"'"'s first sample has no CPU yet
                  cpu += $2; power += $4; last = $3; m++ }
      END { printf "cpu %.1f%%  energy %.1f  idle-wakeups %.0f/s", cpu / m, power / m, (last - first) / secs }'
echo "  footprint $(footprint -p "$PID" 2>/dev/null | awk '/Footprint:/ {for (i = 1; i <= NF; i++) if ($i == "Footprint:") {print $(i+1), $(i+2); exit}}')"
kill "$PID" 2>/dev/null || true
