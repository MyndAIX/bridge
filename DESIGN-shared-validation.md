## DESIGN.md: Shared Validation Library (lib/validate.sh)

### What
A single shared validation library that every runner and hook sources for input parsing, output sanitization, and pre-task gates. Replaces per-agent inline validation with one canonical implementation.

### Why
Security enforcement currently lives only in Mack's Claude Code hooks (`~/.claude/settings.json`). Mini, KilaBz, Antman, and Recon runners have no equivalent gates. This means:
- Prompt injection defenses only exist on MacBook — Mini processes untrusted task content with no sanitization
- Fail-open parsing bugs fixed in one hook but not replicated in runners
- Deploy/dispatch gates only block Mack — Mini can deploy uncommitted code freely
- Each runner has its own ad-hoc parsing (duplicated, inconsistent, some missing entirely)

If any agent is compromised or receives malicious input, the weakest runner is the entry point — not the strongest hook.

### Oracle Review (Phase 0) — All findings addressed

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 1 | P1 | Undefined prompt injection patterns in sanitize_output | Source from existing `patterns.yaml` (scanner already maintains this) |
| 2 | P1 | Task cap counter race condition | Atomic `mkdir` lock around counter read-write |
| 3 | P2 | No automated checksum verification for validate.sh | SHA256 verify before source, fail if mismatch |
| 4 | P2 | Overly aggressive frontmatter sanitization (tr -d '\n\r' on all fields) | Per-field sanitization: control chars on single-value fields only, multi-line fields preserved |
| 5 | P3 | Version in separate file is brittle | Version variable inside validate.sh itself |
| 6 | P3 | Implicit python3 dependency | `command -v python3` check at library load |

### Data Flow

```
Task arrives (inbox .md file)
        │
        ▼
┌─────────────────────────┐
│  Runner picks up task    │
│  (mini/mack/antman/etc)  │
│         │                │
│         ▼                │
│  ┌─────────────────┐    │
│  │ validate.sh      │    │
│  │ (SHA256 verified) │    │
│  │                  │    │
│  │ parse_frontmatter│───→ Fail closed on malformed YAML
│  │ sanitize_input   │───→ Strip control chars, length cap, data fence
│  │ pre_task_gate    │───→ Check: git clean, scope valid, task cap (atomic lock)
│  │ sanitize_output  │───→ Clean results using patterns.yaml before downstream inject
│  │ safe_json        │───→ python3 json.dumps for all JSON generation
│  └─────────────────┘    │
│         │                │
│         ▼                │
│  Execute task            │
│         │                │
│         ▼                │
│  sanitize_output()       │
│  before writing result   │
└─────────────────────────┘
```

### Functions

```
# --- Library header ---
VALIDATE_LIB_VERSION="1.0.0"  # P3-1: version inside script, not separate file
command -v python3 >/dev/null || { echo "FATAL: python3 not found"; exit 1; }  # P3-2

parse_frontmatter(file)
  - Extract YAML frontmatter fields
  - Fail closed: return 1 if frontmatter missing or malformed
  - Per-field sanitization (P2-2):
    - Single-value fields (from, to, type, subject, tier): strip control chars + newlines
    - Multi-line fields (objective, done_criteria, scope): strip control chars only, preserve newlines
  - Validate required fields: from, to, type, subject

sanitize_input(string, max_len)
  - Strip control chars (non-printable except \n \t)
  - Cap length (default 10000)
  - Strip closing data fence tags (</task_content>, </user_input>)
  - Return cleaned string

sanitize_output(string, max_len)
  - Same as sanitize_input
  - PLUS: match against patterns from patterns.yaml (P1-1)
    - Load patterns via: grep -v '^#' "$BRIDGE_DIR/patterns.yaml" | extract regex lines
    - Strip or flag matches (graduated: warn on low score, strip on high score)
  - Used on agent results before injecting into downstream prompts

safe_json(key, value, ...)
  - Generate JSON via python3 json.dumps
  - All values escaped properly — no heredoc interpolation
  - Accepts key-value pairs, outputs valid JSON object
  - Input via sys.argv only

pre_task_gate(task_file)
  - Check 1: git status clean in target repo (if repo specified)
  - Check 2: task from trusted sender (shared trusted-senders.conf)
  - Check 3: daily task cap not exceeded
    - Counter: state/task-count-YYYYMMDD.txt
    - Atomic lock via mkdir state/task-count.lock (P1-2)
    - Read → increment → write inside lock
    - Stale lock timeout: 30 seconds
  - Check 4: scope fields present for review tasks
  - Returns 0 (proceed) or 1 (blocked) with reason on stderr

fail_closed_deny(reason)
  - Standard deny output for hooks (JSON format)
  - Logs denial to bridge/logs/denials.log
```

### Edge Cases
- **validate.sh not found on a machine:** Runner must `source` with explicit check — `source "$LIB_DIR/validate.sh" || { echo "FATAL: validate.sh missing"; exit 1; }`. Never silently skip.
- **SHA256 mismatch:** Runner refuses to source and exits with FATAL. Logs which hash was expected vs found. Operator must investigate (could be Syncthing lag or tampering).
- **Syncthing lag:** If validate.sh is updated on MacBook but hasn't synced to Mini, machines run different versions. Mitigation: `VALIDATE_LIB_VERSION` logged on every task. SHA256 mismatch blocks execution until sync completes — this is intentional (fail closed > stale code).
- **Large task content:** sanitize_input caps at 10000 chars by default. Tasks with large code payloads need explicit override (`sanitize_input "$content" 50000`).
- **Runner already has inline validation:** Migration is incremental — replace inline code with function calls one runner at a time. Don't rewrite all runners in one shot.
- **Empty/corrupt frontmatter from trusted sender:** Fail closed even for trusted senders on missing required fields. Trust means skip quarantine, not skip validation.
- **patterns.yaml missing or empty:** sanitize_output falls back to sanitize_input only (no pattern matching). Logs warning — does not fail closed here because pattern matching is defense-in-depth, not the only gate.
- **Task cap lock stale:** If lock dir exists but is older than 30 seconds, forcibly remove and re-acquire. Prevents deadlock from crashed runner.

### Security Surface
- **validate.sh itself is a high-value target** — if an attacker modifies it, all runners are compromised. Mitigations:
  - File owned by user, chmod 755
  - SHA256 checksum verified before every source (P2-1)
  - Checksum stored in `lib/validate.sh.sha256` — runners verify with `shasum -a 256 -c`
  - Checksum file itself protected by same ownership/permissions
- **Environment variable injection:** Functions must not read from arbitrary env vars. All input via function arguments.
- **Python subprocess:** `safe_json` spawns python3 — input passed via sys.argv, never interpolated into -c strings.
- **Shared config files** (trusted-senders.conf, deploy-targets.conf, patterns.yaml) must be locked during reads if writers are concurrent. For read-only consumers (most runners), no lock needed — atomic mv on write side is sufficient.
- **Task cap counter:** Protected by mkdir atomic lock. Stale lock cleaned after 30s timeout.

### Files
- **Create:** `lib/validate.sh` — the shared library (includes VALIDATE_LIB_VERSION)
- **Create:** `lib/validate.sh.sha256` — checksum for integrity verification
- **Create:** `state/trusted-senders.conf` — canonical trusted sender list (currently hardcoded in multiple places)
- **Create:** `tests/test_validate.sh` — smoke tests for every function
- **Modify:** `watchers/mini-runner.sh` — source validate.sh, replace inline parsing
- **Modify:** `watchers/mack-runner.sh` — source validate.sh, replace inline parsing
- **Modify:** `watchers/mack-watcher.sh` — source validate.sh for frontmatter parsing
- **Modify:** `hooks/pre-dispatch-gate.sh` — use safe_json(), sanitize_input()
- **Modify:** `hooks/new-script-warning.sh` — use safe_json()

### Dependencies
- **python3** — required on both machines for safe_json (verified at library load)
- **shasum** — macOS built-in, used for SHA256 verification
- **Syncthing** — syncs lib/ between MacBook and Mini (already configured)
- **patterns.yaml** — existing scanner pattern file, reused for sanitize_output
- **No new external deps**

### Migration Plan
1. Build validate.sh + tests — no runners touched yet
2. Generate SHA256 checksum file
3. Wire into hooks first (pre-dispatch-gate, new-script-warning) — lowest risk, immediate value
4. Wire into mack-runner.sh + mack-watcher.sh — test on MacBook
5. Deploy to Mini via Syncthing, wire into mini-runner.sh
6. Wire into remaining watchers (antman, kilabz) last
7. Each step: run test_validate.sh, confirm no regressions in task processing

### What This Does NOT Cover
- SQLite migration (separate initiative — replaces file-based state)
- Claim-and-lock inbox redesign (depends on SQLite)
- Scanner pattern updates (scanner already has its own validation)
- Agent permission scoping (already handled by --allowedTools JSON profiles)
