# claude_statusline

C statusline formatter for Claude Code. Reads JSON from stdin (piped by Claude Code's statusline runner) and outputs an ANSI-colored two-line display showing model, directory, git branch, session name, context usage, token counts, and 5-hour rate limit.

## Build

```bash
make          # build claude_statusline binary
make clean    # remove binary
make test     # build + run smoke tests
```

**Dependency:** json-c and pkg-config (install via your system package manager: `libjson-c-dev pkg-config` on Ubuntu/Debian, `json-c pkg-config` via Homebrew on macOS). The Makefile resolves json-c's include/lib paths through `pkg-config`, so Homebrew's non-standard prefixes (`/opt/homebrew`, `/usr/local`) work without manual flags.

## Architecture

- **`main.c`** — Single-file C program; all logic lives here.
- **`statusline.sh`** — Tiny shell wrapper that invokes the binary from the script's directory. Used as the Claude Code statusline command.
- Git branch is read directly from `.git/HEAD` (no `git` subprocess).
- All buffers are stack-allocated (`static char` / local arrays). No `malloc`.

## JSON Schema (stdin)

The program parses these fields from the JSON object piped to stdin:

| Path | Type | Used for |
|------|------|----------|
| `model.display_name` | string | Model name in header |
| `workspace.current_dir` | string | Directory basename |
| `context_window.used_percentage` | number | Context % (color-coded) |
| `rate_limits.five_hour.used_percentage` | number | 5h rate limit used % (color-coded; Pro/Max only) |
| `rate_limits.five_hour.resets_at` | int | Unix epoch seconds when 5h window resets (countdown display) |
| `rate_limits.seven_day.used_percentage` | number | 7d (weekly) rate limit used % (color-coded; Pro/Max only) |
| `rate_limits.seven_day.resets_at` | int | Unix epoch seconds when 7d window resets (countdown display) |

All fields are optional; missing fields are silently skipped.

## Code Conventions

- **Standard:** C99 + POSIX (`_POSIX_C_SOURCE 200809L`)
- **Functions:** `snake_case`
- **Macros:** `UPPERCASE`
- **Memory:** Static/stack buffers only — no heap allocation
- **Compiler flags:** Must compile clean with `-Wall -Wextra -std=c99 -O2` (`-s` is added on Linux only; Apple's linker doesn't support it)
