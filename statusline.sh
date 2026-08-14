#!/bin/bash
# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# "$@" is forwarded so `./statusline.sh --version` reaches the binary. Claude Code
# invokes this with no arguments, where "$@" expands to nothing and behavior is
# unchanged; without it the flag is silently dropped and the process blocks on stdin.
"$SCRIPT_DIR/target/release/claude_statusline" "$@"
