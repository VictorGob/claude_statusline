# Claude Statusline

A fast Rust statusline formatter for [Claude Code](https://claude.com/claude-code). Reads JSON from stdin, outputs a two-line ANSI-colored status display.

```
Opus high | 📁 project | 🌿 main | ⏳ 2h15m ⚡16%
🎫 42% | 💾 96% | ⏱️ 5h: 24%, resets in 2h35m | 📅 7d: 41%, resets in 3d11h
```

**Line 1:** model, reasoning effort (color-coded by level, shown when available), directory, git branch, session age and active share
**Line 2:** context window %, cache hit ratio, 5-hour and 7-day (weekly) rate limits with countdown — the "resets in" text is a [clickable link](https://claude.ai/settings/usage) in supported terminals (shown only when data is available)

**Burn rate:** the 5-hour quota is 100%, so 20%/hour is a sustainable pace. Overspend it and the `5h` label turns yellow (≥23%/h) then red (≥35%/h), with the ⏱️ icon becoming 🔥 at ≥28%/h. Stays invisible while you're on pace.

Warnings start at 23%/h rather than 20%/h so that spending exactly on budget — which lands at 100% right as the window resets — doesn't sit permanently yellow.

```
🎫 42% | 🔥 5h: 30%, resets in 4h0m | 📅 7d: 20%, resets in 5d0h
```

At red only, a projection of when you'll run out is appended — the one level where knowing your remaining runway is worth the extra width:

```
🎫 42% | 🔥 5h: 40%, resets in 4h0m, dry in 1h30m | 📅 7d: 20%, resets in 5d0h
```

The cue is separate from the used-% coloring, which keeps its own thresholds (yellow ≥60%, red ≥90%), so you can tell "used a lot slowly" from "used a little fast".

The weekly window deliberately has no pace cue: a straight-line budget assumes uniform spending, which doesn't hold across a week. A weekday-only pattern would read as 1.4x by Friday while being exactly on track.

**Cache hit ratio:** `💾` is the share of the last turn's context that was re-read from the prompt cache rather than written into it. A cache write costs roughly 12x a cache read, so this tracks what the turn actually cost — at 96% you re-send a large context for almost nothing, at 20% you rebuild most of it at full price. It collapses when the one-hour cache lifetime expires, or when a model or settings change invalidates the prefix. Plain at ≥85%, yellow at 60–84%, red below 60%.

It stays hidden below 30% context and immediately after a `/compact`. A cold start is all cache writes by definition, so an ungated indicator would sit red at the top of every session — and a warning that's always on is one you stop reading.

**Session age:** `⏳` is wall-clock time since the session started or was last `/clear`ed — the window over which context has been accumulating. `⚡` is the fraction of it actually spent waiting on the model.

```
Opus high | 📁 project | 🌿 main | ⏳ 6h30m ⚡3%
```

Six and a half hours holding a large context, of which twelve minutes was real work. Age turns yellow at 4h and red at 8h; `⚡` only warns when the session is both long *and* mostly idle, so it stays quiet on one you just opened, and is hidden entirely under an hour where the ratio means nothing.

## When something turns red

The colors are there to prompt a decision, not to tell you a number got big.

**`💾` red** — the cache prefix was rebuilt and that turn's cost is already spent. If it followed an idle gap of about an hour, the cache had simply expired, which means clearing now costs nothing extra — the free moment to `/rename` and `/clear`. If it stays red turn after turn, something keeps invalidating the prefix: mid-session model switches, `/effort` changes, MCP servers coming and going.

Resist the urge to `/compact` here. Compaction re-reads the entire conversation it summarizes, so you'd pay a second large request on top of the miss you just took.

**`⏳` red** — eight hours of accumulated context. `/rename`, then `/clear`, writing a handoff brief first if the work isn't finished. Come back with `/resume`, and take the "resume from summary" offer if it appears.

**`⚡`** never goes red. Yellow means the session is both long and mostly idle — the same verdict as `⏳`, arriving earlier.

**Both red together** is the one that isn't a judgment call: a large context that just lost its cache, where every further turn re-sends all of it at full price. Clear it.

Put simply — `💾` tells you when clearing is free, `⏳` tells you it's overdue.

## Benchmark

On Linux the build links libc statically, which removes the dynamic loader from every spawn:

```
                syscalls   startup
dynamic libc          81     ~750 µs
static libc           49     ~555 µs     (~26% faster)
```

Measured as alternating 400-run blocks pinned to one core, mean of 6 rounds. Syscall counts are
from `strace -c` and are the more trustworthy figure — they're deterministic, while sub-millisecond
wall-clock on a scaling CPU is not. `hyperfine` was tried first and gave results varying ~10x for a
byte-identical binary depending on run order, so don't reach for it here.

`opt-level` made no measurable difference either way; `3` and `"s"` both land at ~750 µs. This
program is startup-bound, not compute-bound — there's no hot loop for the optimizer to reach.

## Setup

**Dependencies:** Rust toolchain (install via [rustup](https://rustup.rs))

### Linux / macOS

```bash
make
```

On Linux this statically links libc and prints `Built: static (libc linked in)`. If your system has
no static libc it falls back automatically and reports `Built: default (dynamic libc)` — the binary
works either way, just with the loader back in the startup path. macOS always takes the default
build, since Apple ships no static libSystem.

Add to `~/.claude/settings.json`:
```json
{
  "statusLine": {
    "type": "command",
    "command": "/absolute/path/to/claude_statusline/statusline.sh",
    "padding": 0
  }
}
```

### Windows

`build.ps1` is the PowerShell equivalent of the Makefile, with the same three targets:

```powershell
.\build.ps1           # build
.\build.ps1 -Clean    # clean
.\build.ps1 -Test     # build + smoke tests
```

Point `settings.json` straight at the binary — `statusline.sh` is bash-only, and invoking the
executable directly keeps the working directory that the git branch lookup relies on:

```json
{
  "statusLine": {
    "type": "command",
    "command": "C:/path/to/claude_statusline/target/release/claude_statusline.exe",
    "padding": 0
  }
}
```

Either Rust toolchain works. `x86_64-pc-windows-gnu` needs no Visual Studio — rustup's
`rust-mingw` component bundles its own linker, so nothing else has to be installed.

## Testing

```bash
make test                  # Linux / macOS
cat input.json | ./statusline.sh
```

```powershell
.\build.ps1 -Test          # Windows
Get-Content input.json | .\target\release\claude_statusline.exe
```

## License

MIT
