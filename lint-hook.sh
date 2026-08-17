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

# Exit codes, named so the contract is legible at the call sites. EXIT_BLOCK
# arrives with the first thing that can actually fail, in Phase 2.
EXIT_OK=0

# Characters JSON allows between tokens.
LINT_HOOK_WS=$' \t\n\r'

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

# Messages the agent is meant to act on. stderr is what Claude Code feeds back.
notice() {
  printf 'lint-hook: %s\n' "$*" >&2
}

# Tracing for humans debugging the hook; silent unless LINT_HOOK_DEBUG is set.
debug() {
  [ -n "${LINT_HOOK_DEBUG:-}" ] || return 0
  printf 'lint-hook[debug]: %s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# JSON extraction
# ---------------------------------------------------------------------------
#
# `jq` is used when it happens to be installed, but the fallback below is the
# supported path — the whole point of the tool is that it drops into a repo with
# nothing to install.
#
# The fallback is safe for one specific reason: a JSON string value can never
# contain a bare `"`, so any occurrence of the byte sequence `"<key>"` inside
# some *other* field's text is necessarily written `\"<key>\"`. Requiring the
# opening quote to be unescaped is therefore enough to tell a real key from
# arbitrary text that happens to mention one — which matters here, because the
# payload carries the full old/new contents of the edit.

# Turn JSON escape sequences in a string value back into the bytes they denote.
# \uXXXX is left alone: Bash 3.2 has no way to emit an arbitrary code point, and
# a path we fail to decode simply fails the -f test later and is skipped.
json_unescape() {
  local s="$1" out="" head
  while [ -n "$s" ]; do
    head="${s%%\\*}"
    if [ "$head" = "$s" ]; then
      out="$out$s"
      break
    fi
    out="$out$head"
    s="${s#"$head"\\}"
    case "$s" in
      '"'*) out="$out\"" ;;
      \\*) out="$out\\" ;;
      '/'*) out="$out/" ;;
      'b'*) out="$out"$'\b' ;;
      'f'*) out="$out"$'\f' ;;
      'n'*) out="$out"$'\n' ;;
      'r'*) out="$out"$'\r' ;;
      't'*) out="$out"$'\t' ;;
      *)
        # Unknown escape (including \uXXXX): keep it verbatim.
        out="$out\\"
        continue
        ;;
    esac
    s="${s#?}"
  done
  printf '%s' "$out"
}

# Print everything that follows the first unescaped `"<key>"`, or return 1 when
# the key does not occur.
json_after_key() {
  local json="$1" key="$2" before after
  after="$json"
  while :; do
    before="${after%%\""$key"\"*}"
    [ "$before" = "$after" ] && return 1
    after="${after#*\""$key"\"}"
    case "$before" in
      *\\) continue ;;
    esac
    printf '%s' "$after"
    return 0
  done
}

# Print everything that precedes the first unescaped `"<key>"`, or all of <json>
# when the key does not occur.
json_before_key() {
  local json="$1" key="$2" seen="" before after
  after="$json"
  while :; do
    before="${after%%\""$key"\"*}"
    if [ "$before" = "$after" ]; then
      printf '%s' "$json"
      return 0
    fi
    after="${after#*\""$key"\"}"
    case "$before" in
      *\\)
        seen="$seen$before\"$key\""
        continue
        ;;
    esac
    printf '%s' "$seen$before"
    return 0
  done
}

# Read the string value of a key out of a JSON blob, ignoring occurrences that
# are really just text inside some other string.
# Usage: json_string <json> <key>; prints the value, returns 1 if not found.
json_string() {
  local json="$1" key="$2"
  local before after raw seg trailing slashes

  after="$json"
  while :; do
    before="${after%%\""$key"\"*}"
    # No (further) occurrence of the key.
    [ "$before" = "$after" ] && return 1
    after="${after#*\""$key"\"}"
    # A backslash immediately before the opening quote means we matched text
    # inside some other string value, not a key. Keep looking.
    case "$before" in
      *\\) continue ;;
    esac

    while :; do
      case "$after" in
        [$LINT_HOOK_WS]*) after="${after#?}" ;;
        *) break ;;
      esac
    done
    case "$after" in
      :*) after="${after#:}" ;;
      *) continue ;;
    esac
    while :; do
      case "$after" in
        [$LINT_HOOK_WS]*) after="${after#?}" ;;
        *) break ;;
      esac
    done
    # A non-string value (null, number, object) is not our business.
    case "$after" in
      \"*) after="${after#\"}" ;;
      *) continue ;;
    esac
    break
  done

  # Accumulate until an unescaped closing quote. A quote is escaped only when
  # preceded by an odd number of backslashes.
  raw=""
  while :; do
    seg="${after%%\"*}"
    [ "$seg" = "$after" ] && return 1 # unterminated string; malformed payload
    raw="$raw$seg"
    after="${after#*\"}"
    trailing="$seg"
    slashes=0
    while [ "${trailing%\\}" != "$trailing" ]; do
      trailing="${trailing%\\}"
      slashes=$((slashes + 1))
    done
    [ $((slashes % 2)) -eq 0 ] && break
    raw="$raw\""
  done

  json_unescape "$raw"
}

# Pull tool_input.file_path out of the PostToolUse payload.
#
# The Bash path narrows to tool_input before searching, so that a file_path
# echoed back under tool_response can neither shadow the real one nor stand in
# for it when the tool that ran had no file_path of its own. Bounding the object
# exactly would mean a brace-matching scan, which in Bash is quadratic in the
# size of the edit — so the window is cut at the tool_response key instead,
# relying on Claude Code emitting tool_input first.
extract_file_path() {
  local payload="$1" scope value status

  if command -v jq >/dev/null 2>&1; then
    value="$(
      jq -r '.tool_input.file_path // empty' 2>/dev/null <<EOF
$payload
EOF
    )"
    status=$?
    # Only fall through when jq itself failed (malformed payload, broken
    # binary). A clean exit with no output is an authoritative "not present".
    if [ "$status" -eq 0 ]; then
      printf '%s' "$value"
      return 0
    fi
  fi

  scope="$(json_after_key "$payload" "tool_input")" || scope="$payload"
  scope="$(json_before_key "$scope" "tool_response")"
  json_string "$scope" "file_path"
}

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------

# The directory the hook should treat as the project root.
project_dir() {
  local payload="$1" cwd

  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    printf '%s' "$CLAUDE_PROJECT_DIR"
    return 0
  fi

  cwd="$(json_string "$payload" "cwd")"
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    printf '%s' "$cwd"
    return 0
  fi

  printf '%s' "$PWD"
}

# Make a possibly-relative path absolute against the project root and collapse
# it to a physical path. No `realpath`/`readlink -f`: neither is portable to a
# stock macOS.
resolve_path() {
  local path="$1" root="$2" dir base

  case "$path" in
    /*) ;;
    *) path="$root/$path" ;;
  esac

  dir="$(dirname -- "$path")"
  base="$(basename -- "$path")"
  [ -d "$dir" ] || return 1
  printf '%s/%s' "$(cd -- "$dir" && pwd -P)" "$base"
}

# ---------------------------------------------------------------------------
# Skip rules
# ---------------------------------------------------------------------------

# Empty files count as text; `grep -I` reports "no match" for them either way.
is_text_file() {
  [ -s "$1" ] || return 0
  LC_ALL=C grep -Iq . -- "$1" 2>/dev/null
}

is_git_ignored() {
  local file="$1" dir
  command -v git >/dev/null 2>&1 || return 1
  dir="$(dirname -- "$file")"
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$dir" check-ignore -q -- "$file" 2>/dev/null
}

# Return 0 when the file should not be linted, with a debug line saying why.
should_skip() {
  local file="$1"

  if [ ! -e "$file" ]; then
    debug "skip: does not exist ($file)"
    return 0
  fi
  if [ ! -f "$file" ]; then
    debug "skip: not a regular file ($file)"
    return 0
  fi
  if ! is_text_file "$file"; then
    debug "skip: binary ($file)"
    return 0
  fi
  if is_git_ignored "$file"; then
    debug "skip: git-ignored ($file)"
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
  local payload file root resolved

  case "${1-}" in
    --version)
      printf 'lint-hook %s\n' "$LINT_HOOK_VERSION"
      return "$EXIT_OK"
      ;;
  esac

  # Invoked by hand with no piped payload: there is nothing to do, and blocking
  # on a terminal read would hang the caller.
  if [ -t 0 ]; then
    debug "no payload on stdin"
    return "$EXIT_OK"
  fi

  payload="$(cat)"
  if [ -z "$payload" ]; then
    debug "empty payload"
    return "$EXIT_OK"
  fi

  file="$(extract_file_path "$payload")"
  if [ -z "$file" ]; then
    debug "no tool_input.file_path in payload"
    return "$EXIT_OK"
  fi

  root="$(project_dir "$payload")"
  resolved="$(resolve_path "$file" "$root")"
  if [ -z "$resolved" ]; then
    debug "could not resolve path ($file) against root ($root)"
    return "$EXIT_OK"
  fi

  should_skip "$resolved" && return "$EXIT_OK"

  debug "lintable: $resolved (root: $root)"

  # Phase 2 hangs linter detection off this point. Until then a lintable file is
  # simply reported clean.
  return "$EXIT_OK"
}

# Only run when executed, not when sourced by the test suite.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
