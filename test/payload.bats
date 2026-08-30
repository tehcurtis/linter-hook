#!/usr/bin/env bats
#
# Reading tool_input.file_path out of the PostToolUse payload.
#
# The payload carries the full old and new contents of the edit, so the parser
# has to tell a real key from an edit that merely talks about one. These run
# with no jq on PATH: the fallback is the supported path, and the one test that
# needs jq says so.

load 'helpers/common'

setup() {
  setup_project
  use_path_without_jq
}

@test "reads a plain file_path" {
  call 'extract_file_path "$1"' '{"tool_input":{"file_path":"/x/a.js"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "/x/a.js" ]
}

@test "ignores a key mentioned inside another string value" {
  call 'extract_file_path "$1"' \
    '{"tool_input":{"content":"see \"file_path\": \"/evil.js\"","file_path":"/x/a.js"}}'
  [ "$output" = "/x/a.js" ]
}

@test "a file_path under tool_response cannot stand in for a missing one" {
  call 'extract_file_path "$1"' \
    '{"tool_input":{"other":1},"tool_response":{"file_path":"/resp.js"}}'
  [ "$output" = "" ]
}

@test "a non-string value does not end the search" {
  call 'extract_file_path "$1"' \
    '{"tool_input":{"file_path":null,"file_path":"/x/b.js"}}'
  [ "$output" = "/x/b.js" ]
}

@test "decodes escapes in the value" {
  call 'extract_file_path "$1"' '{"tool_input":{"file_path":"/x/a\"b.js"}}'
  [ "$output" = '/x/a"b.js' ]
}

@test "decodes an escaped backslash and tab" {
  call 'extract_file_path "$1"' '{"tool_input":{"file_path":"/x/a\\b\tc.js"}}'
  [ "$output" = "$(printf '/x/a\\b\tc.js')" ]
}

@test "no tool_input at all yields nothing" {
  call 'extract_file_path "$1"' '{"cwd":"/x"}'
  [ "$output" = "" ]
}

@test "an escaped-only mention plus a tool_response decoy yields nothing" {
  call 'extract_file_path "$1"' \
    '{"tool_input":{"note":"the key \"file_path\" only appears escaped"},"tool_response":{"file_path":"/resp.js"}}'
  [ "$output" = "" ]
}

@test "an unterminated string is treated as no value, not a crash" {
  call 'extract_file_path "$1"' '{"tool_input":{"file_path":"/x/a.js'
  [ "$output" = "" ]
}

@test "the jq path and the fallback agree" {
  [ -n "$JQ_BIN" ] || skip "jq not installed"
  local pay='{"tool_input":{"content":"x \"file_path\": \"/evil.js\"","file_path":"/x/a.js"},"tool_response":{"file_path":"/resp.js"}}'
  local fallback

  call 'extract_file_path "$1"' "$pay"
  fallback="$output"

  PATH="$STUB_BIN:/usr/bin:/bin:$(dirname "$JQ_BIN")"
  export PATH
  call 'extract_file_path "$1"' "$pay"

  [ "$output" = "$fallback" ]
  [ "$output" = "/x/a.js" ]
}
