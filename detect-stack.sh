#!/usr/bin/env bash
# Detect the JS toolchain of the repo in $PWD so the watch panes are not
# hardcoded to one package manager. Sourced by bootstrap.sh and add-lane.sh.
#
# Resolution order for every value: explicit env var  >  repo override file
# (.herdr-orchestrate in the repo root)  >  detection  >  built-in default.
#
# Exports: PM PM_EXEC PM_RUN TYPECHECK_TASK TYPECHECK_CMD TEST_CMD INSTALL_CMD

# --- repo override file ------------------------------------------------------
# A repo whose real entrypoint is its own CLI (kyrok, nx, rush, make …) just
# sets the commands here instead of relying on detection.
#
#   # .herdr-orchestrate
#   TYPECHECK_CMD="pnpm exec turbo watch check-types --ui=stream"
#   TEST_CMD="kyrok test @repo/database -- --watch"
[ -f .herdr-orchestrate ] && . ./.herdr-orchestrate

# --- package manager ---------------------------------------------------------
if [ -z "${PM:-}" ]; then
  if   [ -f bun.lock ] || [ -f bun.lockb ]; then PM=bun
  elif [ -f pnpm-lock.yaml ];               then PM=pnpm
  elif [ -f yarn.lock ];                    then PM=yarn
  elif [ -f package-lock.json ];            then PM=npm
  else
    # No lockfile: fall back to packageManager in package.json, else npm.
    PM=$(node -p "((require('./package.json').packageManager)||'npm').split('@')[0]" 2>/dev/null || echo npm)
  fi
fi

case "$PM" in
  bun)  PM_EXEC="bunx";      PM_RUN="bun run";  INSTALL_CMD="bun install" ;;
  pnpm) PM_EXEC="pnpm exec"; PM_RUN="pnpm run"; INSTALL_CMD="pnpm install" ;;
  yarn) PM_EXEC="yarn exec"; PM_RUN="yarn run"; INSTALL_CMD="yarn install" ;;
  *)    PM_EXEC="npx";       PM_RUN="npm run";  INSTALL_CMD="npm install" ;;
esac

# --- which script is "typecheck" here? ---------------------------------------
# turbo.json tasks first (that is what `turbo watch` can drive), then root
# package.json scripts. Repos disagree: typecheck / check-types / types.
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

# --- the two watch commands --------------------------------------------------
# `turbo watch --ui=stream` when the repo has turbo (stream, not the TUI: the
# TUI is unreadable to `herdr pane read`). Otherwise a plain watch script.
if [ -z "${TYPECHECK_CMD:-}" ]; then
  if [ -f turbo.json ]; then
    TYPECHECK_CMD="$PM_EXEC turbo watch $TYPECHECK_TASK --ui=stream"
  else
    TYPECHECK_CMD="$PM_RUN $TYPECHECK_TASK"
  fi
fi

# TEST_CMD is built by the caller (it needs TEST_PKG / TEST_FILTER) unless the
# repo override file or the environment already pinned one.
#
# Resolution scans the TARGET PACKAGE's own package.json scripts rather than
# assuming a `test` script exists -- in a monorepo the package you want to watch
# often has none (kyrok's packages/database has only check-types and
# test:integration), and `pnpm run test` there just fails.
herdr_default_test_cmd() {  # $1 = test filter; run from the package directory
  local filter="$1"
  if [ -n "${TEST_CMD:-}" ]; then echo "$TEST_CMD"; return; fi
  PM="$PM" PM_RUN="$PM_RUN" PM_EXEC="$PM_EXEC" FILTER="$filter" node -e '
  // Wrapped in a function: `node -e` has no module scope, so a top-level
  // `return` is a SyntaxError.
  process.stdout.write((() => {
    const fs = require("fs");
    const { PM, PM_RUN, PM_EXEC, FILTER } = process.env;
    const filter = FILTER ? " " + FILTER : "";
    let scripts = {};
    try { scripts = JSON.parse(fs.readFileSync("package.json", "utf8")).scripts || {}; } catch {}

    // A dedicated watch script always wins -- it already knows this package.
    for (const name of ["test:watch", "test:unit:watch"])
      if (scripts[name]) return `${PM_RUN} ${name}${filter}`;

    // Otherwise find a test script and drive its runner in watch mode directly.
    const name = ["test", "test:unit"].find(n => scripts[n]);
    const body = name ? scripts[name] : "";
    if (/\bvitest\b/.test(body))  return `${PM_EXEC} vitest --watch${filter}`;
    if (/\bjest\b/.test(body))    return `${PM_EXEC} jest --watch${filter}`;
    if (/\bbun test\b/.test(body))return `bun test --watch${filter}`;
    if (name)                       return `${PM_RUN} ${name} --${filter ? " --watch" + filter : " --watch"}`;

    // No test script at all: fall back to a runner the package is configured
    // for, detected from its config files.
    const has = re => fs.readdirSync(".").some(f => re.test(f));
    if (has(/^vitest\.(config|workspace)\./)) return `${PM_EXEC} vitest --watch${filter}`;
    if (has(/^jest\.config\./))               return `${PM_EXEC} jest --watch${filter}`;
    if (PM === "bun")                           return `bun test --watch${filter}`;

    // Nothing to watch. The caller turns this into an idle pane with a note
    // rather than a command that exits immediately and looks broken.
    return "";
  })());
  ' 2>/dev/null
}

export PM PM_EXEC PM_RUN TYPECHECK_TASK TYPECHECK_CMD INSTALL_CMD
