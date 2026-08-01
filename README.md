# Claude Statusline

A fast Rust statusline formatter for [Claude Code](https://claude.com/claude-code). Reads JSON from stdin, outputs a two-line ANSI-colored status display.

```
Opus high | 📁 project | 🌿 main
🎫 42% | ⏱️ 5h: 24%, resets in 2h35m | 📅 7d: 41%, resets in 3d11h
```

**Line 1:** model, reasoning effort (color-coded by level, shown when available), directory, git branch
**Line 2:** context window %, 5-hour and 7-day (weekly) rate limits with countdown — the "resets in" text is a [clickable link](https://claude.ai/settings/usage) in supported terminals (shown only when data is available)

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

## Benchmark

```
Time (mean ± σ):   3.1 ms ± 1.0 ms   [User: 1.8 ms, System: 1.2 ms]
Range (min … max): 0.6 ms … 5.0 ms    1000 runs   (hyperfine, cargo build --release, LTO+strip)
```

## Setup

**Dependencies:** Rust toolchain (install via [rustup](https://rustup.rs))

### Linux / macOS

```bash
make
```

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
