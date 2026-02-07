# Claude Statusline

A fast C statusline formatter for [Claude Code](https://claude.com/claude-code). Reads JSON from stdin, outputs a two-line ANSI-colored status display.

```
[Opus] 📁 project | 🌿 main | 💲0.05
🎫 42% | 🔤 50k in / 12k out | ✏️ +156 / -23
```

**Line 1:** model, directory, git branch, session cost
**Line 2:** context window % ([clickable link](https://claude.ai/settings/usage) in supported terminals), token counts, lines changed (shown only when data is available)

## Benchmark

```
Time (mean ± σ):   5.0 ms ± 0.8 ms   [User: 1.1 ms, System: 0.5 ms]
Range (min … max): 3.5 ms … 17.5 ms    500 runs   (hyperfine)
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
