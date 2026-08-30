# Shared setup for the lint-hook suite.
#
# Every test runs against a throwaway project directory with a stub PATH, so a
# real ruff or shellcheck on the developer's machine can never change what the
# detection table selects — and CI needs no toolchain to exercise it.

# `run -<status>` is a 1.5 feature, and the suite uses it to say that a 127 is
# the expected answer rather than an accident.
bats_require_minimum_version 1.5.0

LINT_HOOK="${BATS_TEST_DIRNAME}/../lint-hook.sh"

# PROJECT is the fake project root, STUB_BIN the directory that stands in for
# a global install. Both are inside BATS_TEST_TMPDIR, which bats removes.
#
# The path is resolved physically because the hook resolves the edited file
# that way: on macOS the per-test temp directory is reached through a symlink,
# and a root that still contained it would share no prefix with the file.
setup_project() {
  PROJECT="$(mkdir -p "$BATS_TEST_TMPDIR/project" && cd "$BATS_TEST_TMPDIR/project" && pwd -P)"
  STUB_BIN="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_BIN"
  # Remembered while the real PATH is still in effect, so a test that wants jq
  # back can say so; use_path_without_jq is what takes it away.
  # shellcheck disable=SC2034  # read by the .bats files, which are not analysed
  JQ_BIN="$(command -v jq 2>/dev/null)" || JQ_BIN=""
  # shellcheck disable=SC2034  # read by the .bats files, which are not analysed
  PYTHON3_BIN="$(command -v python3 2>/dev/null)" || PYTHON3_BIN=""
  PATH="$STUB_BIN:/usr/bin:/bin"
  export PATH
}

# A PATH with no jq on it, so the pure-Bash fallback parser is what runs.
# Built by symlinking in what is needed rather than by shortening PATH, because
# jq ships in /usr/bin on some CI images and would otherwise quietly take over
# the test. Everything the hook shells out to is here, plus what it takes to
# launch it; name any extra tool a test needs as an argument.
use_path_without_jq() { # use_path_without_jq [extra tool...]
  local dir="$BATS_TEST_TMPDIR/nojq" tool found
  mkdir -p "$dir"
  for tool in env bash sh cat dirname basename grep tr git mkdir rm chmod ln "$@"; do
    found="$(command -v "$tool" 2>/dev/null)" && ln -sf "$found" "$dir/$tool"
  done
  PATH="$STUB_BIN:$dir"
  export PATH
}

# Write an executable stub at <path> that records how it was called and exits
# with the given status. Recording argv is what lets a test prove the edited
# file reached the linter as a single argument, and as a path rather than an
# option; recording the working directory proves linters run from the root.
write_stub() { # write_stub <path> <exit-status> [stdout line]
  local path="$1" status="$2" line="${3-}"
  # A separate statement: every word of a `local` is expanded before any of its
  # assignments take effect, so this cannot be folded into the line above.
  local name="${path##*/}"
  mkdir -p "${path%/*}"
  cat >"$path" <<EOF
#!/bin/sh
: >"$BATS_TEST_TMPDIR/$name.ran"
pwd >"$BATS_TEST_TMPDIR/$name.pwd"
for arg in "\$@"; do printf '%s\n' "\$arg"; done >"$BATS_TEST_TMPDIR/$name.argv"
[ -n "$line" ] && printf '%s\n' "$line"
exit $status
EOF
  chmod +x "$path"
}

# A stub found the way a global install would be.
stub_global() { # stub_global <name> <exit-status> [stdout line]
  write_stub "$STUB_BIN/$1" "$2" "${3-}"
}

# A stub found the way a project-pinned install would be.
stub_pinned() { # stub_pinned <name> <exit-status> [stdout line]
  write_stub "$PROJECT/node_modules/.bin/$1" "$2" "${3-}"
}

# Did the named stub run, and how was it called?
stub_ran() { [ -e "$BATS_TEST_TMPDIR/$1.ran" ]; }
stub_argv() { cat "$BATS_TEST_TMPDIR/$1.argv" 2>/dev/null; }
stub_pwd() { cat "$BATS_TEST_TMPDIR/$1.pwd" 2>/dev/null; }

# A PostToolUse payload naming <file_path>, with <cwd> defaulting to PROJECT.
payload() { # payload <file_path> [cwd]
  printf '{"tool_input":{"file_path":"%s"},"cwd":"%s"}' "$1" "${2-$PROJECT}"
}

# Run the hook over a payload. CLAUDE_PROJECT_DIR is cleared so that the root
# comes from the payload's cwd, which is what the tests control.
run_hook() { # run_hook <payload>
  run env -u CLAUDE_PROJECT_DIR bash "$LINT_HOOK" <<<"$1"
}

# Call a function from the script directly. A child shell, because the script
# sets -u at the top level and bats does not expect that in its own process.
#
# Trailing arguments reach the snippet as "$1", "$2", ... so that a payload
# full of quotes and backslashes can be written plainly instead of escaped
# through two layers of shell.
call() { # call [-<expected status>] <snippet> [args...]
  local -a expected=()
  # An expected status quiets bats' warning about a command exiting 127, which
  # is a normal answer here: it is how the hook signals tooling absence.
  case "${1-}" in
    -[0-9]*)
      expected=("$1")
      shift
      ;;
  esac
  local snippet="$1"
  shift
  # The single quotes are the point: this text is the child shell's script, and
  # its "$1" refers to that shell's arguments, not to anything here.
  # shellcheck disable=SC2016
  run "${expected[@]}" env -u CLAUDE_PROJECT_DIR bash -c \
    '. "$1"; shift; __snippet="$1"; shift; eval "$__snippet"' \
    bash "$LINT_HOOK" "$snippet" "$@"
}
