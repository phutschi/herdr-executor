#!/usr/bin/env bash
# Recreate the standard herdr orchestration layout for executing a plan, with
# tower (github.com/phutschi/tower) as the record and the console when it is
# installed. Without tower the same layout comes up: the plan is copied into the
# run dir, lane ownership goes to <run-dir>/lanes.txt, the git log takes the
# console pane, and lanes report through commits and their pane instead of
# `tower task|block|note` (see brief-template.md, "Without tower").
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
#   2. splits the layout below and starts the lane-A executor: EXECUTOR_KIND
#      (claude, default, or codex) on EXECUTOR_MODEL (claude-sonnet-5[1m] or
#      gpt-6-astra by default; never the CLI default) — see executor.sh. Lanes
#      may differ: EXECUTOR_KIND=codex add-lane.sh … B … next to a claude lane A.
#      The agent is named <repo>-executor after the main checkout's directory,
#      normalised and truncated to herdr's 32-character limit (EXECUTOR_NAME
#      overrides; lanes are <repo>-lane-<x>, see agent_name in executor.sh),
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
# Without tower the git log pane plays that part: leave it open too.
set -euo pipefail
test "${HERDR_ENV:-}" = 1 || { echo "not inside herdr" >&2; exit 1; }
HAVE_TOWER=1
if ! command -v tower >/dev/null; then
  HAVE_TOWER=0
  cat >&2 <<'MSG'
info: tower is not on PATH — running without the console. You get the same panes,
      but no live task board, no `tower wait`, and lanes report through commits
      and their pane instead of `tower task|block|note`.
      To add it: github.com/phutschi/tower (binaries on the releases page;
      npm i -g @phutschi/tower once published; or ~/.local/bin/tower →
      bun run ~/code/tower/src/cli.ts from a checkout).
MSG
fi

RUN_DIR="$1"; PLAN="$2"; BRANCH="$3"; SOURCE="$4"; TEST_FILTER="${5:-src}"
KIT="$(cd "$(dirname "$0")" && pwd)"
REPO="$PWD"
. "$KIT/executor.sh"   # EXECUTOR_KIND, EXECUTOR_MODEL, agent_name, start_agent*
EXECUTOR="${EXECUTOR_NAME:-$(agent_name -executor)}"
# The role → model map tower records in run.json and prints in every brief.
SPEC_REVIEWER_MODEL="${SPEC_REVIEWER_MODEL:-sonnet}"
QUALITY_REVIEWER_MODEL="${QUALITY_REVIEWER_MODEL:-opus}"
TEST_PKG="${TEST_PKG:-.}"
STALE="${STALE:-30}"

. "$KIT/detect-stack.sh"
TEST_CMD_RESOLVED="$( cd "$REPO/$TEST_PKG" 2>/dev/null || cd "$REPO"; herdr_default_test_cmd "$TEST_FILTER" )"

# --- the run ------------------------------------------------------------------
mkdir -p "$RUN_DIR"
if [ "$HAVE_TOWER" = 1 ]; then
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
else
  # The run dir is the record instead: the plan as given, the models, and the
  # lane ownership add-lane.sh appends to.
  case "$SOURCE" in *.md) cp "$SOURCE" "$RUN_DIR/plan.md" ;; *) cp "$SOURCE" "$RUN_DIR/tasks.tsv" ;; esac
  cat > "$RUN_DIR/run.txt" <<TXT
title:            $PLAN
repo:             $REPO
branch:           $BRANCH
plan:             $RUN_DIR/$(basename "$SOURCE" | sed 's/.*\.md$/plan.md/; s/.*\.tsv$/tasks.tsv/')
implementer:      $EXECUTOR_MODEL ($EXECUTOR_KIND)
spec-reviewer:    $SPEC_REVIEWER_MODEL
quality-reviewer: $QUALITY_REVIEWER_MODEL
TXT
  if [ -n "${LANES:-}" ]; then printf '%s\n' $LANES > "$RUN_DIR/lanes.txt"; else echo "A=all" > "$RUN_DIR/lanes.txt"; fi
fi

# --- panes -------------------------------------------------------------------
pid() { python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])'; }
EXEC_PANE=$(herdr pane split --current --direction right --cwd "$REPO" --no-focus | pid)
TYPECHECK_PANE=$(herdr pane split --current --direction down --ratio 0.72 --cwd "$REPO" --no-focus | pid)
TESTS_PANE=$(herdr pane split --pane "$TYPECHECK_PANE" --direction right --cwd "$REPO/$TEST_PKG" --no-focus | pid)
TOWER_PANE=$(herdr pane split --pane "$EXEC_PANE" --direction down --ratio 0.62 --cwd "$REPO" --no-focus | pid)

herdr pane run "$TYPECHECK_PANE" "$TYPECHECK_CMD"
herdr pane run "$TESTS_PANE" "$TEST_CMD_RESOLVED"
GITLOG_CMD='while true; do clear; date +%H:%M:%S; git log --color=always --oneline --graph --decorate=short --branches="*" -14 | cut -c1-$(( $(tput cols) + 60 )); sleep 5; done'
if [ "$HAVE_TOWER" = 1 ]; then
  if [ "${GITLOG:-0}" = 1 ]; then
    GITLOG_PANE=$(herdr pane split --pane "$TOWER_PANE" --direction right --ratio 0.35 --cwd "$REPO" --no-focus | pid)
    herdr pane run "$GITLOG_PANE" "$GITLOG_CMD"
  fi
  herdr pane run "$TOWER_PANE" "tower --stale $STALE"
else
  herdr pane run "$TOWER_PANE" "$GITLOG_CMD"   # the console pane shows the git log instead
fi

# panes.txt first: add-lane.sh and the brief need it even if the agent start below fails.
cat > "$RUN_DIR/panes.txt" <<TXT
run dir:        $RUN_DIR
orchestrator:   $HERDR_PANE_ID
executor:       $EXEC_PANE   (agent "$EXECUTOR", kind $EXECUTOR_KIND, branch $BRANCH, model $EXECUTOR_MODEL)
toolchain:      $PM (typecheck task: $TYPECHECK_TASK)
typecheck:      $TYPECHECK_PANE   ($TYPECHECK_CMD)
                -> herdr pane read $TYPECHECK_PANE --source recent-unwrapped --lines 60
tests:          $TESTS_PANE   ($TEST_PKG: $TEST_CMD_RESOLVED)
$( if [ "$HAVE_TOWER" = 1 ]; then cat <<T2
tower:          $TOWER_PANE   (console; reporting: tower task|block|note from the repo root)
                keep this pane open after the run — it is the record; the human closes it with q
T2
else cat <<T2
git log:        $TOWER_PANE   (no tower installed; lanes report through commits and their pane)
                keep this pane open after the run — it is the record; the human closes it
run record:     $RUN_DIR/run.txt, lanes.txt, $(basename "$SOURCE" | sed 's/.*\.md$/plan.md/; s/.*\.tsv$/tasks.tsv/')
T2
fi )
TXT

start_agent_with_trust_retry "$EXECUTOR" "$EXEC_PANE"

cat "$RUN_DIR/panes.txt"
echo
if [ "$HAVE_TOWER" = 1 ]; then
  echo "next:  tower brief A > $RUN_DIR/brief-A.md   → add the lane judgement (brief-template.md), then"
  echo "       herdr agent prompt $EXECUTOR \"\$(cat $RUN_DIR/brief-A.md)\""
  echo "when done:  tower close \"<how it ended>\"; leave the tower pane $TOWER_PANE open (the human quits it with q)"
else
  echo "next:  write $RUN_DIR/brief-A.md from brief-template.md (section \"Without tower\": lane A owns all tasks, plan at $RUN_DIR), then"
  echo "       herdr agent prompt $EXECUTOR \"\$(cat $RUN_DIR/brief-A.md)\""
  echo "when done:  note how it ended in $RUN_DIR/run.txt; leave the git log pane $TOWER_PANE open"
fi
