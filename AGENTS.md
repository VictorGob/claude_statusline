# claude_statusline

Rust statusline formatter for Claude Code. Reads JSON from stdin, prints a two-line ANSI display: model, directory, git branch, session age, context usage, prompt-cache hit ratio, 5h/7d rate limits.

## Build

```bash
make          # cargo build --release       (Windows: .\build.ps1)
make clean    # cargo clean                 (.\build.ps1 -Clean)
make test     # build + cargo test + smoke  (.\build.ps1 -Test)
```

`build.ps1` is the Windows equivalent, with the same targets and the same smoke assertions. **Every threshold below lives in three files** — `src/main.rs`, `Makefile`, `build.ps1` — so a change lands in all three. `build.ps1` forces UTF-8 on capture (emoji assertions would otherwise fail on the console code page) and, unlike the Makefile, exits non-zero on failure.

**The build *rules* are a deliberate exception to that parity.** The Makefile statically links libc on Linux; `build.ps1` takes a plain `cargo build --release`. Static linking was measured on Windows and does nothing (0.00%) — `msvcrt.dll` is imported either way — so don't port it. The setting that *does* carry across both platforms is `opt-level` in `Cargo.toml`.

**Static linking on Linux** — `RUSTFLAGS="-C target-feature=+crt-static"`: 81 → 49 syscalls (19 of 24 loader `openat`/`mmap`/`mprotect` calls gone), ~750 µs → ~555 µs startup, ~26%. The only build change that moved the number. Three traps:

- **`--target $(TRIPLE)` is mandatory.** Without it `RUSTFLAGS` reaches `serde_derive`, and a proc-macro can't be a static lib — *"cannot produce proc-macro … does not support these crate types"*.
- **That relocates the output** to `target/$(TRIPLE)/release/`, hence the copy back to `target/release/`, which `statusline.sh` and `settings.json` point at.
- **Non-Linux takes the plain build, chosen by `uname -s`, not by trial.** macOS has no static libSystem and rustc *ignores* `crt-static` rather than failing, so probing would report success while producing a dynamic binary.

**Dependency:** Rust toolchain only — Cargo fetches `serde`/`serde_json`. On Windows `x86_64-pc-windows-gnu` needs no Visual Studio; rustup's `rust-mingw` ships its own linker.

## Testing

Two layers, both run by both entry points. They are complements:

- **Unit tests** (`#[cfg(test)] mod tests` at the foot of `src/main.rs` — there is no `tests/` directory) assert every colour band on **both sides** of its boundary. Smoke suites can only sample a midpoint, so a constant could drift far before they noticed. Unit tests are also deterministic, where smoke derives `resets_at` from the wall clock.
- **Smoke assertions** reach what unit tests cannot: assembled ANSI output, the `.git/HEAD` read (throwaway dirs with a synthetic HEAD), `--version`, the no-stdin blocking case.

Rules, each of which has already cost someone a debugging session:

- **A threshold test must be verified to fail** when its constant moves — nudge it, watch the failure, revert. A boundary test that passes under a changed boundary is worthless.
- **Boundary tests must use literals, not the constants.** `token_color(CONTEXT_WARN_TOKENS)` holds whatever the constant says and pins nothing. Two of the three context steps were unpinned this way before it was caught.
- **Clock-dependent assertions need a tolerance**, never equality — a second can tick between the test computing `now` and the function reading it. Applies to `burn_ratio`, `window_elapsed_secs`, `dry_in_suffix`.
- **On Windows a rapid file restore can leave `cargo` fingerprinting a stale artifact.** "Still failing after revert" may be the incremental build; `rm -rf target/debug` settles it.
- **Emoji needles in `build.ps1` need the right plane.** 🔥 💾 🧊 🎫 🌿 are astral and need a surrogate pair (`"$([char]0xD83D)$([char]0xDCBE)"`); ⏳ (U+23F3) and ⚡ (U+26A1) are BMP and take one `[char]`. Getting this wrong yields a needle that silently never matches.
- **Anchor assertions to the segment.** A bare `grep -q $'\033\['` matches line 1's coloured directory and can never fail.

## Thresholds

| Constant | Value | Effect |
|---|---|---|
| `BURN_WARN_RATIO` / `BURN_FIRE_RATIO` / `BURN_HIGH_RATIO` | 1.15 / 1.4 / 1.75 | `5h` yellow / ⏱️→🔥 / `5h` red + `dry in` (≈23/28/35 %/h) |
| `BURN_MIN_GAP_PCT` | 1.0 pp | absolute lead required *as well as* the ratio |
| `BURN_MIN_ELAPSED_FRACTION` | 0.02 (6 min) | residual floor on the window |
| `CACHE_WARN_RATIO` / `CACHE_HIGH_RATIO` | 0.85 / 0.60 | 💾 plain / yellow / red — **inverted, high is good** |
| `CACHE_REBUILD_TOKENS` | 50k | 🧊 marker; strictly `>`, so the constant names the largest write still a top-up |
| `CONTEXT_WARN` / `HIGH` / `CRITICAL_TOKENS` | 200k / 300k / 500k | 🎫 yellow / red / bold red |
| `AGE_WARN_SECS` / `AGE_HIGH_SECS` | 4h / 8h | ⏳ yellow / red |
| `ACTIVITY_MIN_AGE_SECS` / `ACTIVITY_WARN_PCT` | 1h / 5% | ⚡ hidden below / yellow |
| `BRANCH_MAX_CHARS` | 40 | branch truncation |
| `pct_color()` | 60 / 90 % | yellow / red — **shared by 5h, 7d and the context fallback** |

## Architecture

- **`src/main.rs`** — single file; all logic and all tests.
- **`build.rs`** — captures the commit SHA into `GIT_SHA` for `--version` via `std::process::Command` (no build-dependencies). Falls back to `unknown` on any failure; a version string is never worth failing a build over. Two traps, both silent:
  - **Emitting any `cargo:rerun-if-changed` replaces cargo's default.** Every input must then be listed, or builds bake in a stale SHA. `src/main.rs` and `Cargo.toml` are listed to keep `-dirty` honest. Practical only because this crate has one source file — don't copy it into a larger one.
  - **A commit moves the branch ref, not `.git/HEAD`**, so the resolved ref is watched too — but only via a `Path::exists()` guard, because naming a path that doesn't exist re-runs the script on *every* build, and the ref is absent while packed into `.git/packed-refs`.
- **`--version` / `-V`** — handled **before** the stdin read; from a terminal there is no pipe, so reading first blocks forever. Any other argument falls through and is ignored, so a future Claude Code passing one still renders. The SHA is build provenance, not a release identity. Uses `args_os()`, not `args()`, which **panics** on non-UTF-8 argv — under `panic = "abort"` that costs the whole line. **Deliberately unasserted:** reachable only on Unix, and on Windows argv is UTF-16 where a shell won't pass an unpaired surrogate, so a smoke test could not fail on the platform running it. The suites guard the *blocking* case differently on purpose: the Makefile redirects `</dev/null` so a regression exits non-zero and can never hang; `build.ps1` starts the process with stdin closed and a hard timeout, calling `WaitForExit` **before** `ReadToEnd` — reading first blocks until stdout closes and would hang on exactly the case under test.
- **`statusline.sh`** — wrapper invoking the release binary from the script's directory, forwarding `"$@"` so `./statusline.sh --version` works. Drop the `"$@"` and the flag is swallowed and the wrapper blocks on stdin. Unix only, on purpose: `settings.json` needs an absolute path anyway, so Windows points straight at the `.exe`, which also leaves the working directory alone — the `.git/HEAD` read depends on it.
- **`input.json`** — manual-check fixture. Numbers are deliberately self-consistent: 84k against a 200k `context_window_size` is the 42% it reports, and 80000/3150 is the 96% hit ratio. No `rate_limits`, so it renders only the context and cache halves. Keep it coherent — an incoherent fixture makes a formatting bug look like bad input.
- **Nothing in the render path may panic.** Under `panic = "abort"` a panic costs the *entire* line, a bad trade for one segment. `now_epoch()` returns `Option` rather than unwrapping `duration_since(UNIX_EPOCH)`: a clock set before 1970 drops the countdown and the burn cue, states both call sites already produce for missing data. Deliberately unasserted — a test would have to fake the system clock.
- **JSON via `serde` into `Option<T>` fields**, so a missing field and an explicit `null` both become `None`. The distinction is real: Claude Code *omits* `rate_limits` and `effort`, but sends `current_usage` and `used_percentage` as literal `null` before the first call and after `/compact`. No `#[serde(default)]` anywhere.
- **Directory basename** from `Path::file_name()`, not a manual split. `current_dir` is backslash-delimited on Windows; splitting on `/` alone returned the whole path, and splitting on both corrupted Unix names legally containing a backslash. `std::path` applies the right rule per target and handles a trailing separator.

### Git branch

Read directly from `.git/HEAD`, no subprocess. The forward slash is fine on Windows and `str::lines()` strips CRLF, so one code path serves both. Capped at `BRANCH_MAX_CHARS` with a trailing `…` — it is the only unbounded field on line 1 and renders *before* ⏳/⚡, so a long branch pushes exactly the segments that prompt a `/clear` off the edge. The **tail** is cut; the head carries the ticket id. Truncation counts `chars()`, not bytes — git permits UTF-8 in refs and a byte slice landing mid-codepoint panics.

- **Detached HEAD** — the file holds a raw object id. This used to render empty, going quiet in the state most likely to leave you unsure where you are; a 40-char all-hex line now shows as `🌿 @abc1234`. The `@` marks it a commit rather than a branch named like hex. Slicing 7 bytes is safe only because the all-ASCII-hex check runs first.
- **Worktrees** — `.git` is a *file* holding a `gitdir:` pointer, so the read fails with ENOTDIR (the `Err` arm, not a parse arm). `worktree_segment()` falls back to `workspace.git_worktree` rather than following the pointer, since the payload is parsed anyway. It names the *worktree*, not the branch in it. Submodules share the shape but get no such field, so they stay silent. **The "gitdir pointer" smoke case does not cover this** — it writes `gitdir:` into `HEAD` inside a real `.git` directory, exercising a parse arm; the real shape needs `.git` itself to be a file.

### Indicators

- **Burn rate (5h only)** — `burn_ratio()` = `used_pct / expected_pct`, where expected is straight-line spend for the elapsed fraction. `1.0` is on pace. The warn threshold sits above 1.0 because spending exactly on budget lands at 100% as the window resets; warning there would be permanently on and would flicker between refreshes. Red is 1.75x rather than higher because red at ratio `r` is unreachable past `5h / r` elapsed, so raising it shrinks the span in which red can appear at all.
- **The gap gate** — a multiple alone does not warn; `burn_ratio()` also requires `used_pct - expected_pct >= BURN_MIN_GAP_PCT`. The quotient divides by a near-zero denominator early on, where one point of noise swings it ~0.6x; the *difference* stays sane exactly there. Gating on both dropped the blanket blackout from 15 min to 6. A band opens at `expected_pct >= 1.0 / (r - 1)` — 🔥 at 7m30s, yellow at 20 min — except **whichever guard is later wins**, so red is held to 6 min by the elapsed floor rather than the 4 min the gap alone allows (verified against the binary). Binds only early: an hour in, 1.15x already carries 3 points of lead. Returns `None` when on or under budget, the same "stay quiet" every caller reads. Widening to 2pp is not free — it pushes yellow to 40 min.
- **`window_elapsed_secs()`** — shared by `burn_ratio()` and `dry_in_suffix()`. Elapsed = `18000 - (resets_at - now)`, assuming a fixed 5h window. Returns `None` on missing/past `resets_at`, on remaining > window (clock skew), or inside the opening 6 min — now a residual guard only, against a near-zero denominator and against projecting off a two-minute sample.
- **`dry_in_suffix()`** — `, dry in 1h30m`, only at red, so line 2 keeps its usual width elsewhere. `(100 - used) / used * elapsed`; no days branch, since at ≥1.75x exhaustion is under 2h51m away. It inherits the cumulative-average lag, so after a burst then idling it quotes a stale time — confining it to red limits how often that shows.
- **Cache hit ratio (💾)** — `cache_read / (cache_read + cache_creation)` from `current_usage`, which is the **most recent response's** usage, not a session total. So it is per-turn: an invalidation shows on the very next refresh rather than being averaged away. `cache_color()` exists rather than reusing `pct_color()` because the bands are inverted. Worth showing because a write token costs ~12x a read token.
- **No context floor on 💾, deliberately.** It used to carry `CACHE_MIN_CONTEXT_PCT` (30%), reasoning that a cold start is all writes and cheap to redo. Measurement inverted that: cold-start re-caches are the most expensive class of turn, and the floor hid exactly them — a post-TTL return at 300k reads as "low context" for one refresh. Still quiet after `/compact`, where `current_usage` is *null*.
- **Rebuild marker (🧊)** — appends the size written, e.g. `💾 4% 🧊210k`. The ratio cannot carry this: 20% off a 5k top-up and 20% off a 300k rebuild render identically, and only one is worth clearing over.
- **Context size (🎫)** — `🎫 42% (84k)` from `total_input_tokens` (= `input + cache_creation + cache_read` of the last response, i.e. what the turn billed). The percentage says how much window is left; the token count says what a turn costs, and on a large window those stop being the same question. Bare `🎫 42%` when the field is absent.
- **The context segment takes the louder of two ladders.** `token_color()` runs the size ladder; `pct_color()` runs the percentage bands and **must not be edited** — it is shared with the quota bars. `context_color()` ranks both through `severity()` and returns the more severe.
  - **Taking the maximum, not letting size win outright, is load-bearing.** 184k of a 200k window is 92% full and under the warn step, so size-wins renders a nearly-full window *plain*. There is a unit test on that case.
  - **The ladder is absolute, never a fraction of the window.** `context_window_size` does not bound a turn's cost — the largest measured was 659k — and on a 1M-window model 300k is 30%, which every percentage band calls healthy.
  - **Three steps, not one**, because a single alarm is a cliff whose first utterance is that you are already too late. The warn step also keeps the ladder alive on a 200k-window model, where 300k is unreachable.
  - **Measured, not picked** — 37% / 23% / ~9% of turns over 5,384 requests and 1,043M billed input tokens, the turns above 300k carrying half of all billed input. 150k is deliberately *not* the warn step: it is the median turn (146k), so a line there fires on half of everything. The 500k step is read off the end of that table rather than out of it — the softest of the three.
- **Session age (⏳) and active share (⚡)** — from `cost`. `total_duration_ms` is wall clock and `/clear` resets it, so age means "time since the last `/clear`" — how long this context has been accumulating. `⚡` is `total_api_duration_ms / total_duration_ms`; a long session with a low share is a large context held open for nothing. `⚡` needs *both* an age past `AGE_WARN_SECS` and a share under `ACTIVITY_WARN_PCT`, so it never fires on a session you just opened.
- **Why 7d has no pace cue** — a straight-line budget assumes uniform spending. That holds within a session, not across a week: a weekday-only pattern reads ~1.4x by Friday while exactly on track. The cue would fire constantly, so 7d stays a plain 📅 with used-% colouring only.
- **Recommended: `refreshInterval` on the `statusLine` object** (seconds, min 1; 120 is sensible). Otherwise Claude Code re-runs on events only, and the countdown, `dry_in_suffix()` and `burn_ratio()` all read `now_epoch()` at render time, so they freeze between messages. Idling bites: spend stops while elapsed grows, so the true ratio *decays* while a frozen line still shows a 🔥 reality already cleared. Under ~30s buys nothing — `format_reset_suffix()` renders whole minutes. A recommendation, not a repo default; it is the reader's own config.

## JSON Schema (stdin)

| Path | Type | Used for |
|------|------|----------|
| `model.display_name` | string | Model name in header |
| `effort.level` | string | Reasoning effort after the model name (`low`/`medium`/`high`/`xhigh`/`max`, each its own colour) |
| `workspace.current_dir` | string | Directory basename |
| `workspace.git_worktree` | string | Branch fallback in a worktree, where `.git/HEAD` is unreadable |
| `context_window.used_percentage` | number | Context %, coloured by `context_color()` |
| `context_window.total_input_tokens` | int | Absolute size shown beside the % (`🎫 42% (84k)`); what the size ladder tests |
| `context_window.current_usage.cache_read_input_tokens` | int | Numerator of the hit ratio |
| `context_window.current_usage.cache_creation_input_tokens` | int | Other half of the denominator; also drives 🧊 |
| `cost.total_duration_ms` | int | Session wall clock (⏳) |
| `cost.total_api_duration_ms` | int | API wait; over wall clock gives ⚡ |
| `rate_limits.{five_hour,seven_day}.used_percentage` | number | Rate limit used % (Pro/Max only) |
| `rate_limits.{five_hour,seven_day}.resets_at` | int | Epoch seconds of reset; 5h also derives elapsed time for the burn cue |

All fields are optional; anything missing or `null` is skipped and its segment omitted rather than rendered empty.

## Responding to the indicators

The colours drive a decision, not report that a number is large.

- **💾 red (<60%)** — the prefix was rebuilt; that cost is spent. After an idle gap of ~an hour the cache had expired, so clearing now costs nothing extra — the free moment to `/rename` + `/clear`. Red turn after turn means something keeps invalidating it: model switches, `/effort` changes, MCP churn. Do **not** reflex-`/compact` — it re-reads the whole conversation it summarizes, a second large request on top of the miss. One false alarm to rule out: on the first turns the prefix has to be built, so red 💾 with a small 🧊 is just the session starting.
- **🧊 with a large number** — this turn re-sent that much at write price. The cost is sunk when you see it, so it is diagnostic, not a do-this-now: the live question is only whether you still need the context. What it teaches is to clear *before* stepping away for an hour, not after coming back.
- **🎫 yellow / red / bold red** — the context reached 200k / 300k / 500k, so every further turn re-sends at least that much however small the question. Yellow is the approach cue: don't open new work here. Red is where the brief-and-clear rule applies. The same colours can arrive from the percentage instead, when a smaller window is nearly full — the same verdict by the other route.
- **⏳ red (≥8h)** — a full workday of accumulation. `/rename`, then `/clear`; write a handoff brief first if the work is unfinished, and take the "resume from summary" offer on `/resume`.
- **⚡** — never red by design. Yellow is the ⏳ verdict arriving earlier: a parked context held open by nothing.
- **🎫 red with a large 🧊** — the unambiguous case. A large context that just lost its cache, with nothing left worth preserving. Clear immediately.

The through-line: 💾/🧊 say when clearing is free and what the last miss cost, 🎫 says what each further turn costs, ⏳/⚡ say it is overdue.

## Code Conventions

- **Edition 2021**, `snake_case` functions/variables, `UPPERCASE` constants.
- **Dependencies kept minimal** — `serde` + `serde_json` only. Discuss before adding.
- **Release profile:** `opt-level = "z"`, `lto = true`, `strip = true`, `panic = "abort"`, `codegen-units = 1`. Tuned for executable speed; build time is not a constraint. **`opt-level = "z"` is set *for speed*, not size** — reverting it to `3` on the assumption that more optimization is faster is the mistake this note prevents. The program is loader-bound: on Windows the image is mapped every spawn, so the smallest binary starts fastest (375,808 → 339,456 bytes, ~1.7% faster, 16/16 rounds). On Linux `opt-level` measured at exactly zero effect, so `"z"` is neutral there and wins on Windows.

### Benchmarking

This program runs in well under a millisecond, and naive measurement lies.

- **`hyperfine` is unusable here.** On a `powersave` governor it varied ~10x for a byte-identical binary purely by run order; an early "21% faster" was pure ordering artifact. Use `strace -c` syscall counts (deterministic, immune to frequency scaling) or alternating A/B blocks pinned with `taskset`, where each pair is adjacent in time so drift cancels.
- **Always run a null test, and read the win *rate*, not the mean.** Two byte-identical copies on Windows showed a systematic **0.65% bias toward the first slot, winning 8 of 10 rounds** — enough to manufacture a plausible 1% improvement from nothing. A sub-1% mean with a lopsided win count is not evidence. The `opt-level` result was trustworthy because it *reversed* that bias, winning 8/10 from the disfavoured slot.
- **Two Windows traps that produced false results here:** comparing binaries across volumes invented a bogus 5.2% from filesystem difference alone — keep both candidates in one directory; and in PowerShell variable names are case-insensitive, so a local `$a` silently overwrites an `$A` parameter, while `$Input` cannot be a parameter name at all.
- **Windows is ~96% process-creation overhead, which bounds everything.** Empty `fn main() {}` spawns in ~4.41 ms, the full statusline in ~4.61 ms — so all of stdin, JSON, `.git/HEAD`, format and print fit in **~200 µs, 4.4% of a launch**. Measure with 400–500 spawns per block via `cmd /c "for /L ..."`; a .NET `Process` harness costs ~14.8 ms/iteration and buries the signal.

### Measured and rejected — do not retry without new evidence

| Change | Measured | Why not |
|---|---|---|
| `+crt-static` on Windows | 0.00%, 2/6 rounds | `msvcrt.dll` imported either way; `KERNEL32`/`ntdll`/API-set stub mapped into every process — no loader work to remove |
| Hand-rolled JSON parser | whole parse is ~0.87%, within noise | cannot recover even 40 µs; real correctness risk for nothing |
| `Stdin::lock()` + `read_to_end`, or the raw OS handle | 0.15% / −0.30% | the ~130 µs charged to "reading stdin" is the pipe, not Rust's buffering |
| Two `println!` → one `write_all` | −0.45%, faster in 3/8 | — |
| `-C relocation-model=static` (non-PIE, Linux) | ~555 → ~537 µs, ~4%, 8/8 rounds — **real** | disables ASLR for ~18 µs, ~700x below the ~13 ms a human can perceive. Measuring a genuine 4% and switching it on is the easy mistake here |
| `target-cpu=native` | not measured | resolves via LLVM `getHostCPUName()`, which has misidentified Apple silicon; `SIGILL` on any CPU older than the build host; no hot loop to act on |

### Binary size

~1.40 MB static on Linux vs 426 KB dynamic (rustc 1.96.1); 341,504 bytes on Windows (rustc 1.97.1, gnu). **The std floor dominates:** an empty `fn main() {}` on this profile is 240,128 bytes, so ~71% is there before a line of ours — only ~100 KB is actually this program. Compare like with like: the same empty program is 252,416 bytes at `opt-level = 3`, and an earlier revision of this note wrongly measured the floor at `3` while quoting it against a `"z"` binary.

Size is **not** a free variable despite "size is not a constraint": on Windows it is the mechanism behind the `opt-level` win, so shrinking the image is a speed change. All figures are toolchain-dependent and have moved twice — **re-measure rather than trusting them.**

**What the feature work cost.** `--version` plus the panic fixes and detached-HEAD display came to **+512 bytes net**. The instructive part: `env::args()` cost 5,632 bytes and `args_os()` handed 2,560 back, because the UTF-8 validation machinery went with it. That 5,632 measured at 0.00% with a 5/8 coin-flip win rate — a useful scale check, since 52 KB bought ~1.9%. Don't micro-optimise size at this scale; the measurement cannot see it.
