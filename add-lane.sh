#!/usr/bin/env bash
# Add a lane: a git worktree with its own executor, placed in the lane grid,
# owning the given task ids.
#
#   [EXECUTOR_KIND=claude|codex] add-lane.sh <run-dir> <B|C|D> <branch> <base-branch> <task-ids>
#
# Four lanes at most. Lane A is started by bootstrap.sh in the main checkout;
# B goes right of A, C under A, D under B:
#
#        │ lane A   │ lane B   │
#        ├──────────┼──────────┤
#        │ lane C   │ lane D   │
#
# The kind is per lane (executor.sh). Worktrees live at
# <repo>/.worktrees/<branch>; .env (gitignored) is copied and the repo package
# manager installs. The worktree shares the repo's common git dir, so `tower`
# inside it finds the run with no flags. Without tower, ownership goes to
# <run-dir>/lanes.txt.
#
# Never run this for real to see what it does; use DRY_RUN=1, which answers
# every herdr and tower call from tests/stub and touches nothing.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/common.sh"
in_herdr; need git python3 node
[ $# -eq 5 ] || die 'usage: add-lane.sh <run-dir> <B|C|D> <branch> <base-branch> <task-ids>'
RUN_DIR="$1"; LANE="$2"; BRANCH="$3"; BASE="$4"; TASKS="$5"
MAP="$RUN_DIR/panes.txt"
[ -f "$MAP" ] || die "no pane map at $MAP: run bootstrap.sh first"
lane_pane() { sed -nE "s/^lane $1: +([^ ]+).*/\1/p" "$MAP"; }

case "$LANE" in
  B) ANCHOR=A; SPLIT=right ;;
  C) ANCHOR=A; SPLIT=down ;;
  D) ANCHOR=B; SPLIT=down ;;
  A) die "lane A is started by bootstrap.sh" ;;
  *) die "lane must be B, C or D (four lanes at most)" ;;
esac
[ -z "$(lane_pane "$LANE")" ] || die "lane $LANE already exists (see $MAP)"
TARGET=$(lane_pane "$ANCHOR")
[ -n "$TARGET" ] || die "lane $LANE goes under lane $ANCHOR, which does not exist yet"

REPO_ROOT="$(repo_root)"
WT="$REPO_ROOT/.worktrees/$BRANCH"
. "$KIT/executor.sh"   # EXECUTOR_KIND, EXECUTOR_MODEL, agent_name, start_agent*
NAME="$(agent_name "-lane-$(echo "$LANE" | tr 'A-Z' 'a-z')")"

# Ownership first: tower refuses an unknown id, so a typo stops here, before a
# worktree exists. Without tower, ownership is a line in <run-dir>/lanes.txt.
if tower_ok; then HAVE_TOWER=1; tower assign "$LANE" "$TASKS"
else HAVE_TOWER=0; echo "$LANE=$TASKS" >> "$RUN_DIR/lanes.txt"; fi

out=$(herdr worktree create --cwd "$REPO_ROOT" --branch "$BRANCH" --base "$BASE" --path "$WT" --label "$NAME" --no-focus)
WT_PANE=$(echo "$out" | jsonq 'd["result"]["root_pane"]["pane_id"]')
PANE=$(herdr pane move "$WT_PANE" --tab "$HERDR_TAB_ID" --split "$SPLIT" --target-pane "$TARGET" --ratio 0.5 --no-focus \
  | jsonq 'd["result"].get("move_result", d["result"])["pane"]["pane_id"]')

[ -f "$WT/.env" ] || cp "$REPO_ROOT/.env" "$WT/.env" 2>/dev/null || true
INSTALL_CMD="$( cd "$REPO_ROOT" && . "$KIT/detect-stack.sh" && echo "$INSTALL_CMD" )"
# Wait for the install by a sentinel of our own, not the package manager's
# wording; the quotes keep the echoed command line from matching.
herdr pane run "$PANE" "cd '$WT' && $INSTALL_CMD; echo HERDR_INSTALL_'DONE'" >/dev/null
herdr pane wait-output "$PANE" --source recent-unwrapped --regex '^HERDR_INSTALL_DONE$' --timeout 300000 >/dev/null \
  || echo "add-lane: install did not finish in 5 min; starting the agent anyway" >&2

start_agent_with_trust_retry "$NAME" "$PANE"

printf 'lane %s:         %s   (agent "%s", kind %s, branch %s, checkout %s, model %s)\n' \
  "$LANE" "$PANE" "$NAME" "$EXECUTOR_KIND" "$BRANCH" "$WT" "$EXECUTOR_MODEL" >> "$MAP"
if [ "$HAVE_TOWER" = 1 ]; then
  echo "lane $LANE ready: agent $NAME in $PANE — next:  tower brief $LANE > $RUN_DIR/brief-$LANE.md, add the judgement (brief-template.md, with merge points in both briefs), then  herdr agent prompt $NAME \"\$(cat $RUN_DIR/brief-$LANE.md)\""
else
  echo "lane $LANE ready: agent $NAME in $PANE — next: write $RUN_DIR/brief-$LANE.md from brief-template.md (\"Without tower\"; tasks $TASKS, merge points in both briefs), then  herdr agent prompt $NAME \"\$(cat $RUN_DIR/brief-$LANE.md)\""
fi
