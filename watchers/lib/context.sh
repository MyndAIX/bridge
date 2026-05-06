#!/bin/bash
# context.sh — Shared context library for bridge pipeline
# Provides: extract_context, inject_context, build_result_envelope
#
# Usage: source this file from watchers or chaining.sh
# Requires: python3

CONTEXT_MAX_CHARS=2000

# extract_context <result_file>
# Extracts context block from a result envelope's frontmatter + body.
# Returns JSON: {files_touched, decisions, error_info, summary}
# Output capped at CONTEXT_MAX_CHARS.
extract_context() {
  local result_file="$1"
  if [[ ! -f "$result_file" ]]; then
    echo '{"files_touched":[],"decisions":[],"error_info":"","summary":"file not found"}'
    return 1
  fi

  python3 -c '
import sys, json, re

max_chars = int(sys.argv[2])
content = open(sys.argv[1], encoding="utf-8").read()

# Parse frontmatter
fm = {}
m = re.match(r"^---\s*\n(.*?)\n---\s*\n?", content, re.DOTALL)
if m:
    import yaml
    try:
        fm = yaml.safe_load(m.group(1)) or {}
    except Exception:
        fm = {}
    body = content[m.end():]
else:
    body = content

# Extract context fields — check frontmatter first, then body markers
def get_field(key, default):
    if key in fm:
        val = fm[key]
        return val if isinstance(val, list) else [val] if val else default
    # Check for markdown section in body
    pattern = rf"##\s*{re.escape(key)}.*?\n(.*?)(?=\n##|\Z)"
    match = re.search(pattern, body, re.DOTALL | re.IGNORECASE)
    if match:
        lines = [l.strip().lstrip("- ") for l in match.group(1).strip().split("\n") if l.strip()]
        return lines if lines else default
    return default

files_touched = get_field("files_touched", [])
decisions = get_field("decisions", [])

# error_info: string
error_info = fm.get("error_info", "")
if not error_info:
    for marker in ["## Error", "## Errors", "Error:"]:
        idx = body.find(marker)
        if idx >= 0:
            error_info = body[idx:idx+500].strip()
            break

# summary: first non-empty body paragraph or frontmatter subject
summary = fm.get("summary", "")
if not summary:
    summary = fm.get("subject", "")
if not summary:
    for line in body.split("\n"):
        line = line.strip()
        if line and not line.startswith("#") and not line.startswith("---"):
            summary = line
            break

ctx = {
    "files_touched": files_touched[:20],
    "decisions": decisions[:10],
    "error_info": str(error_info)[:500],
    "summary": str(summary)[:500]
}
out = json.dumps(ctx, ensure_ascii=False)
# Cap total output
if len(out) > max_chars:
    ctx["decisions"] = ctx["decisions"][:3]
    ctx["files_touched"] = ctx["files_touched"][:10]
    ctx["error_info"] = ctx["error_info"][:200]
    ctx["summary"] = ctx["summary"][:200]
    out = json.dumps(ctx, ensure_ascii=False)
while len(out) > max_chars:
    # Progressively shorten the largest field until it fits
    lens = {
        "error_info": len(ctx["error_info"]),
        "summary": len(ctx["summary"]),
        "decisions": sum(len(d) for d in ctx["decisions"]),
        "files_touched": sum(len(f) for f in ctx["files_touched"]),
    }
    longest = max(lens, key=lens.get)
    if lens[longest] == 0:
        break  # Nothing left to trim
    if longest in ("error_info", "summary"):
        ctx[longest] = ctx[longest][:len(ctx[longest])//2]
    else:
        ctx[longest] = ctx[longest][:max(len(ctx[longest])-1, 0)]
    out = json.dumps(ctx, ensure_ascii=False)
print(out)
' "$result_file" "$CONTEXT_MAX_CHARS"
}

# inject_context <task_file> <context_block>
# Adds context from previous agent into task body.
# Wraps in <prior_context> tags. Sanitizes injection attempts.
# Modifies the file in place.
inject_context() {
  local task_file="$1"
  local context_block="$2"

  if [[ ! -f "$task_file" ]]; then
    return 1
  fi

  # Sanitize: strip any existing <prior_context> or </prior_context> tags,
  # remove script tags, and cap length
  local sanitized
  sanitized=$(python3 -c '
import sys, re, json

ctx = sys.argv[1]
max_chars = int(sys.argv[2])

# Strip dangerous patterns
ctx = re.sub(r"</?prior_context[^>]*>", "", ctx)
ctx = re.sub(r"<script[^>]*>.*?</script>", "", ctx, flags=re.DOTALL | re.IGNORECASE)
ctx = re.sub(r"</?script[^>]*>", "", ctx, flags=re.IGNORECASE)
# Strip shell injection patterns
ctx = re.sub(r"\$\([^)]*\)", "", ctx)
ctx = re.sub(r"`[^`]*`", "", ctx)

# Cap length
if len(ctx) > max_chars:
    ctx = ctx[:max_chars]

print(ctx)
' "$context_block" "$CONTEXT_MAX_CHARS")

  # Find end of frontmatter and inject after it
  python3 -c '
import sys, re

task_file = sys.argv[1]
context = sys.argv[2]

content = open(task_file, encoding="utf-8").read()

# Find end of frontmatter
m = re.match(r"^(---\s*\n.*?\n---\s*\n?)", content, re.DOTALL)
if m:
    before = m.group(1)
    after = content[m.end():]
else:
    before = ""
    after = content

injection = f"\n<prior_context>\n{context}\n</prior_context>\n\n"

with open(task_file, "w", encoding="utf-8") as f:
    f.write(before + injection + after)
' "$task_file" "$sanitized"
}

# build_result_envelope <status> <summary> <files_touched> <decisions> [dispatch_to] [chain_id] [chain_depth]
# Builds standardized result with context block.
# files_touched and decisions are comma-separated strings.
# Prints the envelope to stdout (caller redirects to file).
build_result_envelope() {
  local status="$1"
  local summary="$2"
  local files_touched="$3"
  local decisions="$4"
  local dispatch_to="${5:-}"
  local chain_id="${6:-}"
  local chain_depth="${7:-0}"

  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  python3 -c '
import sys, json

status = sys.argv[1]
summary = sys.argv[2]
files_raw = sys.argv[3]
decisions_raw = sys.argv[4]
dispatch_to = sys.argv[5]
chain_id = sys.argv[6]
chain_depth = sys.argv[7]
now = sys.argv[8]

files = [f.strip() for f in files_raw.split(",") if f.strip()]
decisions = [d.strip() for d in decisions_raw.split(",") if d.strip()]

lines = []
lines.append("---")
lines.append(f"type: result")
lines.append(f"status: {status}")
lines.append(f"created: {now}")
if chain_id:
    lines.append(f"chain_id: {chain_id}")
    lines.append(f"chain_depth: {chain_depth}")
if dispatch_to:
    lines.append(f"dispatch_to: {dispatch_to}")
lines.append("---")
lines.append("")
lines.append(f"## Summary")
lines.append(summary)
lines.append("")
if files:
    lines.append("## Files Touched")
    for f in files:
        lines.append(f"- {f}")
    lines.append("")
if decisions:
    lines.append("## Decisions")
    for d in decisions:
        lines.append(f"- {d}")
    lines.append("")

print("\n".join(lines))
' "$status" "$summary" "$files_touched" "$decisions" "$dispatch_to" "$chain_id" "$chain_depth" "$now"
}

# Export all functions
export -f extract_context
export -f inject_context
export -f build_result_envelope
