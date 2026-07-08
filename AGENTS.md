# claude_statusline

Rust statusline formatter for Claude Code. Reads JSON from stdin (piped by Claude Code's statusline runner) and outputs an ANSI-colored two-line display showing model, directory, git branch, context usage, and 5-hour/7-day rate limits.

## Build

```bash
make          # cargo build --release
make clean    # cargo clean
make test     # build + run smoke tests
```

**Dependency:** Rust toolchain (`rustup`). `serde`/`serde_json` are fetched automatically by Cargo from crates.io — no system packages required.

## Architecture

- **`src/main.rs`** — Single-file Rust program; all logic lives here.
- **`statusline.sh`** — Tiny shell wrapper that invokes the release binary (`target/release/claude_statusline`) from the script's directory. Used as the Claude Code statusline command.
- Git branch is read directly from `.git/HEAD` (no `git` subprocess).
- JSON is deserialized with `serde`/`serde_json` into structs with `Option<T>` fields — missing fields become `None` automatically.

## JSON Schema (stdin)

The program parses these fields from the JSON object piped to stdin:

| Path | Type | Used for |
|------|------|----------|
| `model.display_name` | string | Model name in header |
| `workspace.current_dir` | string | Directory basename |
| `context_window.used_percentage` | number | Context % (color-coded) |
| `rate_limits.five_hour.used_percentage` | number | 5h rate limit used % (color-coded; Pro/Max only) |
| `rate_limits.five_hour.resets_at` | int | Unix epoch seconds when 5h window resets (countdown display) |
| `rate_limits.seven_day.used_percentage` | number | 7d (weekly) rate limit used % (color-coded; Pro/Max only) |
| `rate_limits.seven_day.resets_at` | int | Unix epoch seconds when 7d window resets (countdown display) |

All fields are optional; missing fields are silently skipped.

## Code Conventions

- **Edition:** 2021
- **Functions/variables:** `snake_case`
- **Constants:** `UPPERCASE`
- **Release profile:** `opt-level = 3`, `lto = true`, `strip = true`, `panic = "abort"`, `codegen-units = 1` (see `Cargo.toml`)
- **Dependencies:** kept minimal — `serde` + `serde_json` only; avoid adding new crates without discussing first
