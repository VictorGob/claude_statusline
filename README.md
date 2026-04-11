# Claude Statusline

A fast C statusline formatter for [Claude Code](https://claude.com/claude-code). Reads JSON from stdin, outputs a two-line ANSI-colored status display.

```
[Opus] 📁 project | 🌿 main | 🏷️ my-session
🎫 42% | 🔤 50k in / 12k out | ⏱️ 5h: 24%, resets in 2h35m
```

**Line 1:** model, directory, git branch, session name (if set via `--name` or `/rename`)
**Line 2:** context window %, token counts, 5-hour rate limit with countdown — the "resets in" text is a [clickable link](https://claude.ai/settings/usage) in supported terminals (shown only when data is available)

## Benchmark

```
Time (mean ± σ):   4.9 ms ± 0.4 ms   [User: 1.0 ms, System: 0.6 ms]
Range (min … max): 3.2 ms … 10.1 ms    500 runs   (hyperfine, -O2 -s)
```

## Setup

**Dependencies:** `libjson-c-dev` (Ubuntu/Debian: `sudo apt-get install libjson-c-dev`, macOS: `brew install json-c`)

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
