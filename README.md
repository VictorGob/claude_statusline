# Claude Statusline

A fast Rust statusline formatter for [Claude Code](https://claude.com/claude-code). Reads JSON from stdin, outputs a two-line ANSI-colored status display.

```
Opus high | 📁 project | 🌿 main
🎫 42% | ⏱️ 5h: 24%, resets in 2h35m | 📅 7d: 41%, resets in 3d11h
```

**Line 1:** model, reasoning effort (color-coded by level, shown when available), directory, git branch
**Line 2:** context window %, 5-hour and 7-day (weekly) rate limits with countdown — the "resets in" text is a [clickable link](https://claude.ai/settings/usage) in supported terminals (shown only when data is available)

**Burn rate:** each quota is 100% per window, so spending is measured against a straight-line budget — 20%/hour for the 5-hour window, 14.3%/day for the weekly one. Outspend it and the window label turns yellow (≥1x budget) then red (≥1.5x), with the icon becoming 🔥 at ≥1.25x. Adds no width, and stays invisible while you're on pace.

```
🎫 42% | 🔥 5h: 27%, resets in 4h0m | 📅 7d: 20%, resets in 5d0h
```

Both windows are tracked independently — burning through the 5-hour quota doesn't flag the weekly one. The cue is separate from the used-% coloring, which keeps its own thresholds (yellow ≥60%, red ≥90%), so you can tell "used a lot slowly" from "used a little fast".

## Benchmark

```
Time (mean ± σ):   3.1 ms ± 1.0 ms   [User: 1.8 ms, System: 1.2 ms]
Range (min … max): 0.6 ms … 5.0 ms    1000 runs   (hyperfine, cargo build --release, LTO+strip)
```

## Setup

**Dependencies:** Rust toolchain (install via [rustup](https://rustup.rs))

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

## Testing

```bash
make test
cat input.json | ./statusline.sh
```

## License

MIT
