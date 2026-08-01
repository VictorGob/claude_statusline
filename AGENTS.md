# claude_statusline

Rust statusline formatter for Claude Code. Reads JSON from stdin (piped by Claude Code's statusline runner) and outputs an ANSI-colored two-line display showing model, directory, git branch, context usage, and 5-hour/7-day rate limits.

## Build

```bash
make          # cargo build --release
make clean    # cargo clean
make test     # build + run smoke tests
```

`make` is the Unix entry point. **`build.ps1` is its Windows equivalent** — same three targets
(`.\build.ps1`, `-Clean`, `-Test`), same smoke assertions. The two duplicate the burn-rate
thresholds, so a change to those in `src/main.rs` has to land in all three files. `build.ps1`
forces UTF-8 on capture (the flame assertions compare emoji, which a non-UTF-8 console code page
would mangle) and, unlike the Makefile, exits non-zero when an assertion fails.

**Dependency:** Rust toolchain (`rustup`). `serde`/`serde_json` are fetched automatically by Cargo from crates.io — no system packages required. On Windows the `x86_64-pc-windows-gnu` host needs no Visual Studio: rustup's `rust-mingw` component ships its own `x86_64-w64-mingw32-gcc.exe` and `ld.exe`.

## Architecture

- **`src/main.rs`** — Single-file Rust program; all logic lives here.
- **`statusline.sh`** — Tiny shell wrapper that invokes the release binary (`target/release/claude_statusline`) from the script's directory. Used as the Claude Code statusline command.
- Git branch is read directly from `.git/HEAD` (no `git` subprocess). The forward slash is fine on Windows — Win32 accepts it — and `str::lines()` strips the CRLF, so the same code path serves both platforms.
- **Directory basename** splits on `/` *and* `\`: `workspace.current_dir` is backslash-delimited on Windows, so a `'/'`-only split returned the entire path instead of the last component.
- JSON is deserialized with `serde`/`serde_json` into structs with `Option<T>` fields — missing fields become `None` automatically.
- **Burn rate (5h window only)** — `burn_ratio()` returns `used_pct / expected_pct`, where `expected_pct` is the straight-line spend for the elapsed fraction of the window. The result is a multiple of budget: `1.0` is exactly on pace, above that is overspending. The `5h` label turns yellow at ≥1.15x and red at ≥1.75x; the ⏱️ icon becomes 🔥 at ≥1.4x — equivalent to 23/28/35 %/hour. The warn threshold sits above 1.0 on purpose: spending exactly on budget lands at 100% just as the window resets, so warning there would be permanently on and would flicker as the ratio crossed the line between refreshes. Red sits at 1.75x rather than higher because red at ratio `r` is unreachable past `5h / r` elapsed (it would need >100% used), so pushing it up shrinks the span of the window in which red can appear at all.
- **`window_elapsed_secs()`** — shared by `burn_ratio()` and `dry_in_suffix()`. Derives elapsed time as `18000 - (resets_at - now)`, assuming a fixed 5-hour window, and holds all the guards: returns `None` when `resets_at` is missing/past, when remaining time exceeds the window (clock skew), or within the first 5% (15 min), where the average is too noisy to be meaningful. A `None` here means no burn coloring and no projection.
- **`dry_in_suffix()`** — appends `, dry in 1h30m` after the countdown, but only at red (≥1.75x); every other level is unchanged, so line 2 keeps its usual width. Computed as `(100 - used) / used * elapsed` — no days branch, since at ≥1.75x exhaustion is always under 2h51m away. Caveat: it inherits the cumulative-average lag, so after a burst followed by idling it keeps quoting a stale time. Confining it to red limits how often that shows.
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
- **Release profile:** `opt-level = "s"`, `lto = true`, `strip = true`, `panic = "abort"`, `codegen-units = 1` (see `Cargo.toml`). Size is preferred over speed on purpose: the program does almost no computation and is spawned fresh on every statusline refresh, so startup dominates and a smaller binary pages in faster. Note ~73% of the binary is irreducible std baseline — an empty `println!` program with this profile is already 305 KB.
- **Dependencies:** kept minimal — `serde` + `serde_json` only; avoid adding new crates without discussing first
