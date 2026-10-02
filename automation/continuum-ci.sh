#!/usr/bin/env bash
set -euo pipefail

bun install --frozen-lockfile
(
  cd packages/opencode
  bun test test/cli/run/coding-bundle.test.ts
)
bun run --cwd packages/opencode script/build.ts --single --coding --skip-embed-web-ui --skip-install

BIN=packages/opencode/dist/opencode-linux-x64/bin/opencode
test -x "$BIN"
"$BIN" --version
HELP="$("$BIN" --help 2>&1)"
grep -q "opencode run" <<<"$HELP"
if grep -Eq '(^|[[:space:]])(web|serve|attach|upgrade|uninstall)([[:space:]]|$)' <<<"$HELP"; then
  echo "::error::Non-coding commands leaked into the optimized CLI"
  exit 1
fi
ls -lh "$BIN"
