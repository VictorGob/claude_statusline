# claude_statusline

C statusline formatter for Claude Code. Reads JSON from stdin (provided by Claude Code's `--output-format stream-json`) and outputs an ANSI-colored two-line display showing model, directory, git branch, cost, context usage, and line changes.

## Build

```bash
make          # build claude_statusline binary
make clean    # remove binary
make test     # build + run smoke tests
```

**Dependency:** `libjson-c-dev` (install via your system package manager).

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
| `context_window.total_input_tokens` | int | Token counts (compact format) |
| `context_window.total_output_tokens` | int | Token counts (compact format) |
| `cost.total_cost_usd` | number | Session cost |
| `cost.total_lines_added` | int | Lines added (green) |
| `cost.total_lines_removed` | int | Lines removed (red) |

All fields are optional; missing fields are silently skipped.

## Code Conventions

- **Standard:** C99 + POSIX (`_POSIX_C_SOURCE 200809L`)
- **Functions:** `snake_case`
- **Macros:** `UPPERCASE`
- **Memory:** Static/stack buffers only — no heap allocation
- **Compiler flags:** Must compile clean with `-Wall -Wextra -std=c99 -O2 -s`
