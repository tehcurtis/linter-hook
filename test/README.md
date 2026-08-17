# Tests

[bats-core](https://github.com/bats-core/bats-core) suite. Landing in Phase 5.

The suite drives `lint-hook.sh` through fake linters — tiny stub scripts placed
on `PATH` — so CI never needs a real Python, Node, Go, or Rust toolchain
installed to exercise the detection and reporting paths.

```bash
brew install bats-core   # or: npm install -g bats
bats test/
```
