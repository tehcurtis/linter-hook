#!/usr/bin/env bats
#
# Running the plan: how a linter is invoked, and how its result becomes the
# hook's exit code. The contract is in the script's header — clean is 0,
# problems are 2, and missing or broken tooling is 0 and never blocks.

load 'helpers/common'

setup() {
  setup_project
  printf 'x = 1\n' >"$PROJECT/app.py"
}

@test "a clean linter exits 0 and says nothing" {
  stub_global ruff 0
  run_hook "$(payload app.py)"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "a failing linter blocks with its output on stderr" {
  stub_global ruff 1 "app.py:1:1: F401 unused import"
  run_hook "$(payload app.py)"
  [ "$status" -eq 2 ]
  [[ "$output" == *"lint-hook: ruff: app.py"* ]]
  [[ "$output" == *"F401 unused import"* ]]
}

@test "a linter that is not installed does not block" {
  # No stub at all: the template names a command that is not there, and the
  # shell answers 127.
  call -0 'LINT_HOOK_ROOT="$1"; run_one nosuch status "definitely-not-installed {file}" app.py' "$PROJECT"
  [ "$status" -eq 0 ]
}

@test "a linter that is not executable does not block" {
  stub_global ruff 1 "boom"
  chmod 644 "$STUB_BIN/ruff"
  run_hook "$(payload app.py)"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "output mode treats any output as a failure, whatever the exit status" {
  printf 'package main\n' >"$PROJECT/x.go"
  stub_global gofmt 0 "x.go"
  run_hook "$(payload x.go)"
  [ "$status" -eq 2 ]
  [[ "$output" == *"lint-hook: gofmt: x.go"* ]]
}

@test "output mode stays clean when the linter says nothing" {
  printf 'package main\n' >"$PROJECT/x.go"
  stub_global gofmt 0
  run_hook "$(payload x.go)"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "the linter runs from the project root and gets a relative path" {
  mkdir -p "$PROJECT/src"
  printf 'x = 1\n' >"$PROJECT/src/deep.py"
  stub_global ruff 0
  run_hook "$(payload src/deep.py)"
  [ "$status" -eq 0 ]
  [ "$(stub_pwd ruff)" = "$PROJECT" ]
  [[ "$(stub_argv ruff)" == *"src/deep.py"* ]]
}

@test "a project path with a space still reaches the linter as one argument" {
  local root
  root="$(mkdir -p "$BATS_TEST_TMPDIR/my project" && cd "$BATS_TEST_TMPDIR/my project" && pwd -P)"
  PROJECT="$root"
  printf 'export default [];\n' >"$PROJECT/eslint.config.js"
  printf 'var x = 1\n' >"$PROJECT/app.js"
  stub_pinned eslint 1 "app.js:1:1: problem"

  run_hook "$(payload app.js)"
  [ "$status" -eq 2 ]
  stub_ran eslint
  # One line per argument: the file is the last, whole and unsplit.
  [ "$(stub_argv eslint | tail -1)" = "app.js" ]
}

@test "a filename starting with a dash arrives as a path, not an option" {
  printf '#!/bin/sh\nrm $1\n' >"$PROJECT/-dash.sh"
  stub_global shellcheck 0
  run_hook "$(payload "-dash.sh")"
  [ "$status" -eq 0 ]
  [ "$(stub_argv shellcheck | tail -1)" = "./-dash.sh" ]
}

@test "a linter that reads stdin does not starve the next one" {
  call 'LINT_HOOK_ROOT="$1"
        plan="$(printf "drain\tstatus\tcat >/dev/null; true {file}\nsecond\tstatus\ttouch second.ran; true {file}\n")"
        run_linters app.py "$plan"' "$PROJECT"
  [ "$status" -eq 0 ]
  [ -e "$PROJECT/second.ran" ]
}

@test "one failing linter among several still blocks" {
  call 'LINT_HOOK_ROOT="$1"
        plan="$(printf "ok\tstatus\ttrue {file}\nbad\tstatus\tfalse {file}\n")"
        run_linters app.py "$plan"' "$PROJECT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lint-hook: bad: app.py"* ]]
}

@test "run_one will not run anything without a usable project root" {
  call 'LINT_HOOK_ROOT=""; cd "$1"; run_one t status "touch leaked.ran; true {file}" app.py' "$PROJECT"
  [ "$status" -eq 0 ]
  [ ! -e "$PROJECT/leaked.ran" ]
}

@test "a project root that does not exist is not linted in" {
  call 'LINT_HOOK_ROOT="$1/gone"; cd "$1"; run_one t status "touch leaked.ran; true {file}" app.py' "$PROJECT"
  [ "$status" -eq 0 ]
  [ ! -e "$PROJECT/leaked.ran" ]
}

@test "a file outside the project keeps its absolute path" {
  printf 'x = 1\n' >"$BATS_TEST_TMPDIR/outside.py"
  stub_global ruff 1 "problem"
  run_hook "$(payload "$BATS_TEST_TMPDIR/outside.py")"
  [ "$status" -eq 2 ]
  [[ "$output" == *"outside.py"* ]]
  [[ "$(stub_argv ruff | tail -1)" == /* ]]
}

@test "NO_COLOR is exported to the linter" {
  cat >"$STUB_BIN/ruff" <<'EOF'
#!/bin/sh
printf 'NO_COLOR=%s\n' "${NO_COLOR-unset}"
exit 1
EOF
  chmod +x "$STUB_BIN/ruff"
  run_hook "$(payload app.py)"
  [[ "$output" == *"NO_COLOR=1"* ]]
}
