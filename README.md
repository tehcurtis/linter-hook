# lint-hook

A zero-dependency Bash script that plugs into [Claude Code](https://claude.com/claude-code)'s
`PostToolUse` hook, works out which linter belongs to whatever file the agent
just edited, runs it on **only that file**, and stays silent unless something
fails.

> **Status: pre-release.** The scaffolding is in place; the hook itself is
> being built out phase by phase. Not yet usable.

## Why

Asking the agent to "remember to lint" costs tokens on every turn and it still
forgets. A hook is deterministic, runs outside the model's attention, and costs
nothing until something is actually wrong.

## Install

Drop the script into your project and register it as a `PostToolUse` hook:

```bash
curl -fsSL https://raw.githubusercontent.com/tehcurtis/linter-hook/main/lint-hook.sh \
  -o .claude/hooks/lint-hook.sh && chmod +x .claude/hooks/lint-hook.sh
```

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/lint-hook.sh"
          }
        ]
      }
    ]
  }
}
```

## Behaviour

| Result | Hook does |
| --- | --- |
| File is clean | exits 0, prints nothing |
| Lint errors | exits 2, terse errors on stderr — Claude sees them and fixes |
| Linter not installed | exits 0 — never blocks you over missing tooling |

Autofixes (safe ones only) are applied by default. When a fix lands, the hook
exits 2 with a note telling the agent to re-read the file, so it never keeps
editing against a stale copy.

## Configuration

Optional. Create a `lint-hook.toml` at your repo root to override detection —
see [`lint-hook.toml.example`](lint-hook.toml.example) for the full grammar and
supported keys.

## Requirements

Bash 3.2 or newer, which includes the `/bin/bash` macOS ships. `jq` is used when
present but is not required.

## License

[MIT](LICENSE)
