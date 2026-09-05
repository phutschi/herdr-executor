#!/usr/bin/env bash
# Recreate the standard herdr orchestration layout for executing a plan, with
# tower (github.com/phutschi/tower) as the record and the console.
#
#   bootstrap.sh <run-dir> "<plan title>" <branch> <plan.md | tasks.tsv> [test-filter]
#
# Run it FROM the main Claude pane (the orchestrator), inside the repo checkout
# on the feature branch, with HERDR_ENV=1. It:
#   1. `tower init` from the plan (or a TSV), into <run-dir> (pass a path under
#      ~/.local/state/tower/runs/ to keep it with tower's own runs), with the
#      role models implementer=$EXECUTOR_MODEL, spec-reviewer=$SPEC_REVIEWER_MODEL
#      (sonnet), quality-reviewer=$QUALITY_REVIEWER_MODEL (opus); every task goes
#      to lane A unless LANES="A=1-4 B=5,6" is set in the environment,
#   2. splits the layout below and starts the lane-A executor (claude, on
#      EXECUTOR_MODEL — default claude-sonnet-5[1m]; never the CLI default),
#   3. opens the tower console in the pane the git log used to occupy
#      (GITLOG=1 keeps a git log pane beside it).
#
#        ┌──────────────────────┬──────────────────────────────┐
#        │ orchestrator (you)   │ executor A  │ lane B …       │
#        ├───────────┬──────────┼──────────────────────────────┤
#        │ typecheck │ tests    │ tower  (≥ 60 columns)        │
#        └───────────┴──────────┴──────────────────────────────┘
#
# The executor brief: `tower brief A` prints the derivable part; you write the
# lane-specific judgement around it (see brief-template.md).
# Watching: run  tower wait --timeout 540 --stale 30  in the background for
# task-level attention, and watch-lanes.sh for process-level state.
# Wrapping up: when the run is over, `tower close "<how it ended>"` and stop the
# executors; the typecheck and tests panes may go, but the TOWER PANE STAYS OPEN.
# It is the record of the run — the closed banner and the transcript are what the
# human reads afterwards. Never `herdr pane close` it; the human quits it with `q`.
set -euo pipefail
test "${HERDR_ENV:-}" = 1 || { echo "not inside herdr" >&2; exit 1; }
command -v tower >/dev/null || { echo "tower is not on PATH (npm i -g @phutschi/tower, or ~/.local/bin/tower → bun run ~/code/tower/src/cli.ts)" >&2; exit 1; }

RUN_DIR="$1"; PLAN="$2"; BRANCH="$3"; SOURCE="$4"; TEST_FILTER="${5:-src}"
KIT="$(cd "$(dirname "$0")" && pwd)"
REPO="$PWD"
EXECUTOR="${EXECUTOR_NAME:-$(basename "$REPO")-executor}"
EXECUTOR_MODEL="${EXECUTOR_MODEL:-claude-sonnet-5[1m]}"
# The role → model map tower records in run.json and prints in every brief.
SPEC_REVIEWER_MODEL="${SPEC_REVIEWER_MODEL:-sonnet}"
QUALITY_REVIEWER_MODEL="${QUALITY_REVIEWER_MODEL:-opus}"
TEST_PKG="${TEST_PKG:-.}"
STALE="${STALE:-30}"

. "$KIT/detect-stack.sh"
TEST_CMD_RESOLVED="$( cd "$REPO/$TEST_PKG" 2>/dev/null || cd "$REPO"; herdr_default_test_cmd "$TEST_FILTER" )"

# --- the run ------------------------------------------------------------------
mkdir -p "$RUN_DIR"
MODELS=(--model "implementer=$EXECUTOR_MODEL" --model "spec-reviewer=$SPEC_REVIEWER_MODEL" --model "quality-reviewer=$QUALITY_REVIEWER_MODEL")
case "$SOURCE" in
  *.md) tower init --plan "$SOURCE" --title "$PLAN" --run "$RUN_DIR" "${MODELS[@]}" ;;
  *)    tower init --tasks "$SOURCE" --title "$PLAN" --run "$RUN_DIR" "${MODELS[@]}" ;;
esac
if [ -n "${LANES:-}" ]; then
  for spec in $LANES; do tower assign "${spec%%=*}" "${spec#*=}"; done
else
  ALL_IDS="$(tower state --json | python3 -c 'import json,sys; print(",".join(t["id"] for t in json.load(sys.stdin)["tasks"]))')"
  tower assign A "$ALL_IDS"
fi

# --- panes -------------------------------------------------------------------
pid() { python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])'; }
EXEC_PANE=$(herdr pane split --current --direction right --cwd "$REPO" --no-focus | pid)
TYPECHECK_PANE=$(herdr pane split --current --direction down --ratio 0.72 --cwd "$REPO" --no-focus | pid)
TESTS_PANE=$(herdr pane split --pane "$TYPECHECK_PANE" --direction right --cwd "$REPO/$TEST_PKG" --no-focus | pid)
TOWER_PANE=$(herdr pane split --pane "$EXEC_PANE" --direction down --ratio 0.62 --cwd "$REPO" --no-focus | pid)

herdr pane run "$TYPECHECK_PANE" "$TYPECHECK_CMD"
herdr pane run "$TESTS_PANE" "$TEST_CMD_RESOLVED"
if [ "${GITLOG:-0}" = 1 ]; then
  GITLOG_PANE=$(herdr pane split --pane "$TOWER_PANE" --direction right --ratio 0.35 --cwd "$REPO" --no-focus | pid)
  herdr pane run "$GITLOG_PANE" 'while true; do clear; date +%H:%M:%S; git log --color=always --oneline --graph --decorate=short --branches="*" -14 | cut -c1-$(( $(tput cols) + 60 )); sleep 5; done'
fi
herdr pane run "$TOWER_PANE" "tower --stale $STALE"

# panes.txt first: add-lane.sh and the brief need it even if the agent start below fails.
cat > "$RUN_DIR/panes.txt" <<TXT
run dir:        $RUN_DIR
orchestrator:   $HERDR_PANE_ID
executor:       $EXEC_PANE   (agent "$EXECUTOR", branch $BRANCH, model $EXECUTOR_MODEL)
toolchain:      $PM (typecheck task: $TYPECHECK_TASK)
typecheck:      $TYPECHECK_PANE   ($TYPECHECK_CMD)
                -> herdr pane read $TYPECHECK_PANE --source recent-unwrapped --lines 60
tests:          $TESTS_PANE   ($TEST_PKG: $TEST_CMD_RESOLVED)
tower:          $TOWER_PANE   (console; reporting: tower task|block|note from the repo root)
                keep this pane open after the run — it is the record; the human closes it with q
TXT

# The agent. A fresh checkout shows claude's trust prompt, which herdr reports
# as "blocked during startup": answer it and try once more.
start_agent() { herdr agent start "$EXECUTOR" --kind claude --pane "$EXEC_PANE" -- --model "$EXECUTOR_MODEL"; }
if ! out=$(start_agent 2>&1); then
  if echo "$out" | grep -q "blocked during startup"; then
    herdr pane send-keys "$EXEC_PANE" Down Enter >/dev/null; sleep 3
    herdr agent get "$EXECUTOR" >/dev/null 2>&1 || start_agent >/dev/null
  else
    echo "$out" >&2; exit 1
  fi
fi

cat "$RUN_DIR/panes.txt"
echo
echo "next:  tower brief A > $RUN_DIR/brief-A.md   → add the lane judgement (brief-template.md), then"
echo "       herdr agent prompt $EXECUTOR \"\$(cat $RUN_DIR/brief-A.md)\""
echo "when done:  tower close \"<how it ended>\"; leave the tower pane $TOWER_PANE open (the human quits it with q)"
