---
name: herdr-orchestrate
description: Use when asked to implement a multi-task plan with a separate executor agent inside Herdr ("herdr executor approach", "orchestrate this plan", "run this plan with lanes", "use tower for this"), or when a plan should be executed by one or more agents while this session only watches. Requires HERDR_ENV=1. Not for single-task changes you can make yourself.
---

# Orchestrating a plan with herdr executors

## Overview

You are the orchestrator: you set up the layout, brief each executor, watch, and
close. **You never implement, and you never report on a lane's behalf.** The kit
lives in this directory; every script's header is its manual. Read
`bootstrap.sh`'s header before the first command.

tower (github.com/phutschi/tower) is the task board and record when installed.
Without it the kit still works: bootstrap prints where to get it and the same
layout comes up with the git log in the console pane.

## The run, in order

1. **Prepare.** From the repo checkout on the feature branch, with a plan
   (markdown with task headings, or a TSV like `example-tasks.tsv`). Pick a run
   dir under `~/.local/state/tower/runs/<name>`. For parallel lanes set
   `LANES="A=1-4 B=5,6"` in the environment. Each lane runs on claude unless
   `EXECUTOR_KIND=codex` is set for its bootstrap or add-lane call (default
   models `claude-sonnet-5[1m]` and `gpt-6-astra`; `EXECUTOR_MODEL` overrides).
   A claude lane A and a codex lane B in one run is fine.
2. **Bootstrap.**
   ```
   <kit>/bootstrap.sh <run-dir> "<title>" <branch> <plan.md|tasks.tsv> [test-filter]
   ```
   It splits the panes, starts the lane-A executor, and writes
   `<run-dir>/panes.txt`. Read that file; it is the pane map for the whole run.
3. **Brief lane A.** With tower: `tower brief A > <run-dir>/brief-A.md`, then add
   the judgement from `brief-template.md` above it. Without tower: write it from
   the template's "Without tower" section. Send with
   `herdr agent prompt <executor> "$(cat <run-dir>/brief-A.md)"`.
4. **More lanes.** `add-lane.sh <run-dir> B <branch> <base> <ids>`, then brief B
   the same way, with merge points in both briefs.
5. **Watch, in the background.** `tower wait --timeout 540 --stale 30` for
   task-level attention, and `watch-lanes.sh <run-dir> <agent>...` for the agent
   processes. Both exit when something needs you; re-run them after acting.
   Never poll `tower state` or the panes in a loop.
6. **Act on attention.** blocked → re-brief with what the lane asked for.
   stale → read the pane tail, then re-brief or wait. idle after the final
   report → verify the check gate and commits yourself, then merge lanes.
7. **Close.** `tower close "<how it ended>"` (without tower: note it in
   `<run-dir>/run.txt`). Stop the executors. **Leave the tower pane open**; the
   human reads the record there and quits it with `q`.

## Rules

- Do not implement. A stuck lane gets a better brief, not your edit.
- Only the executor reports its own tasks (`tower task|block|note`).
- `tower note` is your voice on the board: merges, escalations, decisions.
- Never close panes you did not create; never close the tower pane.
- Executors never push and never open a PR. The brief says so; keep it.
- The brief's review tail matches the lane's kind (panes.txt): review subagents
  for claude, self-review with the code-review skill for codex. See
  brief-template.md, "Executor kind".

## Common mistakes

| Mistake | Instead |
|---|---|
| Hand-rolling `herdr pane split` and `herdr agent start` | Run `bootstrap.sh`; the layout and pane map are its job |
| Drip-feeding one task per prompt | One brief per lane with all its tasks; "do not stop between tasks" is in the template |
| Briefing with the plan alone | Brief = template judgement + derived part; method, other lanes, merge points, reporting |
| Sleeping and re-reading panes | The two watches in `run_in_background`; act only when one exits |
| Closing the tower pane during teardown | It stays; it is the record |
| A second run in a repo with an open one | tower refuses; `tower close` the old one first |
| Briefing a codex lane with subagent review instructions | Codex has no subagents; it reviews its own diff with the code-review skill, per task and once for the lane |
