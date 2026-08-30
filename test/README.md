# Tests

[bats-core](https://github.com/bats-core/bats-core) suite, run on every push
against both Ubuntu and macOS.

```bash
brew install bats-core   # or: mise use -g bats, or: npm install -g bats
bats test/
```

bats 1.5 or newer is required — the suite uses `run -<status>` to say when a
non-zero exit is the expected answer rather than an accident.

## How it works

The suite drives `lint-hook.sh` through **fake linters** — tiny stub scripts
written into a per-test directory that is put at the front of `PATH`. Nothing
here needs a real Python, Node, Go, or Rust toolchain, and a real `ruff` on the
developer's machine cannot change what the detection table selects.

Each stub records how it was called — argv one line per argument, plus its
working directory — which is what lets a test assert that the edited file
arrived as a *single* argument, as a path rather than an option, and relative
to the project root.

`test/helpers/common.bash` holds the shared setup: `setup_project`,
`stub_global` / `stub_pinned`, `payload`, `run_hook` for driving the hook
end-to-end, and `call` for exercising one function directly.

## The files

| File | What it covers |
| --- | --- |
| `payload.bats` | Reading `tool_input.file_path`, including keys that appear only as escaped text inside an edit, and `tool_response` decoys |
| `skip_rules.bats` | What the hook declines to lint: binary, missing, not a regular file, git-ignored, no linter for the extension |
| `detection.bats` | Which linter is selected, which config gates it, project-pinned over global, and the ceiling on the config walk |
| `execution.bats` | How a linter is invoked and how its result becomes the exit code: quoting, the 126/127 contract, output mode, stdin |
| `syntax_checks.bats` | The built-in JSON/YAML/TOML checkers |

## Skips

`syntax_checks.bats` is the one place the stub approach does not reach, because
there the checker *is* the backend. Those tests declare what they need and skip
when it is absent, so a runner without PyYAML reports skips rather than
failures. Everything else runs everywhere.
