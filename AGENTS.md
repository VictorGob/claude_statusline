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
- **Burn rate (5h window only)** — `burn_ratio()` derives elapsed time as `18000 - (resets_at - now)` (assuming a fixed 5-hour window) and returns `used_pct / expected_pct`, where `expected_pct` is the straight-line spend for the elapsed fraction. The result is a multiple of budget: `1.0` is exactly on pace, above that is overspending. The `5h` label turns yellow at ≥1.15x and red at ≥1.5x; the ⏱️ icon becomes 🔥 at ≥1.25x — equivalent to 23/25/30 %/hour. The warn threshold sits above 1.0 on purpose: spending exactly on budget lands at 100% just as the window resets, so warning there would be permanently on and would flicker as the ratio crossed the line between refreshes. Guards return `None` (no coloring) when `resets_at` is missing/past, when remaining time exceeds the window, or within the first 5% (15 min), where the average is too noisy to be meaningful.
- **Why 7d has no pace cue** — a straight-line budget assumes uniform spending. That holds within a 5-hour session but not across a week: a weekday-only pattern reads as ~1.4x by Friday while being exactly on track to finish the week. The cue would fire constantly for normal usage, so the 7d display stays a plain 📅 with only its used-% coloring.

## JSON Schema (stdin)

The program parses these fields from the JSON object piped to stdin:

| Path | Type | Used for |
|------|------|----------|
| `model.display_name` | string | Model name in header |
| `effort.level` | string | Reasoning effort shown after model name (optional; `low`/`medium`/`high`/`xhigh`/`max`, each its own color) |
| `workspace.current_dir` | string | Directory basename |
| `context_window.used_percentage` | number | Context % (color-coded) |
| `rate_limits.five_hour.used_percentage` | number | 5h rate limit used % (color-coded; Pro/Max only) |
| `rate_limits.five_hour.resets_at` | int | Unix epoch seconds when 5h window resets (countdown display; also derives elapsed time for the burn-rate cue on the `5h` label) |
| `rate_limits.seven_day.used_percentage` | number | 7d (weekly) rate limit used % (color-coded; Pro/Max only) |
| `rate_limits.seven_day.resets_at` | int | Unix epoch seconds when 7d window resets (countdown display) |

All fields are optional; missing fields are silently skipped.

## Code Conventions

- **Edition:** 2021
- **Functions/variables:** `snake_case`
- **Constants:** `UPPERCASE`
- **Release profile:** `opt-level = 3`, `lto = true`, `strip = true`, `panic = "abort"`, `codegen-units = 1` (see `Cargo.toml`)
- **Dependencies:** kept minimal — `serde` + `serde_json` only; avoid adding new crates without discussing first
