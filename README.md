# Claude Statusline

A fast C implementation of a custom statusline formatter for Claude Code.

## Overview

This tool reads JSON from stdin containing model and workspace information, and outputs a formatted status line with:
- Model display name
- Current directory basename
- Git branch (if in a git repository)
- Token usage (remaining/total context window)

**Example output:** `[Claude 3.5 Sonnet] 📁 project | 🌿 main | 🎫 150k/200k`

## Requirements

- GCC or compatible C compiler
- `libjson-c-dev` library

### Installing Dependencies

**Ubuntu/Debian:**
```bash
sudo apt-get install libjson-c-dev
```

**macOS:**
```bash
brew install json-c
```

## Building

```bash
make
```

## Configuration in Claude Code

1. **Build the binary:**
   ```bash
   make
   ```

2. **Add to your Claude Code settings** (`~/.claude/settings.json`):
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "/absolute/path/to/claude_statusline/statusline.sh",
       "padding": 0
     }
   }
   ```

3. **Restart Claude Code** or start a new conversation to see the custom statusline

## Manual Testing

```bash
echo '{"model":{"display_name":"Claude 3.5 Sonnet"},"workspace":{"current_dir":"/path/to/project"},"context_window":{"context_window_size":200000,"total_input_tokens":35000,"total_output_tokens":15000}}' | ./statusline.sh
```

**Expected output:**
```
[Claude 3.5 Sonnet] 📁 project | 🌿 main | 🎫 150k/200k
```

**Note:** The token display shows remaining tokens / total context window size in thousands.

## Make Commands

- `make` - Build the binary
- `make test` - Run tests
- `make clean` - Remove built artifacts

## How It Works

1. Claude Code passes JSON via stdin with model, workspace, and context window data
2. The C program parses the JSON using `json-c`
3. Extracts the directory basename and reads `.git/HEAD` for branch info
4. Calculates token usage from `context_window` data (remaining = window_size - input_tokens - output_tokens)
5. Outputs a formatted statusline with UTF-8 emoji support, displaying tokens in thousands (e.g., 150k/200k)

## License

MIT
