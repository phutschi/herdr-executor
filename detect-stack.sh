#!/usr/bin/env bash
# The repo contract and the JS default. Sourced (after common.sh) with $PWD at
# the checkout. Resolution for every value: environment > .herdr-orchestrate >
# detection > built-in default.
#
# .herdr-orchestrate is plain bash in the repo root (see example.herdr-orchestrate):
#   CHECK_CMD="bun run check"           the check gate; one-shot, must pass before a commit
#   pane checks "bun test --watch"      pane NAME "CMD" [DIR]; DIR relative to the checkout
#   pane dev    "bun run dev" apps/web  only checks and dev are placed
#
# Sets: PM PM_EXEC PM_RUN INSTALL_CMD TYPECHECK_TASK CHECK_CMD
#       PANE_NAMES PANE_CMDS PANE_DIRS   (parallel arrays; pane_index NAME finds one)

PANE_NAMES=(); PANE_CMDS=(); PANE_DIRS=()
pane() {
  case "${1:-}" in checks|dev) ;; *) die ".herdr-orchestrate: unknown pane '${1:-}' (only checks and dev are placed)" ;; esac
  [ -n "${2:-}" ] || die ".herdr-orchestrate: pane $1 needs a command"
  PANE_NAMES[${#PANE_NAMES[@]}]="$1"; PANE_CMDS[${#PANE_CMDS[@]}]="$2"; PANE_DIRS[${#PANE_DIRS[@]}]="${3:-.}"
}
pane_index() {  # prints the index of pane NAME, nothing when absent
  local i=0
  while [ "$i" -lt "${#PANE_NAMES[@]}" ]; do
    [ "${PANE_NAMES[$i]}" = "$1" ] && { echo "$i"; return; }
    i=$((i+1))
  done
}
[ -f .herdr-orchestrate ] && . ./.herdr-orchestrate

# --- package manager ---------------------------------------------------------
if [ -z "${PM:-}" ]; then
  if   [ -f bun.lock ] || [ -f bun.lockb ]; then PM=bun
  elif [ -f pnpm-lock.yaml ];               then PM=pnpm
  elif [ -f yarn.lock ];                    then PM=yarn
  elif [ -f package-lock.json ];            then PM=npm
  else PM=$(node -p "((require('./package.json').packageManager)||'npm').split('@')[0]" 2>/dev/null || echo npm)
  fi
fi
case "$PM" in
  bun)  PM_EXEC="bunx";      PM_RUN="bun run";  INSTALL_CMD="bun install" ;;
  pnpm) PM_EXEC="pnpm exec"; PM_RUN="pnpm run"; INSTALL_CMD="pnpm install" ;;
  yarn) PM_EXEC="yarn exec"; PM_RUN="yarn run"; INSTALL_CMD="yarn install" ;;
  *)    PM_EXEC="npx";       PM_RUN="npm run";  INSTALL_CMD="npm install" ;;
esac

# --- which script is "typecheck" here? ---------------------------------------
if [ -z "${TYPECHECK_TASK:-}" ]; then
  TYPECHECK_TASK=$(node -e '
    const fs = require("fs");
    const strip = s => s.replace(/^\s*\/\/.*$/gm, "");
    const read = f => { try { return JSON.parse(strip(fs.readFileSync(f, "utf8"))); } catch { return null; } };
    const turbo = read("turbo.json");
    const pkg   = read("package.json") || {};
    const names = [
      ...Object.keys((turbo && (turbo.tasks || turbo.pipeline)) || {}),
      ...Object.keys(pkg.scripts || {}),
    ];
    const want = ["typecheck", "check-types", "type-check", "types", "check:types"];
    process.stdout.write(want.find(w => names.includes(w)) || "typecheck");
  ' 2>/dev/null || echo typecheck)
fi

# --- the check gate ----------------------------------------------------------
# Typecheck, plus the root test script when there is one.
if [ -z "${CHECK_CMD:-}" ]; then
  if node -e 'const s=require("./package.json").scripts||{}; process.exit(s.test?0:1)' 2>/dev/null; then
    CHECK_CMD="$PM_RUN $TYPECHECK_TASK && $PM_RUN test"
  else
    CHECK_CMD="$PM_RUN $TYPECHECK_TASK"
  fi
fi

# --- the default checks pane -------------------------------------------------
# The target package's test runner in watch mode. Scans that package's own
# scripts: in a monorepo the package you watch often has no `test` script.
herdr_default_test_cmd() {  # $1 = test filter; run from the package directory
  local filter="$1"
  PM="$PM" PM_RUN="$PM_RUN" PM_EXEC="$PM_EXEC" FILTER="$filter" node -e '
  process.stdout.write((() => {
    const fs = require("fs");
    const { PM, PM_RUN, PM_EXEC, FILTER } = process.env;
    const filter = FILTER ? " " + FILTER : "";
    let scripts = {};
    try { scripts = JSON.parse(fs.readFileSync("package.json", "utf8")).scripts || {}; } catch {}
    for (const name of ["test:watch", "test:unit:watch"])
      if (scripts[name]) return `${PM_RUN} ${name}${filter}`;
    const name = ["test", "test:unit"].find(n => scripts[n]);
    const body = name ? scripts[name] : "";
    if (/\bvitest\b/.test(body))   return `${PM_EXEC} vitest --watch${filter}`;
    if (/\bjest\b/.test(body))     return `${PM_EXEC} jest --watch${filter}`;
    if (/\bbun test\b/.test(body)) return `bun test --watch${filter}`;
    if (name)                        return `${PM_RUN} ${name} --${filter ? " --watch" + filter : " --watch"}`;
    const has = re => fs.readdirSync(".").some(f => re.test(f));
    if (has(/^vitest\.(config|workspace)\./)) return `${PM_EXEC} vitest --watch${filter}`;
    if (has(/^jest\.config\./))               return `${PM_EXEC} jest --watch${filter}`;
    if (PM === "bun")                           return `bun test --watch${filter}`;
    return "";
  })());
  ' 2>/dev/null
}
if [ -z "$(pane_index checks)" ]; then
  TEST_PKG="${TEST_PKG:-.}"
  _cmd="$( cd "$TEST_PKG" 2>/dev/null || cd .; herdr_default_test_cmd "${TEST_FILTER:-}" )"
  [ -n "$_cmd" ] || _cmd="echo 'herdr-orchestrate: no test runner detected; declare  pane checks \"<cmd>\"  in .herdr-orchestrate'"
  pane checks "$_cmd" "$TEST_PKG"
  unset _cmd
fi

export PM PM_EXEC PM_RUN INSTALL_CMD TYPECHECK_TASK CHECK_CMD
