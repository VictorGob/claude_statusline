# claude_statusline

Rust statusline formatter for Claude Code. Reads JSON from stdin (piped by Claude Code's statusline runner) and outputs an ANSI-colored two-line display showing model, directory, git branch, session age, context usage, prompt-cache hit ratio, and 5-hour/7-day rate limits.

## Build

```bash
make          # cargo build --release
make clean    # cargo clean
make test     # build + run smoke tests
```

`make` is the Unix entry point. **`build.ps1` is its Windows equivalent** — same three targets
(`.\build.ps1`, `-Clean`, `-Test`), same smoke assertions. The two duplicate every threshold in
`src/main.rs` — the `BURN_*` ratios, `CACHE_*`, and `AGE_*`/`ACTIVITY_*` — so a change to any of
them has to land in all three files. `build.ps1` forces UTF-8 on capture (several assertions
compare emoji, which a non-UTF-8 console code page would mangle) and, unlike the Makefile, exits
non-zero when an assertion fails.

**The build *rules* are a deliberate exception to that parity.** The Makefile statically links
libc on Linux (see below); `build.ps1` runs a plain `cargo build --release` and takes only what
`Cargo.toml` gives it. The smoke assertions stay mirrored, the compile step does not. Don't
"fix" the asymmetry by copying the static-link logic to Windows without measuring it there.

When adding an emoji assertion to `build.ps1`, mind the plane: 🔥 and 💾 are astral and need a
surrogate pair (`"$([char]0xD83D)$([char]0xDCBE)"`), while ⏳ (U+23F3) and ⚡ (U+26A1) are BMP and
take a single `[char]`. Getting this wrong yields a needle that silently never matches.

**Dependency:** Rust toolchain (`rustup`). `serde`/`serde_json` are fetched automatically by Cargo from crates.io — no system packages required. On Windows the `x86_64-pc-windows-gnu` host needs no Visual Studio: rustup's `rust-mingw` component ships its own `x86_64-w64-mingw32-gcc.exe` and `ld.exe`.

## Architecture

- **`src/main.rs`** — Single-file Rust program; all logic lives here.
- **`statusline.sh`** — Tiny shell wrapper that invokes the release binary (`target/release/claude_statusline`) from the script's directory. Used as the Claude Code statusline command on Unix. There is no Windows counterpart on purpose: `settings.json` needs an absolute path either way, so Windows points straight at `target\release\claude_statusline.exe`, which also leaves the working directory alone — the `.git/HEAD` read below depends on it.
- **`Makefile` / `build.ps1`** — Build entry points for Unix and Windows respectively. See **Build** above.
- **Static linking on Linux** — the Makefile builds with `RUSTFLAGS="-C target-feature=+crt-static"`, which drops the binary from 81 syscalls to 49 (19 of the 24 `openat`/`mmap`/`mprotect` loader calls disappear) and startup from ~750 µs to ~555 µs, about 26%. That is the *only* build change that moved the number; see the release-profile note under **Code Conventions** for what didn't. Three things make this fiddlier than it looks:
  - **`--target $(TRIPLE)` is mandatory, not cosmetic.** Without it `RUSTFLAGS` also applies to `serde_derive`, and a proc-macro can't be built as a static lib — the build dies with *"cannot produce proc-macro ... does not support these crate types"*. Passing `--target` splits host from target artifacts.
  - **That relocates the output** to `target/$(TRIPLE)/release/`, so the Makefile copies the artifact back to `target/release/`, which is what `statusline.sh` and `settings.json` point at.
  - **Non-Linux takes the plain build, chosen by `uname -s` rather than by trial.** macOS has no static libSystem and rustc *ignores* `crt-static` there instead of failing, so a probe-and-fallback would report success while silently producing an ordinary dynamic binary. The Makefile prints which path it took.
- **Why `target-cpu=native` is not used anywhere** — it resolves through LLVM's `getHostCPUName()`, so it depends on the LLVM inside *that machine's* rustc rather than on upstream knowing the chip; Apple silicon has a history of being misidentified until a specific patch lands. It also makes the binary `SIGILL` on any CPU older than the build host. Against that risk it buys nothing measurable here: this program parses a ~1 KB JSON object and formats ten short strings, so there is no hot loop for SIMD or unrolling to act on.
- **`input.json`** — the manual-check fixture both platforms' Testing sections pipe through the binary. Its numbers are deliberately self-consistent, not arbitrary sample data: 84k input tokens against a 200k `context_window_size` is exactly the 42% it reports, and the 80000/3150 cache split is the 96% hit ratio. It carries no `rate_limits`, so it renders the context and cache halves of line 2 only. Keep it coherent when editing — an incoherent fixture makes a real formatting bug look like bad input.
- Git branch is read directly from `.git/HEAD` (no `git` subprocess). The forward slash is fine on Windows — Win32 accepts it — and `str::lines()` strips the CRLF, so the same code path serves both platforms. The name is capped at `BRANCH_MAX_CHARS` (40) with a trailing `…`: it is the only unbounded field on line 1 and renders *before* `⏳`/`⚡`, so an 80-character branch pushes exactly the segments that prompt a `/clear` off the right edge. The tail is what gets cut, since the head carries the ticket id that identifies the branch at a glance. Truncation counts `chars()`, not bytes — git permits UTF-8 in ref names, and a byte slice landing mid-codepoint panics.
- **Directory basename** comes from `Path::file_name()` rather than a manual split. `workspace.current_dir` is backslash-delimited on Windows, so splitting on `'/'` alone returned the whole path; splitting on both separators unconditionally instead corrupted Unix directories whose *names* contain a backslash (a legal filename character there). `std::path` is compiled per-target and applies the right rule on each — `\` and `/` on Windows, only `/` on Unix — and handles a trailing separator, which the manual split rendered as an empty basename.
- JSON is deserialized with `serde`/`serde_json` into structs with `Option<T>` fields — both a missing field and an explicit `null` become `None` automatically. The distinction matters here: Claude Code omits `rate_limits` and `effort` entirely when they don't apply, but sends `context_window.current_usage` and `used_percentage` as literal `null` before the first API call and again after `/compact`. `Option` covers both without a `#[serde(default)]` anywhere.
- **Burn rate (5h window only)** — `burn_ratio()` returns `used_pct / expected_pct`, where `expected_pct` is the straight-line spend for the elapsed fraction of the window. The result is a multiple of budget: `1.0` is exactly on pace, above that is overspending. The `5h` label turns yellow at ≥1.15x and red at ≥1.75x; the ⏱️ icon becomes 🔥 at ≥1.4x — equivalent to 23/28/35 %/hour. The warn threshold sits above 1.0 on purpose: spending exactly on budget lands at 100% just as the window resets, so warning there would be permanently on and would flicker as the ratio crossed the line between refreshes. Red sits at 1.75x rather than higher because red at ratio `r` is unreachable past `5h / r` elapsed (it would need >100% used), so pushing it up shrinks the span of the window in which red can appear at all.
- **`window_elapsed_secs()`** — shared by `burn_ratio()` and `dry_in_suffix()`. Derives elapsed time as `18000 - (resets_at - now)`, assuming a fixed 5-hour window, and holds all the guards: returns `None` when `resets_at` is missing/past, when remaining time exceeds the window (clock skew), or within the first 5% (15 min), where the average is too noisy to be meaningful. A `None` here means no burn coloring and no projection.
- **`dry_in_suffix()`** — appends `, dry in 1h30m` after the countdown, but only at red (≥1.75x); every other level is unchanged, so line 2 keeps its usual width. Computed as `(100 - used) / used * elapsed` — no days branch, since at ≥1.75x exhaustion is always under 2h51m away. Caveat: it inherits the cumulative-average lag, so after a burst followed by idling it keeps quoting a stale time. Confining it to red limits how often that shows.
- **Cache hit ratio (💾)** — `cache_read / (cache_read + cache_creation)` from `context_window.current_usage`, which is the **most recent response's** usage, not a session total (Claude Code walks messages backwards and returns the first usage it finds). So this is a per-turn number: a prefix invalidation shows up on the very next refresh rather than being averaged away. Bands are inverted against every other indicator here — high is good — so `cache_color()` exists rather than reusing `pct_color()`: plain ≥85%, yellow 60–84%, red <60%. Worth showing at all because a cache *write* token costs roughly 12x a cache *read* token, so the ratio tracks what the turn actually cost.
- **Why the cache indicator has a context floor** — `CACHE_MIN_CONTEXT_PCT` (30%) hides it entirely on a cold start, where the sample is all cache writes by construction and a red 0% would be correct but useless. The guard is on context size rather than on `read > 0` on purpose: that keeps a genuine post-TTL 0% visible, which is the one event the indicator exists to catch. It also goes quiet after `/compact`, where `current_usage` is explicitly `null` — note *null*, not absent, which `Option` handles either way.
- **Session age (⏳) and active share (⚡)** — from `cost`. `total_duration_ms` is real wall clock (`Date.now() - start`), and `/clear` resets it along with the cost, so the age means "time since the last `/clear`" — i.e. how long this context has been accumulating, which is the useful reading. `⚡` is `total_api_duration_ms / total_duration_ms`: a long session with a low active share is a large context held open for nothing and re-sent every turn. `⚡` needs *both* an age past `AGE_WARN_SECS` and a share under `ACTIVITY_WARN_PCT` to color, so it never fires on a session you just opened, and it is hidden entirely under `ACTIVITY_MIN_AGE_SECS` (1h) where the ratio swings meaninglessly.
- **Why 7d has no pace cue** — a straight-line budget assumes uniform spending. That holds within a 5-hour session but not across a week: a weekday-only pattern reads as ~1.4x by Friday while being exactly on track to finish the week. The cue would fire constantly for normal usage, so the 7d display stays a plain 📅 with only its used-% coloring.

## JSON Schema (stdin)

The program parses these fields from the JSON object piped to stdin:

| Path | Type | Used for |
|------|------|----------|
| `model.display_name` | string | Model name in header |
| `effort.level` | string | Reasoning effort shown after model name (optional; `low`/`medium`/`high`/`xhigh`/`max`, each its own color) |
| `workspace.current_dir` | string | Directory basename |
| `context_window.used_percentage` | number | Context % (color-coded); also gates the cache indicator |
| `context_window.current_usage.cache_read_input_tokens` | int | Numerator of the cache hit ratio |
| `context_window.current_usage.cache_creation_input_tokens` | int | Other half of the hit-ratio denominator |
| `cost.total_duration_ms` | int | Session wall clock (color-coded age) |
| `cost.total_api_duration_ms` | int | Time spent waiting on the API; over wall clock gives the ⚡ active share |
| `rate_limits.five_hour.used_percentage` | number | 5h rate limit used % (color-coded; Pro/Max only) |
| `rate_limits.five_hour.resets_at` | int | Unix epoch seconds when 5h window resets (countdown display; also derives elapsed time for the burn-rate cue on the `5h` label) |
| `rate_limits.seven_day.used_percentage` | number | 7d (weekly) rate limit used % (color-coded; Pro/Max only) |
| `rate_limits.seven_day.resets_at` | int | Unix epoch seconds when 7d window resets (countdown display) |

All fields are optional; anything missing — or explicitly `null` — is silently skipped, and the segment it feeds is omitted from the line rather than rendered empty.

## Responding to the indicators

The colors exist to drive a decision, not to report that a number is large. What each one is asking for:

- **`💾` red (<60%)** — the prompt-cache prefix was rebuilt, and that turn's cost is already spent. If it follows an idle gap of roughly an hour, the cache had expired and clearing now costs nothing extra: this is the free moment to `/rename` + `/clear`. If it stays red turn after turn, something keeps invalidating the prefix — mid-session model switches, `/effort` changes, MCP server churn. Do **not** reflex-`/compact`: that re-reads the whole conversation it summarizes, so you pay a second large request on top of the miss you just took. There are no false alarms to rule out — the indicator is suppressed below 30% context and after `/compact`, so red is always real.
- **`⏳` red (≥8h)** — a context that has been accumulating for a full workday. `/rename`, then `/clear`; write a handoff brief first if the work is unfinished. `/resume` later, and take the "resume from summary" offer when it appears.
- **`⚡`** — never red, by design. Yellow (≥4h old *and* <5% active) is the same verdict as `⏳`, just earlier: a parked context held open by nothing.
- **Both red at once** — the unambiguous case. A large context that has just lost its cache, where every further turn re-sends all of it at full write price. Clear immediately.

The through-line: `💾` tells you *when* clearing is free, `⏳`/`⚡` tell you *that* it is overdue.

## Code Conventions

- **Edition:** 2021
- **Functions/variables:** `snake_case`
- **Constants:** `UPPERCASE`
- **Release profile:** `opt-level = 3`, `lto = true`, `strip = true`, `panic = "abort"`, `codegen-units = 1` (see `Cargo.toml`). Tuned for executable speed; build time and binary size are explicitly not constraints. **`opt-level` was measured at exactly zero effect** — `3` and `"s"` both run ~750 µs, well inside round-off — because the program is startup-bound, not compute-bound. It is set to `3` because speed is the stated goal and the setting costs only the two things that don't matter here, but don't mistake it for the thing that made this fast; static linking did that.
- **Benchmarking this program needs care.** It runs in well under a millisecond, and on a `powersave` CPU governor `hyperfine` produced results that varied ~10x for a byte-identical binary purely by position in the run order — an earlier "21% faster" reading was pure ordering artifact. Two methods that hold up: syscall counts via `strace -c` (deterministic, immune to frequency scaling), and alternating A/B blocks pinned to one core with `taskset`, where each pair is adjacent in time so slow drift cancels. Trust those over a single-shot wall-clock number.
- **Non-PIE was measured and deliberately rejected.** `-C relocation-model=static` on top of static linking gives ~555 µs → ~537 µs, about 4%, consistent in 8 of 8 alternating rounds — a real effect, not noise. It is not used, because it disables ASLR for the executable. The gain is ~18 µs on a status line, roughly 700x below the ~13 ms threshold at which a human perceives a visual change, so the trade gives up a hardening default for nothing observable. Recorded with the numbers precisely so this isn't re-derived: measuring a genuine 4% and switching it on is the easy mistake here.
- **Binary size** is now ~1.40 MB statically linked, against 426 KB dynamic. An empty `println!` program on this profile is 288,904 bytes, so the std floor dominates the dynamic build. All figures are toolchain-dependent (rustc 1.96.1, `x86_64-unknown-linux-gnu`) — re-measure rather than trusting them.
- **Dependencies:** kept minimal — `serde` + `serde_json` only; avoid adding new crates without discussing first
