# Executor brief — the handwritten part

`tower brief <lane>` prints everything derivable: the lane's tasks, the three
reporting commands, the plan's conventions section, the model roles, and the
two standing rules (never push, never open a PR). Start from that:

    tower brief A > <run-dir>/brief-A.md

Then add, above it, only what tower cannot know — and send the whole file with
`herdr agent prompt <agent> "$(cat <run-dir>/brief-A.md)"`.

## Without tower

If tower is not installed (bootstrap.sh said so), write the derivable part by
hand below the separator: the lane's task ids and the plan path from
`<run-dir>/run.txt` and `lanes.txt`, the model roles from `run.txt`, and the two
standing rules (never push, never open a PR). Then substitute the reporting:

| with tower                              | without                                                        |
|-----------------------------------------|----------------------------------------------------------------|
| `tower task <id> start\|done`            | one commit per task, subject starting with the task id          |
| `tower block <id> "<need>"`             | stop, and state exactly what you need as your reply            |
| `tower note --lane X '<text>'`          | say it as your reply; the orchestrator reads the pane          |
| `tower state --json` (other lane's progress) | `git log <branch> --oneline`                              |

The orchestrator then watches with watch-lanes.sh alone; idle after the final
report is "done".

## Executor kind

panes.txt says which agent runs the lane (`kind claude` or `kind codex`). The
brief is the same for both except the review tail of METHOD and of WHEN YOUR
LAST TASK IS DONE. Both kinds load the same tdd skill (claude from the
mattpocock plugin, codex from ~/.codex/skills/tdd); "load the tdd skill" is the
sentence that works for both.

| claude lane                                                     | codex lane                                                        |
|-----------------------------------------------------------------|-------------------------------------------------------------------|
| spec-compliance review subagent (model sonnet) + code-quality review subagent (model opus); pass the model explicitly | `/review` the task's diff against the task spec; fix what it flags before the next task |
| final whole-implementation review subagent (model opus)         | final `/review` of the whole lane diff                            |
| reviewer roles as tower prints them                             | both reviewer roles are the lane's own model; say so in the brief |

A codex lane briefed with subagent instructions will improvise; match the tail
to the kind.

---

You are {{LANE_NAME}} of a {{N}}-lane run. Working directory: {{WORKTREE}} (branch {{BRANCH}} — already a worktree; do NOT create another one, do NOT cd to any other checkout). {{FRESH_WORKTREE_LINE: "Dependencies are installed." | "First run: <install cmd>."}}

Read first: CONTEXT.md and docs/adr/ if the repo has them, then the spec and the plan named in the brief below.

METHOD: {{e.g. "Before each task load the tdd skill and follow its loop; the seams are the modules in the task's Files list, tested through their exports. One failing test, then the minimal implementation, one slice at a time. When green: run the check gate, commit, then" — claude: "a spec-compliance review subagent (model sonnet) and a code-quality review subagent (model opus); fix what they flag. Pass the model explicitly on every dispatch." — codex: "/review the task's diff against the task spec; fix what it flags before the next task. You are your own reviewer here: both reviewer roles below are you."}}

OTHER LANES: {{e.g. "Lane B (agent <name>, branch <branch>) owns tasks 5, 7-9; skip them entirely — do not implement them, do not touch their files, do not report on their ids."}}

MERGE POINTS: {{lane A: "Before task N run  git merge <lane-b-branch> ; if lane B has not finished task M (tower state --json, or git log <branch> --oneline) wait and re-check every 3 minutes. Resolve conflicts keeping both sides, run the check gate, commit the merge, continue."  lane B: "Task M needs X from lane A's task K: before task M run  git merge <lane-a-branch>  and confirm <file> exists; if not, wait and re-check every 3 minutes — never write a local copy."}}

Watch panes you may read instead of re-running suites: {{from panes.txt: typecheck <id>, tests <id>}} (herdr pane read <id> --source recent-unwrapped --lines 60).

Do not stop between tasks to ask whether to continue. If you cannot proceed: tower block <id> "<exactly what you need>", then stop and wait.

WHEN YOUR LAST TASK IS DONE: {{lane A: "run the check gate from the repo root, then a final whole-implementation review (claude: subagent, model opus; codex: /review of the whole lane diff), fix what it flags, then  tower note --lane A 'ALL DONE - check green'  and report a summary."  lane B: "run the tests and typecheck for your files, then  tower note --lane B 'lane B complete - ready to merge'."}}

Begin now with task {{FIRST_ID}}.

--- (paste the output of `tower brief <lane>` below this line) ---
