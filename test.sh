#!/usr/bin/env bash
# The kit's tests. They need neither herdr nor tower: DRY_RUN=1 puts tests/stub
# first on PATH, so every herdr and tower call is logged and answered by a stub.
#
#   ./test.sh            all sections
#   ./test.sh bootstrap  one section (a word from the "# ---" headings below)
set -u
KIT="$(cd "$(dirname "$0")" && pwd)"; export KIT
ONLY="${1:-}"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; shift; printf '     %s\n' "$@"; }
assert_eq()      { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected: $3" "got:      $2"; }
assert_match()   { printf '%s\n' "$2" | grep -qE -- "$3" && ok "$1" || bad "$1" "no match for /$3/ in:" "$2"; }
assert_nomatch() { printf '%s\n' "$2" | grep -qE -- "$3" && bad "$1" "unexpected match for /$3/ in:" "$2" || ok "$1"; }
section() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
export DRY_RUN=1 HERDR_STUB_LOG="$TMP/log" HERDR_STUB_COUNTER="$TMP/counter" HERDR_STUB_STATES_DIR="$TMP/states"
mkdir -p "$HERDR_STUB_STATES_DIR"

# Guard: every section below runs herdr/tower calls through common.sh's
# DRY_RUN PATH shim. If a stub is missing, not executable, or shadowed by
# something earlier on PATH, refuse outright rather than risk a script under
# test touching the real herdr or tower (this happened once: HERDR_ENV=1 is
# inherited from the orchestrating pane, so `in_herdr` alone does not stop a
# script run outside test.sh and outside DRY_RUN=1 from driving real panes).
_herdr_which=$(bash -c ". \"$KIT/common.sh\"; command -v herdr" 2>/dev/null || true)
_tower_which=$(bash -c ". \"$KIT/common.sh\"; command -v tower" 2>/dev/null || true)
[ "$_herdr_which" = "$KIT/tests/stub/herdr" ] || { echo "test.sh: herdr resolves to '$_herdr_which', not the stub ($KIT/tests/stub/herdr) — refusing to run" >&2; exit 1; }
[ "$_tower_which" = "$KIT/tests/stub/tower" ] || { echo "test.sh: tower resolves to '$_tower_which', not the stub ($KIT/tests/stub/tower) — refusing to run" >&2; exit 1; }
unset _herdr_which _tower_which
reset_stub() { : > "$HERDR_STUB_LOG"; rm -f "$HERDR_STUB_COUNTER"; }
# A git repo built from tests/fixtures/<name> (or empty). Prints its path.
fixture_repo() {
  local d="$TMP/repos/$1"
  mkdir -p "$d"
  [ -d "$KIT/tests/fixtures/$1" ] && cp -R "$KIT/tests/fixtures/$1/." "$d/"
  git -C "$d" init -q && git -C "$d" commit -q --allow-empty -m init
  echo "$d"
}
in_kit() { bash -c ". \"\$KIT/common.sh\"; $1" 2>&1; }

# --- common ------------------------------------------------------------------
if section common; then
  assert_eq "tower_ok: stub tower 0.2.0 is 0"     "$(in_kit 'tower_ok; echo $?')" 0
  assert_eq "tower_ok: old tower is 2"           "$(TOWER_STUB=old in_kit 'tower_ok; echo $?')" 2
  assert_eq "tower_ok: absent tower is 1"        "$(TOWER_STUB=absent in_kit 'tower_ok; echo $?')" 1
  assert_match "need names the missing tool"     "$(in_kit 'need git nosuchtool')" "missing dependency: nosuchtool"
  assert_match "in_herdr passes under DRY_RUN"   "$(in_kit 'in_herdr && echo inside')" "^inside$"
  assert_match "DRY_RUN puts the stubs on PATH"  "$(in_kit 'command -v herdr')" "tests/stub/herdr$"
  reset_stub
  assert_eq "pane_id reads herdr's split answer" "$(in_kit 'herdr pane split --current | pane_id')" pane-1
  reset_stub
  assert_match "the stub logs argv"              "$(in_kit 'herdr pane run p1 "echo hi" >/dev/null; cat "$HERDR_STUB_LOG"')" '^herdr pane run p1 echo hi$'
  r=$(fixture_repo none)
  assert_eq "repo_root from a checkout"          "$(cd "$r" && in_kit 'repo_root')" "$r"
fi

# --- executor ----------------------------------------------------------------
if section executor; then
  name_in() { (cd "$1" && EXECUTOR_KIND=claude bash -c ". \"\$KIT/common.sh\"; . \"\$KIT/executor.sh\"; agent_name \"$2\"" 2>&1); }
  r=$(fixture_repo none)
  assert_eq "agent_name: <repo>-lane-a"            "$(name_in "$r" -lane-a)" "none-lane-a"
  wt="$r/.worktrees/some-branch"; mkdir -p "$wt"; git -C "$r" worktree add -q "$wt" -b some-branch
  assert_eq "agent_name: a worktree names the main checkout" "$(name_in "$wt" -lane-b)" "none-lane-b"
  long="$TMP/repos/My.Very_Long-Repository Name With Spaces"; mkdir -p "$long"; git -C "$long" init -q
  n=$(name_in "$long" -lane-a)
  assert_eq "agent_name: 32 characters at most"    "${#n}" 32
  assert_match "agent_name: lowercase, safe characters, suffix intact" "$n" '^[a-z][a-z0-9_-]*-lane-a$'
  digits="$TMP/repos/123-Repo"; mkdir -p "$digits"; git -C "$digits" init -q
  assert_eq "agent_name: starts with a letter"     "$(name_in "$digits" -lane-a)" "repo-lane-a"
fi

# --- detect ------------------------------------------------------------------
if section detect; then
  detect_in() { (cd "$1" && bash -c ". \"\$KIT/common.sh\"; . \"\$KIT/detect-stack.sh\"; $2" 2>&1); }
  r=$(fixture_repo bun-vitest)
  assert_eq "detect: bun from bun.lock"              "$(detect_in "$r" 'echo $PM')" bun
  assert_eq "detect: check gate = typecheck && test" "$(detect_in "$r" 'echo "$CHECK_CMD"')" "bun run typecheck && bun run test"
  assert_eq "detect: default checks pane is the runner in watch mode" "$(detect_in "$r" 'echo "${PANE_NAMES[0]} ${PANE_CMDS[0]} ${PANE_DIRS[0]}"')" "checks bunx vitest --watch ."
  assert_eq "detect: no dev pane by default"        "$(detect_in "$r" 'echo ${#PANE_NAMES[@]}')" 1
  assert_eq "detect: CHECK_CMD from the environment wins" "$(CHECK_CMD='make it' detect_in "$r" 'echo "$CHECK_CMD"')" "make it"
  r=$(fixture_repo pnpm-notest)
  assert_eq "detect: check-types, no test script"   "$(detect_in "$r" 'echo "$CHECK_CMD"')" "pnpm run check-types"
  assert_match "detect: no runner gives a note, not a broken pane" "$(detect_in "$r" 'echo "${PANE_CMDS[0]}"')" "no test runner detected"
  r=$(fixture_repo contract)
  assert_eq "contract: CHECK_CMD"                   "$(detect_in "$r" 'echo "$CHECK_CMD"')" "make check"
  assert_eq "contract: panes in order with dirs"    "$(detect_in "$r" 'echo "${PANE_NAMES[*]}|${PANE_CMDS[1]}|${PANE_DIRS[1]}"')" "checks dev|make dev|web"
  r=$(fixture_repo contract-bad)
  assert_match "contract: unknown pane name is refused" "$(detect_in "$r" 'echo reached')" "unknown pane 'logs'"
  assert_nomatch "contract: refusal stops the script" "$(detect_in "$r" 'echo reached')" "^reached$"
fi

# --- bootstrap ---------------------------------------------------------------
if section bootstrap; then
  boot() { (cd "$1" && shift && "$KIT/bootstrap.sh" "$@" 2>&1); }
  r=$(fixture_repo bun-vitest); RUN="$TMP/run-empty"; reset_stub
  out=$(boot "$r" "$RUN" "Empty run" main)
  log=$(cat "$HERDR_STUB_LOG")
  assert_match "empty: tower init without a source"     "$log" '^tower init --title Empty run --run '"$RUN"' --model implementer=claude-sonnet-5\[1m\] --model spec-reviewer=sonnet --model quality-reviewer=opus$'
  assert_nomatch "empty: no lane assignment"            "$log" '^tower assign'
  assert_match "layout: bottom row first"               "$log" '^herdr pane split --current --direction down --ratio 0.7 '
  assert_match "layout: lane A right of the orchestrator" "$log" '^herdr pane split --current --direction right --ratio 0.3 '
  assert_match "layout: console right of checks"        "$log" '^herdr pane split --pane pane-1 --direction right --ratio 0.5 '
  assert_match "layout: checks pane runs the runner in the checkout" "$log" "^herdr pane run pane-1 cd '$r/.' && bunx vitest --watch$"
  assert_match "layout: console runs tower"             "$log" '^herdr pane run pane-3 tower --stale 30$'
  assert_match "lane A: agent named and started"        "$log" '^herdr agent start bun-vitest-lane-a --kind claude --pane pane-2 -- --model claude-sonnet-5\[1m\]$'
  map=$(cat "$RUN/panes.txt")
  assert_match "pane map: lane A line"                  "$map" '^lane A: +pane-2 +\(agent "bun-vitest-lane-a", kind claude, branch main, checkout '"$r"', model '
  assert_match "pane map: checks line"                  "$map" '^checks: +pane-1 '
  assert_match "pane map: console line"                 "$map" '^console: +pane-3 '
  assert_match "pane map: check gate"                   "$map" '^check gate: +bun run typecheck && bun run test$'
  assert_nomatch "pane map: no dev line by default"     "$map" '^dev:'
  assert_match "output: the pane map is printed"        "$out" '^lane A: '
  assert_match "output: next step for the empty opening" "$out" 'tower add'

  RUN="$TMP/run-planned"; reset_stub
  out=$(boot "$r" "$RUN" "Planned" main "$KIT/example-tasks.tsv")
  log=$(cat "$HERDR_STUB_LOG")
  assert_match "planned: tower init --tasks"            "$log" '^tower init --tasks '"$KIT"'/example-tasks.tsv --title Planned '
  assert_match "planned: every task to lane A"          "$log" '^tower assign A 1,2,3$'
  RUN="$TMP/run-lanes"; reset_stub
  out=$(LANES="A=1 B=2,3" boot "$r" "$RUN" "Lanes" main "$KIT/example-tasks.tsv")
  assert_match "planned: LANES assigns each lane"       "$(cat "$HERDR_STUB_LOG")" '^tower assign B 2,3$'
  out=$(LANES="A=1" boot "$r" "$TMP/run-x" "X" main)
  assert_match "empty: LANES without a source is refused" "$out" 'LANES needs a plan or task file'
  out=$(boot "$r" "$TMP/run-y" "Y" main /nonexistent.md)
  assert_match "a missing source is refused"            "$out" 'no such plan or task file'

  RUN="$TMP/run-notower"; reset_stub
  out=$(TOWER_STUB=absent boot "$r" "$RUN" "No tower" main)
  assert_match "no tower: info with the pointer"        "$out" 'tower is not installed'
  assert_eq "no tower: empty tasks.tsv with the header" "$(cat "$RUN/tasks.tsv")" "$(printf '# id\ttitle\tarea\tlane')"
  assert_eq "no tower: lanes.txt exists and is empty"   "$(cat "$RUN/lanes.txt" | wc -l | tr -d ' ')" 0
  assert_match "no tower: run.txt records the title"    "$(cat "$RUN/run.txt")" '^title: +No tower$'
  assert_match "no tower: console shows the git log"    "$(cat "$HERDR_STUB_LOG")" '^herdr pane run pane-3 while true; do clear; .*git log'
  assert_match "no tower: pane map says so"             "$(cat "$RUN/panes.txt")" '^console: +pane-3 +\(git log'
  out=$(TOWER_STUB=absent boot "$r" "$TMP/run-nt2" "NT2" main "$KIT/example-tasks.tsv")
  assert_eq "no tower, planned: lane A owns all"        "$(cat "$TMP/run-nt2/lanes.txt")" "A=all"
  out=$(TOWER_STUB=old boot "$r" "$TMP/run-old" "Old" main)
  assert_match "old tower is refused"                   "$out" 'older than 0.2.0'
  [ -d "$TMP/run-old" ] && bad "old tower: nothing created" || ok "old tower: nothing created"

  r=$(fixture_repo contract); RUN="$TMP/run-dev"; reset_stub
  out=$(boot "$r" "$RUN" "Dev" main)
  log=$(cat "$HERDR_STUB_LOG")
  assert_match "dev: bottom row in thirds, checks after dev" "$log" '^herdr pane split --pane pane-1 --direction right --ratio 0.34 '
  assert_match "dev: console after checks"              "$log" '^herdr pane split --pane pane-3 --direction right --ratio 0.5 '
  assert_match "dev: dev pane runs in its dir"          "$log" "^herdr pane run pane-1 cd '$r/web' && make dev$"
  assert_match "dev: checks pane runs make watch"       "$log" "^herdr pane run pane-3 cd '$r/.' && make watch$"
  assert_match "dev: pane map has dev, checks, console" "$(cat "$RUN/panes.txt")" '^dev: +pane-1 '
  assert_match "dev: console is pane-4"                 "$(cat "$RUN/panes.txt")" '^console: +pane-4 '
fi

echo; echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
