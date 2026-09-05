#!/usr/bin/env bash
# One round of process-level watching, meant to run in the background from the
# orchestrator (run_in_background) and be re-run after each exit.
#
#   watch-lanes.sh <run-dir> <agent-name>...            # env: ROUND_SECONDS (default 540)
#
# Task-level attention (blocked / stale / complete / closed) is tower's job:
# run  tower wait --timeout 540 --stale 30  beside this. This script covers
# what tower cannot see — the agent process itself: a lane whose session went
# idle, done, blocked, or disappeared. Exit codes:
#   0  a lane settled (idle/done/blocked/gone), or the run is complete/closed
#   3  quiet round: everyone still working
# Note: a lane waiting on its own background review subagent reads as "idle";
# check the pane tail this prints before acting.
set -uo pipefail
RUN_DIR="$1"; shift
ROUND=${ROUND_SECONDS:-540}

state_of() { herdr agent get "$1" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["agent"]["agent_status"])' 2>/dev/null || echo gone; }
finished() { tower state --json --run "$RUN_DIR" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["summary"]["complete"] or d["closed"] else 1)' 2>/dev/null; }

started=$(date +%s)
while [ $(( $(date +%s) - started )) -lt "$ROUND" ]; do
  settled=0
  for name in "$@"; do
    case "$(state_of "$name")" in working|unknown) ;; *) settled=1 ;; esac
  done
  [ "$settled" = 1 ] && break
  finished && break
  sleep 15
done

alert=0
for name in "$@"; do
  state=$(state_of "$name")
  case "$state" in blocked|idle|done|gone) alert=1 ;; esac
  printf '%-22s %s\n' "$name" "$state"
  if [ "$state" = blocked ] || [ "$state" = idle ] || [ "$state" = done ]; then
    herdr agent read "$name" --source recent-unwrapped --lines 40 2>/dev/null | grep -v '^\s*$' | tail -12 | sed 's/^/    │ /'
  fi
done
if finished; then echo "tower: run complete or closed"; alert=1; fi
echo "--- tower"; tower state --json --run "$RUN_DIR" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["summary"], "attention:", d["attention"])' 2>/dev/null || true
[ "$alert" = 1 ] && exit 0 || exit 3
