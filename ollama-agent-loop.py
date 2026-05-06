#!/usr/bin/env python3
"""
ollama-agent-loop.py — Tool-calling agent loop for Ollama models.
Usage: ollama-agent-loop.py <repo-path> <model> <sandbox-mode> <timeout> <log-file>
Reads task prompt from stdin, outputs final response to stdout.
"""

import sys, json, os, subprocess, time
import urllib.request

REPO = os.path.normpath(sys.argv[1])
MODEL = sys.argv[2]
SANDBOX = sys.argv[3]       # "full" or "read-only"
TIMEOUT = int(sys.argv[4])
LOG_FILE = sys.argv[5]

MAX_ITERATIONS = 20
OLLAMA_URL = "http://localhost:11434/api/chat"

# ── Tool definitions ──────────────────────────────────────────────

READ_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read file contents. Path relative to repo root.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "File path relative to repo root"}
                },
                "required": ["path"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "list_directory",
            "description": "List files/dirs at path. Defaults to repo root.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Directory path relative to repo root (default: .)"}
                },
                "required": []
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "search_code",
            "description": "Search codebase for a pattern. Returns matching lines as file:line:content.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": {"type": "string", "description": "Search pattern (regex)"},
                    "glob": {"type": "string", "description": "File glob filter, e.g. '*.swift'"}
                },
                "required": ["pattern"]
            }
        }
    },
]

WRITE_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Write/overwrite a file. Path relative to repo root.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "File path relative to repo root"},
                    "content": {"type": "string", "description": "File content"}
                },
                "required": ["path", "content"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "run_command",
            "description": "Execute a shell command in the repo dir. 30s timeout.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "Shell command to run"}
                },
                "required": ["command"]
            }
        }
    },
]

# ── Helpers ────────────────────────────────────────────────────────

def log(msg):
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [ollama-loop] {msg}\n")
    except Exception:
        pass

def safe_path(path):
    """Resolve path within repo. Raises on escape."""
    abs_path = os.path.normpath(os.path.join(REPO, path))
    if not abs_path.startswith(REPO + os.sep) and abs_path != REPO:
        raise ValueError(f"Path escapes repo: {path}")
    return abs_path

def execute_tool(name, arguments):
    """Run a tool and return result string."""
    if isinstance(arguments, str):
        try:
            arguments = json.loads(arguments)
        except json.JSONDecodeError:
            arguments = {}

    try:
        if name == "read_file":
            path = safe_path(arguments.get("path", ""))
            with open(path, "r", errors="replace") as f:
                content = f.read()
            if len(content) > 50_000:
                content = content[:50_000] + "\n... [truncated at 50K chars]"
            return content

        elif name == "list_directory":
            path = safe_path(arguments.get("path", "."))
            entries = sorted(os.listdir(path))
            lines = []
            for e in entries[:200]:
                full = os.path.join(path, e)
                suffix = "/" if os.path.isdir(full) else f" ({os.path.getsize(full)} bytes)"
                lines.append(f"{e}{suffix}")
            if len(entries) > 200:
                lines.append(f"... and {len(entries) - 200} more")
            return "\n".join(lines)

        elif name == "search_code":
            pattern = arguments.get("pattern", "")
            glob_filter = arguments.get("glob", "")
            # Strip useless globs that models tend to output
            if glob_filter in ("**", "**/*", "*"):
                glob_filter = ""
            # Prefer ripgrep, fall back to grep
            rg = "rg" if subprocess.run(["which", "rg"], capture_output=True).returncode == 0 else None
            if rg:
                cmd = ["rg", "-n", "--max-count", "5", "--max-filesize", "1M"]
                if glob_filter:
                    cmd += ["-g", glob_filter]
                cmd += [pattern, REPO]
            else:
                cmd = ["grep", "-rn", "--max-count=5"]
                if glob_filter:
                    cmd += ["--include", glob_filter]
                cmd += [pattern, REPO]
            try:
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
                output = result.stdout.replace(REPO + "/", "")
                if len(output) > 30_000:
                    output = output[:30_000] + "\n... [truncated]"
                return output or "No matches found."
            except subprocess.TimeoutExpired:
                return "Search timed out (15s)."

        elif name == "write_file":
            if SANDBOX == "read-only":
                return "ERROR: write_file not available in read-only mode."
            path = safe_path(arguments.get("path", ""))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(arguments.get("content", ""))
            return f"Written: {arguments.get('path', '')}"

        elif name == "run_command":
            if SANDBOX == "read-only":
                return "ERROR: run_command not available in read-only mode."
            try:
                result = subprocess.run(
                    arguments.get("command", "echo no-op"),
                    shell=True, capture_output=True, text=True,
                    timeout=30, cwd=REPO
                )
                output = (result.stdout + result.stderr).strip()
                if len(output) > 30_000:
                    output = output[:30_000] + "\n... [truncated]"
                return output or "(no output)"
            except subprocess.TimeoutExpired:
                return "Command timed out (30s)."

        else:
            return f"Unknown tool: {name}"
    except Exception as e:
        return f"ERROR: {e}"

# Track whether model supports native tool calling
_supports_tools = None

def call_ollama(messages, tools):
    """Call Ollama native /api/chat endpoint. Auto-detects tool support."""
    global _supports_tools

    payload = {
        "model": MODEL,
        "messages": messages,
        "stream": False,
        "options": {"temperature": 0.2, "num_predict": 4096},
    }

    # Only include tools if model supports them (or we haven't checked yet)
    use_tools = tools and _supports_tools is not False
    if use_tools:
        payload["tools"] = tools

    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        OLLAMA_URL, data=data,
        headers={"Content-Type": "application/json"}
    )

    try:
        with urllib.request.urlopen(req, timeout=max(TIMEOUT, 120)) as resp:
            if _supports_tools is None and use_tools:
                _supports_tools = True
                log("Model supports native tool calling")
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 400 and use_tools:
            # Model doesn't support tools — retry without them
            _supports_tools = False
            log("Model doesn't support native tools — using prompt-based tools")
            del payload["tools"]
            data = json.dumps(payload).encode()
            req2 = urllib.request.Request(
                OLLAMA_URL, data=data,
                headers={"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(req2, timeout=max(TIMEOUT, 120)) as resp:
                return json.loads(resp.read())
        raise

# ── DeepSeek R1 <think> tag handling ──────────────────────────────

import re

def strip_thinking(text):
    """Remove <think>...</think> blocks from final output."""
    return re.sub(r'<think>.*?</think>', '', text, flags=re.DOTALL).strip()

# ── Text-based tool call parsing (for models that don't use tool_calls) ──

def try_parse_text_tool_call(text):
    """Try to parse tool calls from text when model outputs them as JSON text."""
    TOOL_NAMES = {"read_file", "list_directory", "search_code", "write_file", "run_command"}
    results = []

    # Pattern 1: {"name": "tool_name", "arguments": {...}} (including empty {})
    for m in re.finditer(r'\{\s*"name"\s*:\s*"(\w+)"\s*,\s*"arguments"\s*:\s*(\{[^}]*\})', text):
        name = m.group(1)
        if name in TOOL_NAMES:
            try:
                args = json.loads(m.group(2))
                results.append({"function": {"name": name, "arguments": args}})
            except json.JSONDecodeError:
                pass

    # Pattern 2: tool_name({"key": "value"}) or tool_name({})
    for m in re.finditer(r'(\w+)\(\s*(\{[^)]*\})\s*\)', text):
        name = m.group(1)
        if name in TOOL_NAMES:
            try:
                args = json.loads(m.group(2))
                results.append({"function": {"name": name, "arguments": args}})
            except json.JSONDecodeError:
                pass

    return results if results else None

# ── Main loop ──────────────────────────────────────────────────────

def main():
    task = sys.stdin.read().strip()
    if not task:
        print("No task provided.", file=sys.stderr)
        sys.exit(1)

    all_tools = READ_TOOLS[:]
    if SANDBOX != "read-only":
        all_tools.extend(WRITE_TOOLS)

    # Build tool descriptions for prompt-based tool calling (non-native models)
    tool_names = [t["function"]["name"] for t in all_tools]
    tool_desc = "\n".join(
        f"- {t['function']['name']}: {t['function']['description']} "
        f"Params: {json.dumps(list(t['function']['parameters'].get('properties', {}).keys()))}"
        for t in all_tools
    )

    # Get top-level directory listing to help model navigate
    try:
        top_dirs = sorted(os.listdir(REPO))[:30]
        dir_listing = ", ".join(
            f"{d}/" if os.path.isdir(os.path.join(REPO, d)) else d
            for d in top_dirs if not d.startswith(".")
        )
    except Exception:
        dir_listing = "(unknown)"

    system_content = (
        "You are a skilled software engineer reviewing a codebase. "
        f"The repo root is '{REPO}'.\n\n"
        f"Top-level contents: {dir_listing}\n\n"
        "## Available Tools\n\n"
        f"{tool_desc}\n\n"
        "## How to Use Tools\n\n"
        "Output EXACTLY this JSON on its own line (no markdown code blocks):\n"
        '{"name": "tool_name", "arguments": {"param": "value"}}\n\n'
        "You can call multiple tools — put each on its own line.\n"
        "For search_code, use glob like '*.swift' not '**'.\n"
        "After receiving tool results, analyze them and either call more tools or give your final answer.\n\n"
        "## Rules\n"
        "- ALWAYS read_file before making claims about code\n"
        "- Quote ACTUAL lines from files, never fabricate code examples\n"
        "- If a file path doesn't work, use list_directory to find the right path\n"
        "- Give your final answer as plain text (no tool calls) when done"
    )

    messages = [
        {"role": "system", "content": system_content},
        {"role": "user", "content": task},
    ]

    start = time.time()
    final_content = ""

    for i in range(MAX_ITERATIONS):
        elapsed = time.time() - start
        if elapsed > TIMEOUT - 15:
            log(f"Timeout in {TIMEOUT - elapsed:.0f}s — forcing final answer (iter {i+1})")
            break

        log(f"iter {i+1}/{MAX_ITERATIONS}")

        try:
            resp = call_ollama(messages, all_tools)
        except Exception as e:
            log(f"API error: {e}")
            print(f"Ollama API error: {e}", file=sys.stderr)
            sys.exit(1)

        msg = resp.get("message", {})
        content = msg.get("content", "")
        tool_calls = msg.get("tool_calls") or []

        # Some models output tool calls as text instead of using tool_calls.
        # Also check inside <think> blocks (DeepSeek R1 may reason about tools there).
        if not tool_calls and content:
            # Try parsing from full content (including think blocks)
            parsed = try_parse_text_tool_call(content)
            if parsed:
                tool_calls = parsed
                msg["tool_calls"] = tool_calls
                msg["content"] = ""
                log(f"Parsed {len(tool_calls)} tool call(s) from text output")

        # Append assistant message to history
        messages.append(msg)

        if not tool_calls:
            # Strip <think> tags from DeepSeek R1 output, log thinking for debug
            if '<think>' in content:
                thinking = re.findall(r'<think>(.*?)</think>', content, re.DOTALL)
                for t in thinking:
                    log(f"thinking: {t[:500]}")
            clean = strip_thinking(content)
            final_content = clean
            log(f"Final answer at iter {i+1} ({len(clean)} chars)")
            print(clean)
            return

        # Execute tool calls
        for tc in tool_calls:
            func = tc.get("function", {})
            name = func.get("name", "?")
            args = func.get("arguments", {})

            log(f"tool: {name}({json.dumps(args, default=str)[:200]})")
            result = execute_tool(name, args)
            log(f"result: {len(result)} chars")

            messages.append({
                "role": "tool",
                "content": result,
                "tool_name": name,
            })

        # Context management — truncate if history is too long (~25K tokens)
        total = sum(len(json.dumps(m, default=str)) for m in messages)
        if total > 100_000:
            log(f"Truncating history ({total} chars → keeping system + user + last 10)")
            messages = messages[:2] + messages[-10:]

    # Max iterations or timeout — try to get a final answer
    log(f"Forcing final answer after {MAX_ITERATIONS} iterations")
    messages.append({
        "role": "user",
        "content": "Provide your final answer now based on what you've found.",
    })
    try:
        resp = call_ollama(messages, [])
        content = strip_thinking(resp.get("message", {}).get("content", ""))
        print(content)
    except Exception:
        if final_content:
            print(final_content)
        else:
            print("Agent loop exhausted without producing a final answer.")

if __name__ == "__main__":
    main()
