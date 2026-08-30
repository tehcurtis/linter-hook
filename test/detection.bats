#!/usr/bin/env bats
#
# The detection table: which linter gets picked for a file, and where its
# config and binary are allowed to come from.

load 'helpers/common'

setup() {
  setup_project
}

# The table prints "<name><TAB><mode><TAB><template>". Tests assert on the
# fields rather than the whole line, so adding a flag to a template does not
# break an unrelated test.
plan_name() { printf '%s' "${1%%$'\t'*}"; }
plan_mode() {
  local rest="${1#*$'\t'}"
  printf '%s' "${rest%%$'\t'*}"
}

@test "ruff is preferred for python" {
  stub_global ruff 0
  stub_global flake8 0
  call 'LINT_HOOK_ROOT="$1"; linters_for "$1/app.py" py' "$PROJECT"
  [ "$(plan_name "$output")" = "ruff" ]
  [ "$(plan_mode "$output")" = "status" ]
}

@test "flake8 is the fallback when ruff is absent" {
  stub_global flake8 0
  call 'LINT_HOOK_ROOT="$1"; linters_for "$1/app.py" py' "$PROJECT"
  [ "$(plan_name "$output")" = "flake8" ]
}

@test "no python linter installed means no plan" {
  call 'LINT_HOOK_ROOT="$1"; linters_for "$1/app.py" py' "$PROJECT"
  [ "$output" = "" ]
}

@test "biome wins when its config is present" {
  printf '{}\n' >"$PROJECT/biome.json"
  stub_pinned biome 0
  stub_pinned eslint 0
  call 'LINT_HOOK_ROOT="$1"; linters_for "$1/app.ts" ts' "$PROJECT"
  [ "$(plan_name "$output")" = "biome" ]
}

@test "eslint is not selected without an eslint config" {
  stub_pinned eslint 0
  call 'LINT_HOOK_ROOT="$1"; linters_for "$1/app.js" js' "$PROJECT"
  [ "$output" = "" ]
}

@test "eslint is selected with a flat config" {
  printf 'export default [];\n' >"$PROJECT/eslint.config.js"
  stub_pinned eslint 0
  call 'LINT_HOOK_ROOT="$1"; linters_for "$1/app.js" js' "$PROJECT"
  [ "$(plan_name "$output")" = "eslint" ]
}

@test "eslint is selected with a legacy rc config" {
  printf '{}\n' >"$PROJECT/.eslintrc.json"
  stub_pinned eslint 0
  call 'LINT_HOOK_ROOT="$1"; linters_for "$1/app.js" js' "$PROJECT"
  [ "$(plan_name "$output")" = "eslint" ]
}

@test "biome without its binary falls through to eslint" {
  printf '{}\n' >"$PROJECT/biome.json"
  printf 'export default [];\n' >"$PROJECT/eslint.config.js"
  stub_pinned eslint 0
  call 'LINT_HOOK_ROOT="$1"; linters_for "$1/app.js" js' "$PROJECT"
  [ "$(plan_name "$output")" = "eslint" ]
}

@test "a project-pinned binary beats a global one" {
  printf '{}\n' >"$PROJECT/biome.json"
  stub_global biome 0
  stub_pinned biome 0
  call 'LINT_HOOK_ROOT="$1"; linters_for "$1/app.ts" ts' "$PROJECT"
  [[ "$output" == *"$PROJECT/node_modules/.bin/biome"* ]]
}

@test "a global binary is used when nothing is pinned" {
  printf '{}\n' >"$PROJECT/biome.json"
  stub_global biome 0
  call 'LINT_HOOK_ROOT="$1"; linters_for "$1/app.ts" ts' "$PROJECT"
  [[ "$output" == *"$STUB_BIN/biome"* ]]
}

@test "a discovered binary is quoted, so a path with a space survives" {
  local root
  root="$(mkdir -p "$BATS_TEST_TMPDIR/my project" && cd "$BATS_TEST_TMPDIR/my project" && pwd -P)"
  PROJECT="$root"
  printf '{}\n' >"$PROJECT/biome.json"
  stub_pinned biome 0
  call 'LINT_HOOK_ROOT="$1"; linters_for "$1/app.ts" ts' "$PROJECT"
  [[ "$output" == *"'$PROJECT/node_modules/.bin/biome'"* ]]
}

@test "shellcheck is selected for shell scripts" {
  stub_global shellcheck 0
  call 'LINT_HOOK_ROOT="$1"; linters_for "$1/x.sh" sh' "$PROJECT"
  [ "$(plan_name "$output")" = "shellcheck" ]
}

@test "gofmt reports through the output mode, not the exit status" {
  stub_global gofmt 0
  call 'LINT_HOOK_ROOT="$1"; linters_for "$1/x.go" go' "$PROJECT"
  [ "$(plan_name "$output")" = "gofmt" ]
  [ "$(plan_mode "$output")" = "output" ]
}

@test "checkstyle needs both the binary and a config" {
  stub_global checkstyle 0
  call 'LINT_HOOK_ROOT="$1"; linters_for "$1/A.java" java' "$PROJECT"
  [ "$output" = "" ]

  printf '<x/>\n' >"$PROJECT/checkstyle.xml"
  call 'LINT_HOOK_ROOT="$1"; linters_for "$1/A.java" java' "$PROJECT"
  [ "$(plan_name "$output")" = "checkstyle" ]
  [[ "$output" == *"'$PROJECT/checkstyle.xml'"* ]]
}

@test "markdown is off until lint-hook.toml can switch it on" {
  call 'LINT_HOOK_ROOT="$1"; linters_for "$1/README.md" md' "$PROJECT"
  [ "$output" = "" ]
}

@test "the config walk finds a config inside the project" {
  mkdir -p "$PROJECT/src/deep"
  printf '{}\n' >"$PROJECT/biome.json"
  call 'LINT_HOOK_ROOT="$1"; find_up "$2" biome.json' "$PROJECT" "$PROJECT/src/deep"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJECT/biome.json" ]
}

@test "the config walk does not leave the project root" {
  mkdir -p "$BATS_TEST_TMPDIR/stray/node_modules/.bin"
  : >"$BATS_TEST_TMPDIR/stray/node_modules/.bin/eslint"
  call 'LINT_HOOK_ROOT="$1"; find_up "$2" node_modules/.bin/eslint' \
    "$PROJECT" "$BATS_TEST_TMPDIR/stray"
  [ "$status" -ne 0 ]
  [ "$output" = "" ]
}

@test "the ceiling is resolved once and then reused" {
  printf '{}\n' >"$PROJECT/biome.json"
  call 'LINT_HOOK_CEILING="$2"; LINT_HOOK_ROOT="/nowhere"; find_up "$2/src" biome.json' \
    "$PROJECT" "$PROJECT"
  mkdir -p "$PROJECT/src"
  call 'LINT_HOOK_CEILING="$1"; LINT_HOOK_ROOT="/nowhere"; find_up "$1/src" biome.json' "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJECT/biome.json" ]
}
