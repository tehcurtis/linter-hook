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

# Exit codes, named so the contract is legible at the call sites.
EXIT_OK=0
EXIT_BLOCK=2

# Characters JSON allows between tokens.
LINT_HOOK_WS=$' \t\n\r'

# Field separator for the linter table.
LINT_HOOK_TAB=$'\t'

# The project root: where linters run from, and the fallback ceiling for
# config-file lookups when the file is not inside a git repo.
LINT_HOOK_ROOT=""

# Where the config walk stops, resolved once per run by main. Every find_up in
# a run asks about the same directory, and working it out costs a git fork.
LINT_HOOK_CEILING=""

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

# The one scan for an unescaped `"<key>"`, which all three readers below share.
# On success sets JSON_KEY_BEFORE to the text in front of the key and
# JSON_KEY_AFTER to the text behind it and returns 0; returns 1 when the key
# does not occur. Escaped occurrences are folded back into JSON_KEY_BEFORE
# rather than dropped, so a caller reading what precedes the key sees all of it.
json_find_key() {
  local json="$1" key="$2" seen="" before after
  JSON_KEY_BEFORE=""
  JSON_KEY_AFTER=""
  after="$json"
  while :; do
    before="${after%%\""$key"\"*}"
    [ "$before" = "$after" ] && return 1
    after="${after#*\""$key"\"}"
    # A backslash immediately before the opening quote means we matched text
    # inside some other string value, not a key. Keep looking.
    case "$before" in
      *\\)
        seen="$seen$before\"$key\""
        continue
        ;;
    esac
    JSON_KEY_BEFORE="$seen$before"
    JSON_KEY_AFTER="$after"
    return 0
  done
}

# Print everything that follows the first unescaped `"<key>"`, or return 1 when
# the key does not occur.
json_after_key() {
  json_find_key "$1" "$2" || return 1
  printf '%s' "$JSON_KEY_AFTER"
}

# Print everything that precedes the first unescaped `"<key>"`, or all of <json>
# when the key does not occur.
json_before_key() {
  if json_find_key "$1" "$2"; then
    printf '%s' "$JSON_KEY_BEFORE"
  else
    printf '%s' "$1"
  fi
}

# Read the string value of a key out of a JSON blob, ignoring occurrences that
# are really just text inside some other string.
# Usage: json_string <json> <key>; prints the value, returns 1 if not found.
json_string() {
  local json="$1" key="$2"
  local after raw seg trailing slashes

  after="$json"
  while :; do
    # A `continue` below resumes the search from just past this hit, so a key
    # whose value is not a string does not end the search.
    json_find_key "$after" "$key" || return 1
    after="$JSON_KEY_AFTER"

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

# The directory the hook should treat as the project root, as a physical path.
#
# Canonicalising matters: the edited file is resolved physically, so a root that
# still contains a symlink would share no prefix with it and every diagnostic
# would come out with an absolute path. On macOS that is the common case, not
# the exotic one — /tmp is a symlink to /private/tmp.
project_dir() {
  local payload="$1" cwd

  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    (cd -- "$CLAUDE_PROJECT_DIR" && pwd -P)
    return 0
  fi

  cwd="$(json_string "$payload" "cwd")"
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    (cd -- "$cwd" && pwd -P)
    return 0
  fi

  pwd -P
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

# The pattern is empty rather than `.` so that it matches an empty line too. A
# file of nothing but newlines is text, and `.` finds nothing to match in it —
# which grep reports the same way it reports a binary file. What is left is
# `-I`, which is the actual question being asked.
#
# Empty files count as text; `grep -I` reports "no match" for them either way.
is_text_file() {
  [ -s "$1" ] || return 0
  LC_ALL=C grep -Iq '' -- "$1" 2>/dev/null
}

# `check-ignore` answers this on its own: 0 is ignored, 1 is not, and 128 is
# "not a repository" — which is also not ignored. Asking `rev-parse` first only
# buys a second fork on a path that runs after every edit.
is_git_ignored() {
  local file="$1" dir
  command -v git >/dev/null 2>&1 || return 1
  dir="$(dirname -- "$file")"
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
# Detection
# ---------------------------------------------------------------------------

have() {
  command -v "$1" >/dev/null 2>&1
}

# Quote a value so that it survives run_one's eval as a single word. The edited
# file reaches the command as a positional parameter, but a pinned binary or a
# discovered config is spliced into the template as text — and a project
# directory with a space in it is ordinary.
shell_quote() {
  local s="$1"
  local q="'"
  local esc="'\''"
  printf "'%s'" "${s//"$q"/$esc}"
}

# Lowercase without ${var,,}, which is Bash 4+.
lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Extension of a path, lowercased and without the dot; empty when there is none.
extension_of() {
  local base="${1##*/}"
  case "$base" in
    ?*.*) lower "${base##*.}" ;;
    *) printf '' ;;
  esac
}

# Where to stop when walking up looking for config files: the enclosing git
# repo if there is one, otherwise the project root. Never the filesystem root —
# a stray ~/pyproject.toml should not change how a project is linted.
ceiling_dir() {
  local dir="$1" top
  # main resolves this once per run; every find_up after that is a free read.
  if [ -n "$LINT_HOOK_CEILING" ]; then
    printf '%s' "$LINT_HOOK_CEILING"
    return 0
  fi
  if have git; then
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"
    if [ -n "$top" ]; then
      printf '%s' "$top"
      return 0
    fi
  fi
  printf '%s' "${LINT_HOOK_ROOT:-/}"
}

# Walk up from <dir> to the ceiling looking for any of the named entries, and
# print the first hit.
find_up() {
  local dir="$1" ceiling name
  shift
  ceiling="$(ceiling_dir "$dir")"
  # A ceiling of "/" would make the containment pattern below "//*"; dropping
  # the slash leaves "/*", which still matches everything beneath the root.
  [ "$ceiling" = "/" ] && ceiling=""
  while :; do
    # Containment, not equality. The walk starts outside the ceiling whenever
    # the edited file lives outside the project, and an equality test never
    # fires there — the walk climbs to /, reading whatever $HOME contains.
    case "$dir" in
      "$ceiling" | "$ceiling"/*) ;;
      *) break ;;
    esac
    for name in "$@"; do
      if [ -e "$dir/$name" ]; then
        printf '%s' "$dir/$name"
        return 0
      fi
    done
    [ "$dir" = "/" ] && break
    dir="$(dirname -- "$dir")"
  done
  return 1
}

# A project-local node_modules/.bin entry beats a global install, so that a repo
# is linted with the version it pins.
node_bin() {
  local name="$1" dir="$2" hit
  if hit="$(find_up "$dir" "node_modules/.bin/$name")"; then
    printf '%s' "$hit"
    return 0
  fi
  if have "$name"; then
    command -v "$name"
    return 0
  fi
  return 1
}

# Syntax-only checkers for data formats. Exit 127 is the agreed signal for "no
# usable backend", which the runner treats as tooling absence rather than a
# lint failure.
#
# Three things each of these has to get right. The module probe happens inside
# the interpreter that does the parsing, because a separate `python3 -c "import
# yaml"` doubles the interpreter startups on a path that runs after every edit.
# The file is opened in binary, so that a UTF-8 file does not fail to parse
# under an ASCII locale. And a failure prints the message alone: a traceback is
# noise in the context of the agent that has to read it.
lh_check_json() {
  if have jq; then
    jq empty -- "$1"
    return $?
  fi
  have python3 || return 127
  python3 - "$1" <<'PY'
import json, sys

try:
    with open(sys.argv[1], "rb") as f:
        json.load(f)
except (OSError, ValueError) as e:
    sys.stderr.write("%s\n" % e)
    sys.exit(1)
PY
}

# safe_load_all, not safe_load: a file holding several `---`-separated documents
# is valid YAML, and safe_load rejects it outright as a syntax error.
lh_check_yaml() {
  have python3 || return 127
  python3 - "$1" <<'PY'
import sys

try:
    import yaml
except ImportError:
    sys.exit(127)

try:
    with open(sys.argv[1], "rb") as f:
        list(yaml.safe_load_all(f))
except (OSError, yaml.YAMLError) as e:
    sys.stderr.write("%s\n" % e)
    sys.exit(1)
PY
}

lh_check_toml() {
  have python3 || return 127
  python3 - "$1" <<'PY'
import sys

try:
    import tomllib
except ImportError:
    sys.exit(127)

try:
    with open(sys.argv[1], "rb") as f:
        tomllib.load(f)
except (OSError, tomllib.TOMLDecodeError) as e:
    sys.stderr.write("%s\n" % e)
    sys.exit(1)
PY
}

# The table. Prints the linters to run for <file>, one per line, as:
#
#   <name><TAB><failure-mode><TAB><command template>
#
# Failure mode is `status` (a non-zero exit means problems) or `output` (any
# output at all means problems, which is how `gofmt -l` reports). `{file}` in
# the template is replaced with the edited file.
#
# Adding a linter should be a few lines here and nothing else.
linters_for() {
  local file="$1" ext="$2" dir bin cfg
  dir="$(dirname -- "$file")"

  case "$ext" in
    py)
      if have ruff; then
        printf 'ruff\tstatus\truff check --no-cache --quiet --output-format=concise {file}\n'
      elif have flake8; then
        printf 'flake8\tstatus\tflake8 {file}\n'
      fi
      ;;
    js | jsx | mjs | cjs | ts | tsx | mts | cts)
      if find_up "$dir" biome.json biome.jsonc >/dev/null && bin="$(node_bin biome "$dir")"; then
        printf 'biome\tstatus\t%s lint --reporter=summary {file}\n' "$(shell_quote "$bin")"
      # Gated on a config for the same reason biome is: eslint with nothing to
      # configure it exits non-zero saying so, which would reach the agent as a
      # lint failure it cannot fix by editing its file. An `eslintConfig` block
      # in package.json is not honoured — eslint 9 dropped it.
      elif find_up "$dir" eslint.config.js eslint.config.mjs eslint.config.cjs \
        eslint.config.ts eslint.config.mts eslint.config.cts \
        .eslintrc.js .eslintrc.cjs .eslintrc.yaml .eslintrc.yml \
        .eslintrc.json .eslintrc >/dev/null &&
        bin="$(node_bin eslint "$dir")"; then
        printf 'eslint\tstatus\t%s --no-color --format=unix {file}\n' "$(shell_quote "$bin")"
      fi
      ;;
    sh | bash)
      if have shellcheck; then
        printf 'shellcheck\tstatus\tshellcheck --format=gcc {file}\n'
      fi
      ;;
    go)
      # `gofmt -l` names files that need formatting and still exits 0, hence the
      # output failure mode. `go vet` is deliberately absent: it works on whole
      # packages, which would break the promise to report only the edited file.
      if have gofmt; then
        printf 'gofmt\toutput\tgofmt -l {file}\n'
      fi
      ;;
    rs)
      # rustfmt is file-scoped; clippy is crate-scoped, so it is left out for
      # the same reason as go vet.
      if have rustfmt; then
        printf 'rustfmt\tstatus\trustfmt --check --edition 2021 {file}\n'
      fi
      ;;
    java)
      if have checkstyle && cfg="$(find_up "$dir" checkstyle.xml config/checkstyle/checkstyle.xml)"; then
        printf 'checkstyle\tstatus\tcheckstyle -c %s {file}\n' "$(shell_quote "$cfg")"
      fi
      ;;
    json)
      # Gated like every other branch. Learning that the backend is missing by
      # forking an interpreter is a cost paid on every single edit.
      if have jq || have python3; then
        printf 'json-syntax\tstatus\tlh_check_json {file}\n'
      fi
      ;;
    yaml | yml)
      if have python3; then
        printf 'yaml-syntax\tstatus\tlh_check_yaml {file}\n'
      fi
      ;;
    toml)
      if have python3; then
        printf 'toml-syntax\tstatus\tlh_check_toml {file}\n'
      fi
      ;;
    md | markdown)
      # Opinionated, so off until lint-hook.toml can switch it on in Phase 3.
      :
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

# Run one linter. Returns 0 when the file is clean, 1 when it is not.
#
# The edited path is handed to the command as a positional parameter rather than
# spliced into the string, so a path with spaces, quotes, or shell metacharacters
# needs no escaping and cannot alter the command. Whatever the table splices in
# itself goes through shell_quote, for the same reason.
#
# Linters run from the project root, with a root-relative path where possible.
# Most of them resolve their own config relative to the working directory, so
# this is what makes a project's settings apply — and it keeps absolute paths
# out of the diagnostics the agent has to read. That path is both the argument
# handed to the linter and the name reported back, so it is one parameter.
run_one() {
  local name="$1" mode="$2" template="$3" file="$4"
  # The literal text "$1" is the substitution, expanded later by eval against
  # the positional parameter set below — not by this assignment.
  # shellcheck disable=SC2016
  local placeholder='"$1"'
  local cmd out status

  # Without a usable root the linter would run against whatever directory the
  # caller happened to be sitting in and report on the wrong tree. `cd ""`
  # succeeds in Bash, so an unset root has to be caught by hand.
  if [ -z "$LINT_HOOK_ROOT" ] || [ ! -d "$LINT_HOOK_ROOT" ]; then
    debug "$name: project root unusable (${LINT_HOOK_ROOT:-unset}), skipping"
    return 0
  fi

  cmd="${template//"{file}"/$placeholder}"
  debug "$name: $cmd"

  out="$(
    cd -- "$LINT_HOOK_ROOT" 2>/dev/null || exit 126
    set -- "$file"
    eval "$cmd" 2>&1
  )"
  status=$?

  # 127 is "not found" and 126 is "found but not executable" — a linter left
  # non-executable by a partial install, or a root that went away underneath
  # us. Both are tooling absence, which must never block the agent.
  if [ "$status" -eq 127 ] || [ "$status" -eq 126 ]; then
    debug "$name: not runnable (exit $status), skipping"
    return 0
  fi

  case "$mode" in
    output) [ -n "$out" ] || return 0 ;;
    *) [ "$status" -eq 0 ] && return 0 ;;
  esac

  notice "$name: $file"
  [ -n "$out" ] && printf '%s\n' "$out" >&2
  return 1
}

# Run every linter the table produced for the file. Returns 0 when all are
# clean, 1 when any reported problems.
run_linters() {
  local file="$1" plan="$2"
  local name mode template failed=0

  while IFS="$LINT_HOOK_TAB" read -r name mode template; do
    [ -n "$name" ] || continue
    # </dev/null: this loop's stdin is the plan, and a linter that reads stdin
    # would swallow the rows that have not been dispatched yet.
    run_one "$name" "$mode" "$template" "$file" </dev/null || failed=1
  done <<EOF
$plan
EOF

  return "$failed"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
  local payload file root resolved ext plan label

  case "${1-}" in
    --version)
      printf 'lint-hook %s\n' "$LINT_HOOK_VERSION"
      return "$EXIT_OK"
      ;;
  esac

  # Linter output goes to an agent, not a terminal. Phase 4 strips whatever
  # colour leaks through anyway.
  export NO_COLOR=1

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

  LINT_HOOK_ROOT="$root"
  LINT_HOOK_CEILING="$(ceiling_dir "$(dirname -- "$resolved")")"
  debug "lintable: $resolved (root: $root, ceiling: $LINT_HOOK_CEILING)"

  ext="$(extension_of "$resolved")"
  if [ -z "$ext" ]; then
    debug "no extension, nothing to detect"
    return "$EXIT_OK"
  fi

  plan="$(linters_for "$resolved" "$ext")"
  if [ -z "$plan" ]; then
    debug "no linter available for .$ext"
    return "$EXIT_OK"
  fi

  # Refer to the file the way the agent does. A file outside the project root
  # keeps its absolute path, since a relative one would not resolve there.
  label="${resolved#"$root"/}"
  # A leading dash reads as a bundle of short options to every linter we
  # dispatch to. "./" makes it a path again and leaves every other name alone.
  case "$label" in
    -*) label="./$label" ;;
  esac

  if run_linters "$label" "$plan"; then
    return "$EXIT_OK"
  fi
  return "$EXIT_BLOCK"
}

# Only run when executed, not when sourced by the test suite.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
