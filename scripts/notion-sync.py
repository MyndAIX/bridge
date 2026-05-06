#!/usr/bin/env python3
"""
notion-sync.py — Sync processed bridge result files to the MyndAIX Notion Task Board.

Reads result .md files from ~/.myndaix/bridge/processed/, matches them to
Notion database entries by task name, and updates Status + Result fields.

Usage:
  python3 notion-sync.py                    # process all unsynced files
  python3 notion-sync.py <file.md>          # process a single file
"""

import json
import os
import re
import sys
import urllib.request
import urllib.error
from pathlib import Path

# ── Config ──────────────────────────────────────────────────────────────────
ENV_PATH = Path.home() / ".myndaix" / ".env"
PROCESSED_DIR = Path.home() / ".myndaix" / "bridge" / "processed"
SYNCED_LOG = Path.home() / ".myndaix" / "bridge" / ".notion-synced"
NOTION_API = "https://api.notion.com/v1"
NOTION_VERSION = "2022-06-28"

# Status mapping from result file → Notion select option
STATUS_MAP = {
    "COMPLETE": "Done",
    "COMPLETED": "Done",
    "DONE": "Done",
    "SUCCESS": "Done",
    "SHIPPED": "Done",
    "PASS": "Done",
    "FAILED": "Blocked",
    "REJECTED": "Blocked",
    "BLOCKED": "Blocked",
    "TIMEOUT": "Blocked",
    "CONTEXT_OVERFLOW": "Blocked",
    "KILLED": "Killed",
    "IN PROGRESS": "In Progress",
    "IN_PROGRESS": "In Progress",
    "QUEUED": "Queued",
}


def load_env():
    """Load key=value pairs from .env file."""
    env = {}
    if ENV_PATH.exists():
        for line in ENV_PATH.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


def parse_frontmatter(text: str) -> dict:
    """Extract YAML-ish frontmatter from a markdown file."""
    m = re.match(r"^---\s*\n(.*?)\n---", text, re.DOTALL)
    if not m:
        return {}
    fm = {}
    for line in m.group(1).splitlines():
        line = line.strip()
        if ":" in line and not line.startswith("#"):
            key, val = line.split(":", 1)
            fm[key.strip().lower()] = val.strip().strip('"').strip("'")
    return fm


def get_body_summary(text: str, max_chars: int = 500) -> str:
    """Extract body text after frontmatter, truncated."""
    m = re.match(r"^---\s*\n.*?\n---\s*\n?", text, re.DOTALL)
    body = text[m.end():] if m else text
    body = body.strip()
    if len(body) > max_chars:
        body = body[:max_chars] + "…"
    return body


def notion_headers(api_key: str) -> dict:
    return {
        "Authorization": f"Bearer {api_key}",
        "Notion-Version": NOTION_VERSION,
        "Content-Type": "application/json",
    }


def _api_request(url: str, headers: dict, data: dict = None, method: str = "POST") -> dict:
    """Make a Notion API request using urllib."""
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        error_body = e.read().decode() if e.fp else ""
        raise RuntimeError(f"Notion API {e.code}: {error_body}")


def query_database(api_key: str, db_id: str) -> list:
    """Fetch all pages from the Notion database."""
    pages = []
    url = f"{NOTION_API}/databases/{db_id}/query"
    headers = notion_headers(api_key)
    payload = {"page_size": 100}
    while True:
        data = _api_request(url, headers, payload)
        pages.extend(data.get("results", []))
        if not data.get("has_more"):
            break
        payload["start_cursor"] = data["next_cursor"]
    return pages


def get_page_title(page: dict) -> str:
    """Extract the title text from a Notion page."""
    task_prop = page.get("properties", {}).get("Task", {})
    title_parts = task_prop.get("title", [])
    return "".join(t.get("plain_text", "") for t in title_parts)


def update_page(api_key: str, page_id: str, status: str, result: str):
    """Update Status and Result properties on a Notion page."""
    url = f"{NOTION_API}/pages/{page_id}"
    headers = notion_headers(api_key)
    properties = {}
    if status:
        properties["Status"] = {"select": {"name": status}}
    if result:
        properties["Result"] = {"rich_text": [{"text": {"content": result[:2000]}}]}
    return _api_request(url, headers, {"properties": properties}, method="PATCH")


def load_synced_set() -> set:
    """Load set of already-synced filenames."""
    if SYNCED_LOG.exists():
        return set(SYNCED_LOG.read_text().splitlines())
    return set()


def save_synced(filename: str):
    """Append a filename to the synced log."""
    with open(SYNCED_LOG, "a") as f:
        f.write(filename + "\n")


def get_task_id(page: dict) -> str:
    """Extract the Task ID (e.g. 'MX-30') from a Notion page."""
    tid = page.get("properties", {}).get("Task ID", {}).get("unique_id", {})
    if tid and tid.get("prefix") and tid.get("number") is not None:
        return f"{tid['prefix']}-{tid['number']}"
    return ""


def tokenize(text: str) -> set:
    """Extract meaningful words from text for fuzzy matching."""
    # Remove common prefixes, filenames, timestamps, punctuation
    text = re.sub(r"^(Re|Review|REVIEW|FAILED|COMPLETE|FIX|REVISED|RE|Reply):\s*", "", text)
    text = re.sub(r"\d{14}-[\w-]+\.md", "", text)  # strip filename patterns
    text = re.sub(r"\d{8}T?\d{0,6}Z?", "", text)  # strip timestamps
    text = re.sub(r"[^a-zA-Z0-9\s]", " ", text)  # punctuation to spaces
    words = set(text.lower().split())
    # Remove stopwords
    stopwords = {"the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for",
                 "of", "with", "by", "from", "is", "it", "this", "that", "was", "are",
                 "be", "has", "had", "have", "do", "does", "did", "will", "would",
                 "can", "could", "should", "may", "might", "not", "no", "all", "re"}
    return words - stopwords


def match_page(pages: list, subject: str, task_id: str = ""):
    """Find a Notion page matching by task_id first, then fuzzy subject match."""
    # 1. Exact task_id match (e.g. "MX-30" in frontmatter matches Notion Task ID)
    if task_id:
        task_id_clean = task_id.strip().upper()
        for p in pages:
            if get_task_id(p).upper() == task_id_clean:
                return p, "task_id"

    subject_lower = subject.lower()

    # 2. Exact title match
    for p in pages:
        if get_page_title(p).lower() == subject_lower:
            return p, "exact"

    # 3. Substring match (either direction)
    for p in pages:
        title = get_page_title(p).lower()
        if title and (title in subject_lower or subject_lower in title):
            return p, "substring"

    # 4. Keyword overlap scoring
    subject_tokens = tokenize(subject)
    if len(subject_tokens) < 2:
        return None, None

    best_page = None
    best_score = 0
    for p in pages:
        title = get_page_title(p)
        title_tokens = tokenize(title)
        if not title_tokens:
            continue
        overlap = subject_tokens & title_tokens
        if not overlap:
            continue
        # Score: overlap count / min(len(subject), len(title)) to normalize
        score = len(overlap) / min(len(subject_tokens), len(title_tokens))
        if score > best_score and score >= 0.4:  # 40% keyword overlap threshold
            best_score = score
            best_page = p

    if best_page:
        return best_page, f"fuzzy({best_score:.0%})"

    return None, None


def sync_file(filepath: Path, api_key: str, db_id: str, pages: list) -> bool:
    """Process a single result file and sync to Notion. Returns True if synced."""
    text = filepath.read_text()
    fm = parse_frontmatter(text)

    # Must be a result file
    if fm.get("type") not in ("result", "review", "response"):
        return False

    subject = fm.get("subject", "")
    if not subject:
        return False

    # Clean "Re: " prefix
    clean_subject = re.sub(r"^Re:\s*", "", subject, flags=re.IGNORECASE)

    # Get task_id if present
    task_id = fm.get("task_id", "")

    # Determine status
    raw_status = fm.get("status", fm.get("validation", "")).upper()
    notion_status = STATUS_MAP.get(raw_status)

    # Build result summary
    result_summary = get_body_summary(text)

    # Find matching page
    page, match_type = match_page(pages, clean_subject, task_id)
    if not page:
        return False

    title = get_page_title(page)
    print(f"  MATCH [{match_type}] {filepath.name} → '{title}'")

    # Update
    update_page(api_key, page["id"], notion_status, result_summary)
    status_msg = f" Status→{notion_status}" if notion_status else ""
    print(f"  UPDATED{status_msg}")
    return True


def main():
    env = load_env()
    api_key = env.get("NOTION_API_KEY")
    db_id = env.get("NOTION_DB_ID")

    if not api_key or not db_id:
        print("ERROR: NOTION_API_KEY and NOTION_DB_ID must be set in ~/.myndaix/.env")
        sys.exit(1)

    # If a specific file is given, process just that
    if len(sys.argv) > 1:
        target_files = [Path(sys.argv[1])]
    else:
        synced = load_synced_set()
        target_files = [
            f for f in sorted(PROCESSED_DIR.glob("*.md"))
            if f.name not in synced
        ]

    if not target_files:
        return

    pages = query_database(api_key, db_id)

    synced_count = 0
    skipped_count = 0
    error_count = 0
    for f in target_files:
        if not f.exists():
            continue
        try:
            if sync_file(f, api_key, db_id, pages):
                save_synced(f.name)
                synced_count += 1
            else:
                save_synced(f.name)  # mark non-matching files done; stops retry
                skipped_count += 1
        except Exception as e:
            print(f"  ERROR {f.name}: {e}")
            error_count += 1

    if synced_count > 0 or error_count > 0:
        print(f"Synced {synced_count}, skipped {skipped_count}, errors {error_count} (of {len(target_files)} attempted).")


if __name__ == "__main__":
    main()
