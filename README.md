# Claude Statusline

A fast C statusline formatter for [Claude Code](https://claude.com/claude-code). Reads JSON from stdin, outputs a two-line ANSI-colored status display.

```
Opus | 📁 project | 🌿 main
🎫 42% | ⏱️ 5h: 24%, resets in 2h35m | 📅 7d: 41%, resets in 3d11h
```

**Line 1:** model, directory, git branch
**Line 2:** context window %, 5-hour and 7-day (weekly) rate limits with countdown — the "resets in" text is a [clickable link](https://claude.ai/settings/usage) in supported terminals (shown only when data is available)

## Benchmark

```
Time (mean ± σ):   3.0 ms ± 0.8 ms   [User: 1.9 ms, System: 1.0 ms]
Range (min … max): 0.8 ms … 4.4 ms    1000 runs   (hyperfine, -O2 -s)
```

## Setup

**Dependencies:** json-c and pkg-config (Ubuntu/Debian: `sudo apt-get install libjson-c-dev pkg-config`, macOS: `brew install json-c pkg-config`)

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
