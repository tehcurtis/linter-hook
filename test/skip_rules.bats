#!/usr/bin/env bats
#
# What the hook declines to lint. A wrong answer here is quiet in both
# directions: a skipped file is never checked, and an unskippable one blocks
# the agent on something it cannot fix.

load 'helpers/common'

setup() {
  setup_project
  stub_global ruff 0
}

@test "a file of nothing but newlines is text, and is linted" {
  printf '\n\n\n' >"$PROJECT/blank.py"
  run_hook "$(payload blank.py)"
  [ "$status" -eq 0 ]
  stub_ran ruff
}

@test "an empty file is text" {
  : >"$PROJECT/empty.py"
  call 'is_text_file "$1"' "$PROJECT/empty.py"
  [ "$status" -eq 0 ]
}

@test "a file with a NUL byte is skipped" {
  printf 'a\000b\n' >"$PROJECT/binary.py"
  run_hook "$(payload binary.py)"
  [ "$status" -eq 0 ]
  ! stub_ran ruff
}

@test "a path that does not exist is skipped" {
  run_hook "$(payload gone.py)"
  [ "$status" -eq 0 ]
  ! stub_ran ruff
}

@test "a directory is skipped" {
  mkdir -p "$PROJECT/adir.py"
  run_hook "$(payload adir.py)"
  [ "$status" -eq 0 ]
  ! stub_ran ruff
}

@test "a git-ignored file is skipped" {
  command -v git >/dev/null 2>&1 || skip "git not installed"
  git -C "$PROJECT" init -q
  printf 'vendor/\n' >"$PROJECT/.gitignore"
  mkdir -p "$PROJECT/vendor"
  printf 'x = 1\n' >"$PROJECT/vendor/dep.py"
  run_hook "$(payload vendor/dep.py)"
  [ "$status" -eq 0 ]
  ! stub_ran ruff
}

@test "a tracked file in the same repo is still linted" {
  command -v git >/dev/null 2>&1 || skip "git not installed"
  git -C "$PROJECT" init -q
  printf 'vendor/\n' >"$PROJECT/.gitignore"
  printf 'x = 1\n' >"$PROJECT/app.py"
  run_hook "$(payload app.py)"
  [ "$status" -eq 0 ]
  stub_ran ruff
}

@test "a file with no extension is skipped" {
  printf 'x = 1\n' >"$PROJECT/Makefile"
  run_hook "$(payload Makefile)"
  [ "$status" -eq 0 ]
  ! stub_ran ruff
}

@test "an extension with no linter is skipped" {
  printf 'hello\n' >"$PROJECT/notes.txt"
  run_hook "$(payload notes.txt)"
  [ "$status" -eq 0 ]
  ! stub_ran ruff
}

@test "an empty payload is not an error" {
  run env -u CLAUDE_PROJECT_DIR bash "$LINT_HOOK" </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "--version reports and exits clean" {
  run env -u CLAUDE_PROJECT_DIR bash "$LINT_HOOK" --version </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == lint-hook\ * ]]
}
