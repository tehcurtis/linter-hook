#!/usr/bin/env bash
#
# lint-hook — a Claude Code PostToolUse hook that lints only the file just edited.
#
# Exit-code contract (see README.md):
#   clean                 -> exit 0, no output
#   lint failures         -> exit 2, terse errors on stderr (fed back to the agent)
#   linter missing/broken -> exit 0, never block the agent on tooling absence
#
# Portability: targets Bash 3.2, the version macOS ships as /bin/bash. That means
# no associative arrays, no `mapfile`/`readarray`, no `${var,,}` case conversion.
#
# `set -e` is deliberately NOT used: linters exiting non-zero is the normal path,
# and this script must stay in control of its own exit code at all times.

set -uo pipefail

LINT_HOOK_VERSION="0.1.0-dev"

main() {
  case "${1-}" in
    --version)
      printf 'lint-hook %s\n' "$LINT_HOOK_VERSION"
      return 0
      ;;
  esac

  # Phase 1 wires up the real payload parsing. Until then the hook is a no-op
  # that drains stdin so the writing end never sees a broken pipe.
  cat >/dev/null 2>&1

  return 0
}

# Only run when executed, not when sourced by the test suite.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
