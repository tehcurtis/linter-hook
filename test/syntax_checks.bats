#!/usr/bin/env bats
#
# The built-in syntax checkers for data formats.
#
# These are the one corner the suite cannot drive through stubs: the checkers
# are the backend. So each test says which backend it needs and skips when that
# backend is absent, which keeps the promise that CI needs no toolchain — a
# runner without PyYAML reports skips, not failures.

load 'helpers/common'

setup() {
  setup_project
  # setup_project narrows PATH to the system tools so that a real linter cannot
  # influence detection. Here the interpreter *is* what is under test, so the
  # python3 the developer actually has goes back on the path — otherwise a
  # venv with PyYAML in it still reports skips.
  [ -n "$PYTHON3_BIN" ] && PATH="$STUB_BIN:$(dirname "$PYTHON3_BIN"):/usr/bin:/bin"
  export PATH
}

needs_python3() {
  command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
}

needs_module() {
  needs_python3
  python3 -c "import $1" 2>/dev/null || skip "python3 module $1 not installed"
}

@test "valid JSON passes" {
  printf '{"a":1}\n' >"$PROJECT/x.json"
  command -v jq >/dev/null 2>&1 || needs_python3
  call 'lh_check_json "$1"' "$PROJECT/x.json"
  [ "$status" -eq 0 ]
}

@test "invalid JSON fails" {
  printf '{"a":}\n' >"$PROJECT/x.json"
  command -v jq >/dev/null 2>&1 || needs_python3
  call 'lh_check_json "$1"' "$PROJECT/x.json"
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "UTF-8 JSON passes under an ASCII locale" {
  needs_python3
  printf '{"name":"caf\303\251"}\n' >"$PROJECT/x.json"
  use_path_without_jq python3
  run env -u CLAUDE_PROJECT_DIR LC_ALL=C PYTHONCOERCECLOCALE=0 PYTHONUTF8=0 \
    bash -c '. "$1"; lh_check_json "$2"' bash "$LINT_HOOK" "$PROJECT/x.json"
  [ "$status" -eq 0 ]
}

@test "a JSON parse error is reported without a traceback" {
  needs_python3
  printf '{"a":}\n' >"$PROJECT/x.json"
  use_path_without_jq python3
  call 'lh_check_json "$1"' "$PROJECT/x.json"
  [ "$status" -eq 1 ]
  [[ "$output" != *"Traceback"* ]]
  [ -n "$output" ]
}

@test "a multi-document YAML file is valid" {
  needs_module yaml
  printf 'a: 1\n---\nb: 2\n' >"$PROJECT/x.yaml"
  call 'lh_check_yaml "$1"' "$PROJECT/x.yaml"
  [ "$status" -eq 0 ]
}

@test "a single-document YAML file is valid" {
  needs_module yaml
  printf 'a: 1\nb: 2\n' >"$PROJECT/x.yaml"
  call 'lh_check_yaml "$1"' "$PROJECT/x.yaml"
  [ "$status" -eq 0 ]
}

@test "broken YAML fails, and reports without a traceback" {
  needs_module yaml
  printf 'a: [1, 2\n' >"$PROJECT/x.yaml"
  call 'lh_check_yaml "$1"' "$PROJECT/x.yaml"
  [ "$status" -eq 1 ]
  [[ "$output" != *"Traceback"* ]]
  [ -n "$output" ]
}

@test "valid TOML passes and broken TOML fails" {
  needs_module tomllib
  printf 'a = 1\n' >"$PROJECT/ok.toml"
  call 'lh_check_toml "$1"' "$PROJECT/ok.toml"
  [ "$status" -eq 0 ]

  printf 'a = \n' >"$PROJECT/bad.toml"
  call 'lh_check_toml "$1"' "$PROJECT/bad.toml"
  [ "$status" -eq 1 ]
  [[ "$output" != *"Traceback"* ]]
}

@test "no backend at all is tooling absence, not a lint failure" {
  printf '{"a":}\n' >"$PROJECT/x.json"
  # A PATH with neither jq nor python3 on it.
  use_path_without_jq
  call -127 'lh_check_json "$1"' "$PROJECT/x.json"
  [ "$status" -eq 127 ]
}

# A throwaway venv rather than "skip when PyYAML happens to be absent": CI
# installs PyYAML, so the skip version of this test never ran where it counts.
# --without-pip keeps it to well under a second.
@test "a missing python module is tooling absence" {
  needs_python3
  printf 'a: 1\n' >"$PROJECT/x.yaml"
  python3 -m venv --without-pip "$BATS_TEST_TMPDIR/bare" 2>/dev/null ||
    skip "python3 cannot create a venv"
  PATH="$STUB_BIN:$BATS_TEST_TMPDIR/bare/bin:/usr/bin:/bin"
  export PATH
  python3 -c 'import yaml' 2>/dev/null && skip "the bare venv can still see PyYAML"

  call -127 'lh_check_yaml "$1"' "$PROJECT/x.yaml"
  [ "$status" -eq 127 ]
}

@test "the table offers no syntax check when no backend is installed" {
  use_path_without_jq
  call 'LINT_HOOK_ROOT="$1"; linters_for "$1/x.json" json' "$PROJECT"
  [ "$output" = "" ]
}

@test "a syntax check that fails blocks the hook" {
  command -v jq >/dev/null 2>&1 || needs_python3
  printf '{"a":}\n' >"$PROJECT/x.json"
  run_hook "$(payload x.json)"
  [ "$status" -eq 2 ]
  [[ "$output" == *"lint-hook: json-syntax: x.json"* ]]
}
