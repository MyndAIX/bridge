#!/usr/bin/env node
/**
 * MyndAIX Message Daemon v2.0.0 — Phase 0 Redesign
 *
 * Daemon NO LONGER routes or moves files. Watchers read directly from inbox/.
 *
 * What it does:
 *  1. Watches inbox/<agent>/ dirs for new .md files
 *  2. If agent has a watcher → spawn it
 *  3. If agent has no watcher (lobster, mack) → do nothing
 *  4. Heartbeat every 5 min
 *  5. Health checks every 60s (monitors inbox age, not stale heartbeat files)
 */

import fs from "fs/promises";
import { openSync, watch as fsWatch } from "node:fs";
import { spawn } from "node:child_process";
import path from "path";
import os from "os";

// ── Config ────────────────────────────────────────────────────────────────────

const BRIDGE_ROOT = path.join(os.homedir(), ".myndaix/bridge");
const INBOX_ROOT = path.join(BRIDGE_ROOT, "inbox");
const STATE_ROOT = path.join(BRIDGE_ROOT, "state");
const QUARANTINE_ROOT = path.join(BRIDGE_ROOT, "quarantine");
const LOG_FILE = path.join(BRIDGE_ROOT, "watchers/daemon.log");
// Per-machine heartbeat to avoid Syncthing conflicts
const MACHINE_ID = os.userInfo().username === "stevenfernandez" ? "macbook" : "mini";
const HEARTBEAT_FILE = path.join(STATE_ROOT, `daemon-heartbeat-${MACHINE_ID}.json`);

const AGENTS = ["lobster", "mack", "antman", "kilabz", "mini", "recon", "oracle", "harley"];

// Agents with watchers — daemon spawns these on file events
const WATCHER_AGENTS = {
  mini: true,
  antman: true,
  kilabz: true,
  recon: true,
  oracle: true,
  harley: true,
  lobster: false,
  mack: false,
};

// Only check health for watchers on THIS machine
const LOCAL_WATCHERS = os.userInfo().username === "stevenfernandez"
  ? ["mack"]
  : ["mini", "antman", "kilabz", "recon", "oracle", "harley"];

const HEARTBEAT_INTERVAL_MS = 5 * 60 * 1000;
const HEALTH_CHECK_INTERVAL_MS = 60 * 1000;
const STALE_INBOX_MS = 30 * 60 * 1000; // 30 min — if tasks sitting in inbox for 30 min, watcher may be down
const DEBOUNCE_MS = 500;

// ── Logging ───────────────────────────────────────────────────────────────────

async function log(msg) {
  const line = `[${new Date().toISOString()}] [daemon] ${msg}\n`;
  process.stderr.write(line);
  try {
    await fs.appendFile(LOG_FILE, line);
  } catch { /* best effort */ }
}

// ── Ensure directories ───────────────────────────────────────────────────────

async function ensureDirs() {
  for (const agent of AGENTS) {
    await fs.mkdir(path.join(INBOX_ROOT, agent), { recursive: true });
  }
  await fs.mkdir(STATE_ROOT, { recursive: true });
  await fs.mkdir(QUARANTINE_ROOT, { recursive: true });
  await fs.mkdir(path.dirname(LOG_FILE), { recursive: true });
}

// ── Startup cleanup ──────────────────────────────────────────────────────────

async function startupCleanup() {
  const locksDir = path.join(BRIDGE_ROOT, "locks");
  const processedDir = path.join(BRIDGE_ROOT, "processed");
  const dedupeDir = path.join(STATE_ROOT, "dedupe");

  // Clean stale locks (PID-verified)
  try {
    const entries = await fs.readdir(locksDir, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isDirectory() || !entry.name.endsWith(".lock")) continue;
      const pidFile = path.join(locksDir, entry.name, "pid");
      try {
        const pid = parseInt(await fs.readFile(pidFile, "utf8"), 10);
        try { process.kill(pid, 0); } catch {
          // PID is dead — remove lock
          await fs.rm(path.join(locksDir, entry.name), { recursive: true });
          await log(`CLEANUP: removed stale lock ${entry.name} (PID ${pid} dead)`);
        }
      } catch { /* no pid file — remove orphan lock */
        await fs.rm(path.join(locksDir, entry.name), { recursive: true });
        await log(`CLEANUP: removed orphan lock ${entry.name}`);
      }
    }
  } catch { /* locks dir may not exist */ }

  // Clean old processed files (>30 days)
  try {
    const now = Date.now();
    const thirtyDays = 30 * 24 * 60 * 60 * 1000;
    const files = await fs.readdir(processedDir);
    let cleaned = 0;
    for (const file of files) {
      try {
        const stat = await fs.stat(path.join(processedDir, file));
        if (now - stat.mtimeMs > thirtyDays) {
          await fs.unlink(path.join(processedDir, file));
          cleaned++;
        }
      } catch { /* skip */ }
    }
    if (cleaned > 0) await log(`CLEANUP: removed ${cleaned} processed files older than 30 days`);
  } catch { /* dir may not exist */ }

  // Truncate large log files (>5MB)
  const logsDir = path.join(BRIDGE_ROOT, "logs");
  const MAX_LOG_BYTES = 5 * 1024 * 1024; // 5MB
  try {
    const logFiles = await fs.readdir(logsDir);
    for (const file of logFiles) {
      if (!file.endsWith(".log")) continue;
      const logPath = path.join(logsDir, file);
      try {
        const stat = await fs.stat(logPath);
        if (stat.size > MAX_LOG_BYTES) {
          // Keep last 1MB, truncate the rest
          const content = await fs.readFile(logPath, "utf8");
          const keepBytes = 1024 * 1024;
          await fs.writeFile(logPath, content.slice(-keepBytes));
          await log(`CLEANUP: truncated ${file} (${(stat.size / 1024 / 1024).toFixed(1)}MB → 1MB)`);
        }
      } catch { /* skip */ }
    }
  } catch { /* logs dir may not exist */ }

  // Clean old dedupe markers (>7 days)
  try {
    const now = Date.now();
    const sevenDays = 7 * 24 * 60 * 60 * 1000;
    const entries = await fs.readdir(dedupeDir);
    let cleaned = 0;
    for (const entry of entries) {
      try {
        const stat = await fs.stat(path.join(dedupeDir, entry));
        if (now - stat.mtimeMs > sevenDays) {
          await fs.rm(path.join(dedupeDir, entry), { recursive: true });
          cleaned++;
        }
      } catch { /* skip */ }
    }
    if (cleaned > 0) await log(`CLEANUP: removed ${cleaned} dedupe markers older than 7 days`);
  } catch { /* dir may not exist */ }
}

// ── Debounce tracker ─────────────────────────────────────────────────────────

const recentlyProcessed = new Map();

function shouldProcess(filePath) {
  const now = Date.now();
  const last = recentlyProcessed.get(filePath);
  if (last && (now - last) < DEBOUNCE_MS) return false;
  recentlyProcessed.set(filePath, now);
  if (recentlyProcessed.size > 200) {
    for (const [k, v] of recentlyProcessed) {
      if (now - v > 60000) recentlyProcessed.delete(k);
    }
  }
  return true;
}

// ── Security scanning ────────────────────────────────────────────────────────

const SCANNER_SCRIPT = path.join(BRIDGE_ROOT, "scripts/scan-inbound.sh");

async function scanInboundFile(filePath) {
  try {
    // Check if scanner script exists
    await fs.access(SCANNER_SCRIPT);
  } catch {
    await log(`SECURITY: Scanner script not found at ${SCANNER_SCRIPT}, allowing file through`);
    return true; // Allow file through if scanner is missing
  }

  try {
    const { spawn } = await import("node:child_process");
    const { promisify } = await import("util");

    // Spawn scanner process
    const child = spawn("/bin/bash", [SCANNER_SCRIPT, filePath], {
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, LANG: "en_US.UTF-8", LC_ALL: "en_US.UTF-8" },
    });

    // Wait for process to complete
    const exitCode = await new Promise((resolve) => {
      child.on("close", resolve);
    });

    switch (exitCode) {
      case 0:
        await log(`SECURITY: File cleared - ${filePath}`);
        return true; // Safe to process
      case 1:
        await log(`SECURITY: File quarantined - ${filePath}`);
        return false; // File was quarantined
      default:
        await log(`SECURITY: Scanner error (code ${exitCode}) - ${filePath}`);
        return true; // Allow through on scanner error to avoid breaking flow
    }
  } catch (e) {
    await log(`SECURITY ERROR: Failed to scan ${filePath} - ${e.message}`);
    return true; // Allow through on error to avoid breaking flow
  }
}

// ── Spawn watcher on demand ──────────────────────────────────────────────────

const WATCHERS_DIR = path.join(BRIDGE_ROOT, "watchers");

async function spawnWatcher(agent) {
  const script = path.join(WATCHERS_DIR, `${agent}-watcher.sh`);
  try {
    await fs.access(script);
  } catch {
    return; // no script, skip silently
  }
  try {
    const out = openSync(`/tmp/${agent}-watcher.log`, "a");
    const err = openSync(`/tmp/${agent}-watcher-err.log`, "a");
    const child = spawn("/bin/bash", [script], {
      detached: true,
      stdio: ["ignore", out, err],
      env: { ...process.env, LANG: "en_US.UTF-8", LC_ALL: "en_US.UTF-8" },
    });
    child.unref();
    await log(`SPAWN: triggered ${agent}-watcher (pid: ${child.pid})`);
  } catch (e) {
    await log(`SPAWN ERROR ${agent}: ${e.message}`);
  }
}

// ── File event handler ──────────────────────────────────────────────────────

async function handleFileEvent(filePath) {
  const filename = path.basename(filePath);

  // Skip non-md, temp, syncthing files
  if (!filename.endsWith(".md")) return;
  if (filename.startsWith(".")) return;
  if (filename.includes("~syncthing~") || filename.includes(".syncthing.")) return;
  if (filename.endsWith(".tmp")) return;

  // Ghost-event guard: file may have been moved/deleted before handler fires
  try {
    await fs.access(filePath);
  } catch {
    return; // file gone — suppress silently
  }

  if (!shouldProcess(filePath)) return;

  // Figure out which agent's inbox
  const rel = path.relative(INBOX_ROOT, filePath);
  const agent = rel.split(path.sep)[0];
  if (!AGENTS.includes(agent)) return;

  // Security scan before processing
  const isSafe = await scanInboundFile(filePath);
  if (!isSafe) {
    await log(`SECURITY: File quarantined, skipping watcher spawn - ${filePath}`);
    return; // File was quarantined, don't process further
  }

  await log(`EVENT: inbox/${agent}/${filename}`);

  // If agent has a watcher, spawn it
  if (WATCHER_AGENTS[agent]) {
    await spawnWatcher(agent);
  }
  // Otherwise do nothing — file stays in inbox for interactive session to read
}

// ── Heartbeat ────────────────────────────────────────────────────────────────

async function writeHeartbeat() {
  const data = {
    agent: "daemon",
    version: "2.0.0",
    pid: process.pid,
    last_beat: new Date().toISOString(),
    uptime_seconds: Math.floor(process.uptime()),
    watching: AGENTS,
  };
  try {
    await fs.writeFile(HEARTBEAT_FILE, JSON.stringify(data, null, 2));
  } catch { /* best effort */ }
}

// ── Health checks (inbox age based) ─────────────────────────────────────────

const alertedAgents = new Set();

async function checkWatcherHealth() {
  const now = Date.now();

  for (const agent of LOCAL_WATCHERS) {
    if (!WATCHER_AGENTS[agent]) continue;

    const inboxDir = path.join(INBOX_ROOT, agent);
    let files;
    try {
      const allFiles = await fs.readdir(inboxDir);
      files = allFiles.filter(f => f.endsWith(".md") && !f.startsWith(".") && !f.includes("~syncthing~"));
    } catch { continue; }

    if (files.length === 0) {
      alertedAgents.delete(agent);
      continue;
    }

    // Check oldest file age
    let oldestAge = 0;
    for (const file of files) {
      try {
        const stat = await fs.stat(path.join(inboxDir, file));
        const age = now - stat.mtimeMs;
        if (age > oldestAge) oldestAge = age;
      } catch { /* skip */ }
    }

    if (oldestAge > STALE_INBOX_MS) {
      if (!alertedAgents.has(agent)) {
        const staleMin = Math.floor(oldestAge / 60000);
        const msg = `ALERT: ${agent}-watcher may be down — ${files.length} file(s) in inbox, oldest ${staleMin}m`;
        await log(msg);
        await writeAlert(agent, msg, files.length, staleMin);
        alertedAgents.add(agent);
      }
    } else {
      alertedAgents.delete(agent);
    }
  }
}

async function writeAlert(agent, message, fileCount, staleMinutes) {
  const alertFile = path.join(INBOX_ROOT, "lobster", `alert-${agent}-watcher-${Date.now()}.md`);
  const content = `---
id: alert-${agent}-${Date.now()}
from: daemon
to: lobster
type: status
subject: "ALERT: ${agent}-watcher down"
priority: urgent
status: pending
created: ${new Date().toISOString()}
---

## Watcher Health Alert

**Agent:** ${agent}
**Status:** DOWN (${fileCount} file(s) sitting in inbox for ${staleMinutes}+ minutes)
**Message:** ${message}
`;
  try {
    const tmpFile = `${alertFile}.tmp.${process.pid}`;
    await fs.writeFile(tmpFile, content);
    await fs.rename(tmpFile, alertFile);
  } catch (err) {
    await log(`ERROR writing alert: ${err.message}`);
  }
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  // ── Singleton lock — prevent duplicate daemon instances ────────────────────
  const PID_FILE = path.join(STATE_ROOT, "daemon.pid");
  await fs.mkdir(STATE_ROOT, { recursive: true });
  try {
    const existingPid = parseInt(await fs.readFile(PID_FILE, "utf8"), 10);
    if (existingPid && existingPid !== process.pid) {
      try {
        process.kill(existingPid, 0); // throws if dead
        console.error(`[daemon] FATAL: Another daemon is already running (PID ${existingPid}). Exiting.`);
        process.exit(1);
      } catch {
        // PID is dead — stale lock, safe to overwrite
      }
    }
  } catch {
    // No PID file — first run
  }
  await fs.writeFile(PID_FILE, String(process.pid));
  // Clean up PID file on exit (use imported fs sync via fsSync)
  const { unlinkSync } = await import("node:fs");
  const cleanup = () => { try { unlinkSync(PID_FILE); } catch {} };
  process.on("exit", cleanup);
  process.on("SIGINT", () => { cleanup(); process.exit(0); });
  process.on("SIGTERM", () => { cleanup(); process.exit(0); });

  await ensureDirs();
  await startupCleanup();

  await log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  await log(`MyndAIX Daemon v2.0.0 starting (pid: ${process.pid})`);
  await log(`Watchers read directly from inbox/ — no routing, no queue/`);
  await log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

  // Native fs.watch on each agent's inbox dir
  const watchers = [];
  for (const agent of AGENTS) {
    const dir = path.join(INBOX_ROOT, agent);
    try {
      const w = fsWatch(dir, (eventType, filename) => {
        if (!filename || !filename.endsWith(".md")) return;
        if (filename.startsWith(".") || filename.includes("~syncthing~") || filename.endsWith(".tmp")) return;
        const filePath = path.join(dir, filename);
        handleFileEvent(filePath).catch(err => {
          log(`ERROR in handleFileEvent: ${err.message}`).catch(() => {});
        });
      });
      watchers.push(w);
    } catch (err) {
      await log(`ERROR watching inbox/${agent}/: ${err.message}`);
    }
  }

  // Heartbeat loop
  await writeHeartbeat();
  setInterval(async () => {
    await writeHeartbeat();
  }, HEARTBEAT_INTERVAL_MS);

  // Health check loop
  setInterval(async () => {
    try {
      await checkWatcherHealth();
    } catch (err) {
      await log(`ERROR in health check: ${err.message}`);
    }
  }, HEALTH_CHECK_INTERVAL_MS);

  // Graceful shutdown
  for (const signal of ["SIGINT", "SIGTERM"]) {
    process.on(signal, async () => {
      await log(`Received ${signal}, shutting down`);
      watchers.forEach(w => w.close());
      process.exit(0);
    });
  }

  await log("Daemon ready — watching inbox/ dirs, spawning watchers on events");
}

main().catch(async (err) => {
  await log(`FATAL: ${err.message}`);
  process.exit(1);
});
