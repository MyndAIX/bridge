#!/usr/bin/env python3
"""
ollama-enrich-prompt.py — Pre-read files mentioned in a task and inject their contents.
Usage: ollama-enrich-prompt.py <repo-path> < task.md > enriched.md

Extracts file paths from the task text, reads them from the repo,
and prepends their contents to the prompt so the model has real code context.
"""

import sys, os, re

REPO = os.path.normpath(sys.argv[1])
MAX_FILE_SIZE = 60_000  # chars per file
MAX_TOTAL_INJECT = 120_000  # total injected chars

task = sys.stdin.read()

# Extract file paths from the task text
# Match patterns like: path/to/file.ext, "path/to/file.ext", `path/to/file.ext`
# Must have a file extension to avoid false positives
path_pattern = re.compile(
    r'(?:^|[\s`"\'/])('
    r'(?:[\w.-]+/)*[\w.-]+\.'  # path segments ending with dot
    r'(?:swift|ts|tsx|js|jsx|py|sh|md|json|yaml|yml|toml|css|html|xml|plist|xcconfig|entitlements)'
    r')(?:[\s`"\',.:;)\]|]|$)',
    re.MULTILINE
)

found_paths = []
for m in path_pattern.finditer(task):
    p = m.group(1)
    # Try the path as-is, and with common prefixes
    candidates = [p]
    # If path doesn't start with a known top-level dir, try finding it
    if not os.path.exists(os.path.join(REPO, p)):
        # Walk top-level dirs to find the file
        for d in os.listdir(REPO):
            full = os.path.join(REPO, d, p)
            if os.path.isfile(full):
                candidates = [os.path.join(d, p)]
                break
            # Try stripping first segment if it matches
            parts = p.split("/", 1)
            if len(parts) > 1 and d == parts[0]:
                full2 = os.path.join(REPO, p)
                if os.path.isfile(full2):
                    candidates = [p]
                    break
    found_paths.extend(candidates)

# Deduplicate while preserving order
seen = set()
unique_paths = []
for p in found_paths:
    if p not in seen:
        seen.add(p)
        unique_paths.append(p)

# Read files and build injection
injected = []
total_chars = 0

for rel_path in unique_paths:
    abs_path = os.path.join(REPO, rel_path)
    if not os.path.isfile(abs_path):
        continue
    # Safety: must be within repo
    if not os.path.normpath(abs_path).startswith(REPO):
        continue
    try:
        with open(abs_path, "r", errors="replace") as f:
            content = f.read()
        if len(content) > MAX_FILE_SIZE:
            content = content[:MAX_FILE_SIZE] + "\n... [truncated]"
        if total_chars + len(content) > MAX_TOTAL_INJECT:
            break
        injected.append((rel_path, content))
        total_chars += len(content)
    except Exception:
        pass

# Output: injected files + original task
if injected:
    print("# Pre-loaded File Contents\n")
    print("The following files were pre-read from the repository for your reference.\n")
    for rel_path, content in injected:
        ext = rel_path.rsplit(".", 1)[-1] if "." in rel_path else ""
        print(f"## File: {rel_path}\n")
        print(f"```{ext}")
        print(content)
        print("```\n")
    print("---\n")
    print("# Task\n")

print(task)
