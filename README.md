# Claude Statusline

A fast Rust statusline formatter for [Claude Code](https://claude.com/claude-code). Reads JSON from stdin, outputs a two-line ANSI-colored status display.

```
Opus high | 📁 project | 🌿 main
🎫 42% | ⏱️ 5h: 24%, resets in 2h35m | 📅 7d: 41%, resets in 3d11h
```

**Line 1:** model, reasoning effort (color-coded by level, shown when available), directory, git branch
**Line 2:** context window %, 5-hour and 7-day (weekly) rate limits with countdown — the "resets in" text is a [clickable link](https://claude.ai/settings/usage) in supported terminals (shown only when data is available)

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
