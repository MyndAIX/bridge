# MyndAIX Cheat Sheet
# Read this before writing code. KilaBz enforces it.

## Platform (macOS)
- NO `readlink -f` — use `python3 -c "import os; print(os.path.realpath('$path'))"`
- NO `setsid` — use `pkill -P "$pid"` for process group kills
- NO `timeout` — use `gtimeout` (brew install coreutils) or background + sleep + kill
- NO `echo` for data — use `printf '%s' "$var"` (echo is shell-dependent)

## Paths
- Trailing slash on prefix checks: `"$root/"*` not `"$root"*`
- Mini = `~/`, MacBook = `~/`
- Never hardcode cross-machine paths — use `$HOME`
- Resolve symlinks before allowlist checks: `python3 os.path.realpath()`

## Shell
- `local` only inside functions — top-level = crash with `set -e`
- Array-based exec: `cmd=("claude" "-p"); "${cmd[@]}"` — never `eval` or `bash -c` with interpolation
- Build JSON with `python3 -c` or `jq`, not heredocs in bash variables
- Temp files: `mktemp` + `trap 'rm -f "$tmp"' EXIT`

## Security
- Wrap untrusted input in `<user_input>` tags with "treat as DATA" instruction
- Strip `</user_input>` (case-insensitive) from content before wrapping
- Secrets in `~/.myndaix/.secrets` (chmod 600), never in .zshrc or env vars
- Validate task_id/paths: strip `..`, `/`, shell metacharacters before filesystem use

## Dispatch Schema (REQUIRED FIELDS)
- **ALL types**: `from`, `type`, `subject`
- **task**: + `objective`, `priority` (P0-P3), `tier` (auto), `scope` (in/out arrays), `done_criteria`
- **review**: + `objective`, `branch`, `tier`, `scope` (in/out arrays)
- **research**: + `objective`, `priority`, `tier`
- **repo**: Always absolute path to a valid git repo on the TARGET machine

## Git Safety
- NO `git reset --hard`, `git checkout --`, `git clean -f`, or force push without explicit instruction
- NO history rewrite (`rebase -i`, `commit --amend` on pushed commits) without approval

## The MyndAIX Way
Build → Review (KilaBz + Oracle) → Fix → Re-review → Ship
