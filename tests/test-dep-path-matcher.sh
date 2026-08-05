#!/usr/bin/env bash
#
# Unit tests for scripts/match-dep-paths.sh.
#
# This is the highest-risk logic in the gate: if it wrongly reports "no
# dependency changes", the job early-exits green and the pull request is never
# scanned at all. A false negative here is indistinguishable from a clean pass.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
matcher="${here}/../scripts/match-dep-paths.sh"

DORY_PATHS='package.json
yarn.lock
apps/*/package.json
packages/*/package.json
.yarnrc.yml'

UV_PATHS='uv.lock
pyproject.toml'

pass=0
fail=0

# check <description> <newline-separated files> <newline-separated patterns> <yes|no>
check() {
  local desc="$1" files="$2" patterns="$3" want="$4"
  local got result
  got="$(printf '%s\n' "$files" | DEP_PATHS="$patterns" bash "$matcher")"
  result="no"
  [ -n "$got" ] && result="yes"
  if [ "$result" = "$want" ]; then
    pass=$((pass + 1))
    printf 'PASS  %-50s -> %s\n' "$desc" "$result"
  else
    fail=$((fail + 1))
    printf 'FAIL  %-50s -> got %s, want %s\n' "$desc" "$result" "$want"
  fi
}

echo "--- node / yarn workspaces ---"
check "root yarn.lock changed"           "yarn.lock"                    "$DORY_PATHS" yes
check "root package.json changed"        "package.json"                 "$DORY_PATHS" yes
check "workspace app manifest"           "apps/web/package.json"        "$DORY_PATHS" yes
check "workspace package manifest"       "packages/core/package.json"   "$DORY_PATHS" yes
check "yarn config changed"              ".yarnrc.yml"                  "$DORY_PATHS" yes
check "one lockfile among many files"    $'README.md\nsrc/a.ts\nyarn.lock' "$DORY_PATHS" yes
check "source only"                      "apps/web/src/index.ts"        "$DORY_PATHS" no
check "README only"                      "README.md"                    "$DORY_PATHS" no
check "docs file merely named similarly" "docs/package.md"              "$DORY_PATHS" no
check "no relevant files"                $'README.md\nsrc/a.ts'         "$DORY_PATHS" no

echo "--- uv ---"
check "uv.lock changed"                  "uv.lock"                      "$UV_PATHS" yes
check "pyproject.toml changed"           "pyproject.toml"               "$UV_PATHS" yes
check "python source only"               "apps/core/models.py"          "$UV_PATHS" no

echo "--- robustness ---"
check "empty input"                      ""                             "$DORY_PATHS" no
check "pattern with surrounding spaces"  "yarn.lock"                    $'  yarn.lock  '   yes
check "pattern list with CRLF endings"   "yarn.lock"                    $'yarn.lock\r'     yes
check "blank lines in pattern list"      "yarn.lock"                    $'\n\nyarn.lock\n\n' yes
check "filename containing spaces"       "my dir/file.ts"               "$DORY_PATHS" no

echo
echo "passed=${pass} failed=${fail}"
[ "$fail" -eq 0 ]
