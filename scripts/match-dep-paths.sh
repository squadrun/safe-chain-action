#!/usr/bin/env bash
#
# Reads a newline-separated list of changed files on stdin and prints the subset
# matching any of the newline-separated glob patterns in $DEP_PATHS.
#
# Patterns are shell `case` globs, where `*` also crosses `/`. That over-matches
# slightly — `docs/*/package.json` style patterns are broader than they look —
# which is the correct direction to err: a spurious scan costs a few CI minutes,
# a missed scan silently disables the gate for that pull request.
#
# Always exits 0. Emptiness of stdout is the signal, so a crash can never be
# mistaken for "no dependency changes".
#
# Unit-tested by tests/test-dep-path-matcher.sh.
set -uo pipefail

: "${DEP_PATHS:?DEP_PATHS must be set to a newline-separated list of globs}"

while IFS= read -r file; do
  [ -n "$file" ] || continue
  while IFS= read -r pattern; do
    pattern="$(printf '%s' "$pattern" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$pattern" ] || continue
    # shellcheck disable=SC2254  # $pattern is intentionally an unquoted glob.
    case "$file" in
      $pattern)
        printf '%s\n' "$file"
        break
        ;;
    esac
  done <<<"$DEP_PATHS"
done
