# Claude Statusline

A fast Rust statusline formatter for [Claude Code](https://claude.com/claude-code). Reads JSON from stdin, outputs a two-line ANSI-colored status display.

```
Opus high | 📁 project | 🌿 main | ⏳ 2h15m ⚡16%
🎫 42% (84k) | 💾 96% | ⏱️ 5h: 24%, resets in 2h35m | 📅 7d: 41%, resets in 3d11h
```

**Line 1:** model, reasoning effort (color-coded, when available), directory, git branch, session age and active share
**Line 2:** context window % and size, cache hit ratio, 5-hour and 7-day rate limits with countdown — the "resets in" text is a [clickable link](https://claude.ai/settings/usage) in supported terminals

Every segment is omitted rather than rendered empty when its data is absent.

## Git branch

Read straight from `.git/HEAD` — no `git` subprocess. The name is cut to 40 characters with a trailing `…`; it's the one field with no natural bound, and it sits ahead of the session indicators, so a long ticket-style branch would otherwise push `⏳` and `⚡` off a narrow terminal. The tail goes, since the head carries the ticket id:

```
🌿 feature/PROJ-1482/limit-git-branch-leng…
```

On a detached HEAD there's no branch to show, so it falls back to the short commit id rather than going blank — which would leave the line quietest exactly when you're least sure where you are. The `@` marks it a commit rather than a branch named like hex:

```
🌿 @8d879d1
```

In a git worktree `.git` is a file holding a pointer, so no branch is readable; the worktree's own name is shown instead, from the payload. Submodules have the same shape but no such field, so there the branch is omitted.

## Context size

`🎫` shows the percentage of the window used *and* the tokens behind it.

The two answer different questions. The percentage tells you how much room is left; the token count tells you what a turn now costs, because the whole context is re-sent every turn. Ask a one-line question in a 300k session and you pay 300k for it.

So the segment is coloured by **two ladders, and shows the louder of them**:

```
🎫 30% (199k)      plain      under the first step
🎫 30% (200k)      yellow     getting large
🎫 30% (300k)      red        write a brief and clear
🎫 50% (500k)      bold red   this is extreme
```

Every one of those is a *size* verdict on a window with plenty of room left — 300k is 30% of a 1M window, which a percentage rule would call perfectly healthy. That's the point: windows range from 200k to 1M, and the largest single turn behind these numbers was 659k, so no fraction of the window expresses it.

The percentage ladder runs alongside, and sometimes wins:

```
🎫 92% (184k)      red        under the first size step, but the window is nearly full
```

That case is why it's the louder of the two rather than size alone — otherwise a nearly-full small window would render plain. With no token count in the payload, the bare `🎫 42%` renders on the plain 60/90 bands.

The steps come from measured usage rather than taste: over a week of 5,384 requests, 37% / 23% / ~9% of turns sat above 200k / 300k / 500k, and the turns above 300k carried half of all billed input. 150k is deliberately *not* the first step — it's the *median* turn, so a line there fires on half of everything and tells you nothing you didn't know.

## Cache hit ratio

`💾` is the share of the last turn's context re-read from the prompt cache rather than written into it. A cache write costs roughly 12x a cache read, so this tracks what the turn actually cost — at 96% you re-send a large context for almost nothing, at 20% you rebuild most of it at full price. It collapses when the one-hour cache lifetime expires, or when a model or settings change invalidates the prefix. Plain at ≥85%, yellow 60–84%, red below 60%.

It shows from the first turn, and goes quiet only after a `/compact`, where the payload reports no usage at all.

**Rebuild marker.** A ratio is scale-free, so `💾 20%` looks identical whether 8k or 240k was rebuilt — and only one of those is worth acting on. When a turn writes more than 50k into the cache, `🧊` follows the ratio with the size written:

```
💾 4% 🧊210k
```

That turn re-sent 210k at write price. It appears on the first turns of a session (the prefix has to be built once — normal), after an idle gap longer than the cache lifetime, or repeatedly when something keeps invalidating the prefix. It also catches what the ratio misses — a healthy-looking 77% hit rate that still paid for 60k of writes:

```
💾 77% 🧊60k
```

## Rate limits

The 5-hour quota is 100%, so 20%/hour is a sustainable pace. Overspend it and the `5h` label turns yellow (≥23%/h) then red (≥35%/h), with `⏱️` becoming `🔥` at ≥28%/h. Invisible while you're on pace.

```
🎫 42% (84k) | 🔥 5h: 30%, resets in 4h0m | 📅 7d: 20%, resets in 5d0h
```

Warnings start at 23%/h rather than 20%/h so that spending exactly on budget — which lands at 100% right as the window resets — doesn't sit permanently yellow. The rate alone isn't enough either: you also have to be at least 1 percentage point ahead of budget. Early on the budget-so-far is near zero, so a single request four minutes in divides out to 3x without meaning anything. Requiring both lets the cue work from 6 minutes in rather than staying blind for 15.

At red only, a projection of when you'll run out is appended — the one level where the remaining runway is worth the extra width:

```
🎫 42% (84k) | 🔥 5h: 40%, resets in 4h0m, dry in 1h30m | 📅 7d: 20%, resets in 5d0h
```

The pace cue is separate from the used-% coloring, which keeps its own thresholds (yellow ≥60%, red ≥90%), so you can tell "used a lot slowly" from "used a little fast".

The weekly window deliberately has no pace cue: a straight-line budget assumes uniform spending, which doesn't hold across a week. A weekday-only pattern would read as 1.4x by Friday while being exactly on track.

## Session age

`⏳` is wall-clock time since the session started or was last `/clear`ed — the window over which context has been accumulating. `⚡` is the fraction of it actually spent waiting on the model.

```
Opus high | 📁 project | 🌿 main | ⏳ 6h30m ⚡3%
```

Six and a half hours holding a large context, of which twelve minutes was real work. Age turns yellow at 4h and red at 8h. `⚡` only warns when the session is both long *and* mostly idle, so it stays quiet on one you just opened, and is hidden entirely under an hour where the ratio means nothing.

## When something turns red

The colors are there to prompt a decision, not to tell you a number got big.

**`🎫` yellow, then red** — yellow at 200k is the approach cue: the context is now large enough that every turn costs real money, so don't open a new thread of work in it. Red at 300k is where the brief-and-clear rule applies — finish what you're on, write a brief, then `/rename` and `/clear`. Bold red at 500k isn't a judgment call. The same colours can arrive from the percentage when a smaller window is nearly full, which is the same verdict by the other route.

**`💾` red** — the cache prefix was rebuilt and that turn's cost is already spent. If it followed an idle gap of about an hour, the cache had simply expired, which means clearing now costs nothing extra — the free moment to `/rename` and `/clear`. If it stays red turn after turn, something keeps invalidating the prefix: mid-session model switches, `/effort` changes, MCP servers coming and going.

Resist the urge to `/compact` here. Compaction re-reads the entire conversation it summarizes, so you'd pay a second large request on top of the miss you just took.

**`🧊` with a large number** — mostly diagnostic, and the one indicator that is *not* a "do this now". The cost is sunk by the time you see it, and you've just bought a fresh cache, so clearing on the spot throws away what you paid for. The only live question is whether you still need the context. What it's really teaching is to clear *before* stepping away for an hour, not after coming back — by the time the `🧊` appears, that decision has already passed.

**`⏳` red** — eight hours of accumulated context. `/rename`, then `/clear`, writing a handoff brief first if the work isn't finished. Come back with `/resume`, and take the "resume from summary" offer if it appears.

**`⚡`** never goes red. Yellow means the session is both long and mostly idle — the same verdict as `⏳`, arriving earlier.

**`🎫` red with a large `🧊`** is the pair that isn't a judgment call: a large context that just lost its cache, where every further turn re-sends all of it at full price and there's nothing left worth preserving. Clear it.

Put simply — `🎫` tells you what each further turn costs, `💾` and `🧊` tell you when clearing is free and what the last miss cost, and `⏳` tells you it's overdue.

## Benchmark

On Linux the build links libc statically, which removes the dynamic loader from every spawn:

```
                syscalls   startup
dynamic libc          81     ~750 µs
static libc           49     ~555 µs     (~26% faster)
```

Measured as alternating 400-run blocks pinned to one core, mean of 6 rounds. Syscall counts from `strace -c` are the more trustworthy figure — they're deterministic, while sub-millisecond wall-clock on a scaling CPU is not. `hyperfine` gave results varying ~10x for a byte-identical binary depending on run order, so don't reach for it here.

On Linux `opt-level` made no measurable difference; `3` and `"s"` both land at ~750 µs. This program is startup-bound, not compute-bound.

**Windows** has no equivalent win available, because there's almost nothing left to win:

```
                        per spawn
empty `fn main() {}`      4.41 ms
full statusline           4.61 ms
```

**About 96% of a launch is `CreateProcess`.** Everything the program does — read stdin, parse the JSON, read `.git/HEAD`, format, print — fits in the remaining ~200 µs, and that is the entire budget any change competes for.

So the build ships `opt-level = "z"`, and that's a *speed* setting here rather than a size one: the image is mapped on every spawn, so the smallest binary starts fastest. It measures ~1.7% faster than `opt-level = 3` and is neutral on Linux. Static linking, which is what actually made the Linux build fast, has no counterpart — `msvcrt.dll` is imported either way.

Anything that sounds like it should help here probably doesn't; `AGENTS.md` lists what was tried and rejected, with the numbers.

## Setup

**Dependencies:** Rust toolchain ([rustup](https://rustup.rs)). `git` is used at *build* time to stamp the commit id into `--version`; without it the build still succeeds and reports `(unknown)`. The program never shells out to git — it reads `.git/HEAD` directly.

### Linux / macOS

```bash
make
```

On Linux this statically links libc and prints `Built: static (libc linked in)`. Without a static libc it falls back automatically and reports `Built: default (dynamic libc)` — the binary works either way, just with the loader back in the startup path. macOS always takes the default build, since Apple ships no static libSystem.

Add to `~/.claude/settings.json`:
```json
{
  "statusLine": {
    "type": "command",
    "command": "/absolute/path/to/claude_statusline/statusline.sh",
    "padding": 0,
    "refreshInterval": 120
  }
}
```

`refreshInterval` (seconds) is worth setting. Without it Claude Code re-runs the command on events only, so the countdown, `dry in`, and burn cue — all computed from the clock — freeze between messages. That bites while idle: your spend stops but time doesn't, so the burn rate is quietly falling while a frozen line still shows the `🔥`. Under ~30s buys nothing; the countdown renders whole minutes.

### Windows

`build.ps1` is the PowerShell equivalent of the Makefile, with the same three targets:

```powershell
.\build.ps1           # build
.\build.ps1 -Clean    # clean
.\build.ps1 -Test     # build + cargo test + smoke tests
```

Point `settings.json` straight at the binary — `statusline.sh` is bash-only, and invoking the executable directly keeps the working directory that the git branch lookup relies on:

```json
{
  "statusLine": {
    "type": "command",
    "command": "C:/path/to/claude_statusline/target/release/claude_statusline.exe",
    "padding": 0
  }
}
```

Either Rust toolchain works. `x86_64-pc-windows-gnu` needs no Visual Studio — rustup's `rust-mingw` component bundles its own linker.

## Version

```console
$ claude_statusline --version
claude_statusline 0.2.0 (8d879d1)
```

`-V` is an alias. The SHA is the commit checked out **when the binary was built**, which is what tells you whether the statusline you're running matches the code you have — the tool is built locally, so a `git pull` and a rebuild move it forward on their own. Two things it tells you rather than hides:

```
claude_statusline 0.2.0 (8d879d1-dirty)   built from a tree with uncommitted changes
claude_statusline 0.2.0 (unknown)         built outside a git checkout, or without git
```

Every other argument is ignored and the statusline renders as normal, so nothing breaks if Claude Code ever passes one. On Unix the wrapper forwards arguments, so `./statusline.sh --version` works the same way.

## Testing

```bash
make test                  # Linux / macOS
cat input.json | ./statusline.sh
```

```powershell
.\build.ps1 -Test          # Windows
Get-Content input.json | .\target\release\claude_statusline.exe
```

Both entry points run the same two layers. `cargo test` covers the threshold and formatting logic — each colour band is asserted on *both* sides of its boundary, since a test at a comfortable midpoint passes just as happily with the constant moved. The smoke assertions then run the real binary end to end, checking the ANSI output, the `.git/HEAD` read, and `--version`, which unit tests can't reach.

`cargo test` alone is the fast loop while changing thresholds — no release build, no process per case.

## License

MIT
