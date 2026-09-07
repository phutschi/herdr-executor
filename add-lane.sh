#!/usr/bin/env bash
# Add a parallel lane: a git worktree with its own executor, placed in tab 1 to
# the right of the previous lane, owning the given task ids in tower.
#
#   [EXECUTOR_KIND=claude|codex] add-lane.sh <run-dir> <lane-letter> <branch> <base-branch> <task-ids>
#
# The kind is per lane (default claude; EXECUTOR_MODEL overrides the kind's
# default model — see executor.sh), so a codex lane B can run beside a claude lane A.
# Worktrees live at <repo>/.worktrees/<branch>. Copies .env (gitignored) and
# installs with the repo package manager. The worktree shares the repo's
# common git dir, so `tower` inside it finds the same run with no flags. Works
# without tower too: ownership is then recorded in <run-dir>/lanes.txt.
set -euo pipefail
test "${HERDR_ENV:-}" = 1 || { echo "not inside herdr" >&2; exit 1; }

RUN_DIR="$1"; LANE="$2"; BRANCH="$3"; BASE="$4"; TASKS="$5"
KIT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git rev-parse --path-format=absolute --git-common-dir | sed 's#/\.git$##')"
WT="$REPO_ROOT/.worktrees/$BRANCH"
NAME="$(basename "$REPO_ROOT")-lane-$(echo "$LANE" | tr 'A-Z' 'a-z')"
. "$KIT/executor.sh"   # EXECUTOR_KIND, EXECUTOR_MODEL, start_agent*

# Ownership first: tower refuses an unknown id, so a typo stops here, before a
# worktree exists. Without tower, ownership is a line in <run-dir>/lanes.txt.
if command -v tower >/dev/null; then
  HAVE_TOWER=1; tower assign "$LANE" "$TASKS"
else
  HAVE_TOWER=0; echo "$LANE=$TASKS" >> "$RUN_DIR/lanes.txt"
fi

out=$(herdr worktree create --cwd "$REPO_ROOT" --branch "$BRANCH" --base "$BASE" --path "$WT" --label "$NAME" --no-focus)
WT_PANE=$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])')

# Lanes line up left→right in tab 1: the newest splits the previous one. The
# previous lane's pane comes from panes.txt; without it, the newest agent pane in this tab.
PREV=$(sed -nE 's/^(executor|lane [A-Z]): +([^ ]+).*/\2/p' "$RUN_DIR/panes.txt" 2>/dev/null | tail -1 || true)
[ -n "$PREV" ] || PREV=$(herdr pane list | python3 -c 'import json,sys,os; t=os.environ["HERDR_TAB_ID"]; ps=[p for p in json.load(sys.stdin)["result"]["panes"] if p["tab_id"]==t and p.get("agent")]; print(ps[-1]["pane_id"])')
PANE=$(herdr pane move "$WT_PANE" --tab "$HERDR_TAB_ID" --split right --target-pane "$PREV" --ratio 0.5 --no-focus \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; m=r.get("move_result",r); print(m["pane"]["pane_id"])')

[ -f "$WT/.env" ] || cp "$REPO_ROOT/.env" "$WT/.env" 2>/dev/null || true
INSTALL_CMD="$( cd "$REPO_ROOT" && . "$KIT/detect-stack.sh" && echo "$INSTALL_CMD" )"
# Wait for the install by a sentinel of our own, not the package manager's wording
# (bun prints "[1.00ms] done" for a dependency-free package; nothing generic matches
# bun, pnpm, yarn and npm alike). The quotes keep the echoed command line from matching.
herdr pane run "$PANE" "cd '$WT' && $INSTALL_CMD; echo HERDR_INSTALL_'DONE'"
herdr pane wait-output "$PANE" --source recent-unwrapped --regex '^HERDR_INSTALL_DONE$' --timeout 300000 >/dev/null \
  || echo "add-lane: install did not finish in 5 min; starting the agent anyway" >&2

start_agent_with_trust_retry "$NAME" "$PANE"

printf 'lane %s:         %s   (agent "%s", kind %s, branch %s, worktree %s, model %s)\n' "$LANE" "$PANE" "$NAME" "$EXECUTOR_KIND" "$BRANCH" "$WT" "$EXECUTOR_MODEL" >> "$RUN_DIR/panes.txt"
if [ "$HAVE_TOWER" = 1 ]; then
  echo "lane $LANE ready: agent $NAME in $PANE — next:  tower brief $LANE  (+ merge points), then  herdr agent prompt $NAME \"<brief>\""
else
  echo "lane $LANE ready: agent $NAME in $PANE — next: write brief-$LANE.md from brief-template.md (\"Without tower\"; tasks $TASKS, + merge points), then  herdr agent prompt $NAME \"<brief>\""
fi
