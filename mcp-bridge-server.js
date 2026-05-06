#!/usr/bin/env node
/**
 * MyndAIX Bridge MCP Server v3.1.0
 * Named inboxes per agent. No messages/ split. All routes through inbox/.
 * v3.1: Resilient frontmatter parsing, no silent file drops, bridge_repair tool.
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import fs from "fs/promises";
import path from "path";
import os from "os";
import { execSync } from "child_process";

const BRIDGE_ROOT = path.join(os.homedir(), ".myndaix/bridge");
const AGENTS = ["lobster", "mack", "antman", "kilabz", "mini", "recon", "oracle", "harley"];

// Backwards compatibility: old names resolve to new names
const AGENT_ALIASES = {
  claude: "lobster",
  builder: "antman",
  "codex-review": "kilabz",
  codex: "mack",
  gemini: "mack",
};

// All agents + aliases accepted as valid recipients
const ALL_VALID_TARGETS = [...AGENTS, ...Object.keys(AGENT_ALIASES)];

// Resolve an agent name through aliases
function resolveAgent(name) {
  if (!name) return name;
  const lower = name.toLowerCase().trim();
  return AGENT_ALIASES[lower] || lower;
}

// Determine "from" identity based on which machine is running this MCP
function getIdentity() {
  const user = os.userInfo().username;
  if (user === "stevenfernandez") return "mack";
  return "lobster"; // Mini (jefe) or fallback
}

// Valid state transitions for the task state machine
const VALID_TRANSITIONS = {
  pending:  ["claimed"],
  claimed:  ["building"],
  building: ["review"],
  review:   ["approved", "rejected"],
  approved: ["merged"],
  rejected: ["building"],
  merged:   [],
};

// Ensure directories exist
async function ensureDirs() {
  for (const agent of AGENTS) {
    await fs.mkdir(path.join(BRIDGE_ROOT, "inbox", agent), { recursive: true });
  }
  await fs.mkdir(path.join(BRIDGE_ROOT, "archive"), { recursive: true });
}

// Generate timestamp-based ID
function generateId(subject) {
  const now = new Date();
  const ts = now.toISOString().replace(/[-:T]/g, "").slice(0, 14);
  const slug = subject.toLowerCase().replace(/[^a-z0-9]+/g, "-").slice(0, 30);
  return `${ts}-${slug}`;
}

// Atomic write (temp then rename)
async function atomicWrite(filePath, content) {
  const tempPath = `${filePath}.tmp.${process.pid}`;
  await fs.writeFile(tempPath, content, "utf8");
  await fs.rename(tempPath, filePath);
}

// Parse frontmatter from message
// Resilient: handles BOM, CRLF, leading whitespace, and plain markdown (no frontmatter)
function parseFrontmatter(content) {
  // Normalize: strip BOM, normalize line endings, trim leading whitespace
  const normalized = content.replace(/^\uFEFF/, "").replace(/\r\n/g, "\n").trimStart();
  const match = normalized.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!match) return null;

  const frontmatter = {};
  match[1].split("\n").forEach(line => {
    if (!line.trim()) return; // skip blank lines inside frontmatter
    const colonIdx = line.indexOf(":");
    if (colonIdx > 0) {
      const key = line.slice(0, colonIdx).trim();
      const value = line.slice(colonIdx + 1).trim();
      if (key && value) frontmatter[key] = value;
    }
  });

  return { frontmatter, body: match[2] };
}

// Extract best-effort metadata from a plain markdown file (no frontmatter)
function parsePlainMarkdown(content, filename) {
  const lines = content.split("\n").filter(l => l.trim());
  const heading = lines.find(l => l.startsWith("# "));
  return {
    frontmatter: {
      id: filename.replace(/\.md$/, ""),
      from: "unknown",
      to: "unknown",
      type: "unknown",
      subject: heading ? heading.replace(/^#\s*/, "").slice(0, 80) : "(no subject)",
      status: "unknown",
      created: null,
      _malformed: true,
    },
    body: content,
  };
}

// Serialize frontmatter back to string
function serializeFrontmatter(frontmatter, body) {
  const lines = Object.entries(frontmatter)
    .filter(([_, v]) => v !== undefined && v !== "")
    .map(([k, v]) => `${k}: ${v}`);
  return `---\n${lines.join("\n")}\n---\n${body}`;
}

// Validate required frontmatter fields
function validateMessage(frontmatter) {
  const required = ["id", "from", "to", "subject", "status"];
  const missing = required.filter(f => !frontmatter[f]);
  if (missing.length) {
    throw new Error(`Missing required fields: ${missing.join(", ")}`);
  }
  const resolved = resolveAgent(frontmatter.to);
  if (!AGENTS.includes(resolved)) {
    throw new Error(`Invalid recipient: ${frontmatter.to}. Must be one of: ${AGENTS.join(", ")}`);
  }
}

const server = new Server(
  { name: "myndaix-bridge", version: "3.1.0" },
  { capabilities: { tools: {} } }
);

// List available tools
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "bridge_send",
      description: "Send a message to another agent via the MyndAIX bridge",
      inputSchema: {
        type: "object",
        properties: {
          to: { type: "string", enum: ALL_VALID_TARGETS, description: "Target agent (lobster, mack, antman, kilabz)" },
          subject: { type: "string", description: "Message subject" },
          body: { type: "string", description: "Message body (markdown)" },
          type: { type: "string", enum: ["task", "response", "question", "handoff", "status"], default: "task", description: "Message type" },
          priority: { type: "string", enum: ["normal", "urgent"], default: "normal" },
          project: { type: "string", description: "Related project path (optional)" }
        },
        required: ["to", "subject", "body"]
      },
      annotations: { readOnlyHint: false, openWorldHint: false, destructiveHint: false }
    },
    {
      name: "bridge_send_with_diff",
      description: "Send a message with an auto-attached git diff from a project",
      inputSchema: {
        type: "object",
        properties: {
          to: { type: "string", enum: ALL_VALID_TARGETS, description: "Target agent (lobster, mack, antman, kilabz)" },
          subject: { type: "string", description: "Message subject" },
          body: { type: "string", description: "Message body (markdown)" },
          type: { type: "string", enum: ["task", "response", "question", "handoff", "status"], default: "task" },
          priority: { type: "string", enum: ["normal", "urgent"], default: "normal" },
          project: { type: "string", description: "Project path to run git diff in (required)" },
          git_ref: { type: "string", description: "Git diff ref range (default: HEAD~1..HEAD)", default: "HEAD~1..HEAD" }
        },
        required: ["to", "subject", "body", "project"]
      },
      annotations: { readOnlyHint: false, openWorldHint: false, destructiveHint: false }
    },
    {
      name: "bridge_list",
      description: "List messages in an agent's inbox. By default only shows messages from the last 24 hours. Use max_age_hours=0 to see all.",
      inputSchema: {
        type: "object",
        properties: {
          inbox: { type: "string", enum: ALL_VALID_TARGETS, description: "Which agent's inbox to list (lobster, mack, antman, kilabz)" },
          status: { type: "string", enum: ["pending", "claimed", "building", "review", "approved", "rejected", "merged", "in_progress", "complete", "all"], default: "all" },
          max_age_hours: { type: "number", description: "Only show messages newer than this many hours (default: 24, use 0 for all)", default: 24 }
        },
        required: ["inbox"]
      },
      annotations: { readOnlyHint: true, openWorldHint: false, destructiveHint: false }
    },
    {
      name: "bridge_read",
      description: "Read a message by filename",
      inputSchema: {
        type: "object",
        properties: {
          inbox: { type: "string", enum: ALL_VALID_TARGETS, description: "Which agent's inbox" },
          filename: { type: "string", description: "Message filename" }
        },
        required: ["inbox", "filename"]
      },
      annotations: { readOnlyHint: true, openWorldHint: false, destructiveHint: false }
    },
    {
      name: "bridge_reply",
      description: "Reply to a message (creates response in sender's inbox)",
      inputSchema: {
        type: "object",
        properties: {
          original_inbox: { type: "string", enum: ALL_VALID_TARGETS, description: "Inbox containing original message" },
          original_filename: { type: "string", description: "Original message filename" },
          body: { type: "string", description: "Reply body (markdown)" }
        },
        required: ["original_inbox", "original_filename", "body"]
      },
      annotations: { readOnlyHint: false, openWorldHint: false, destructiveHint: false }
    },
    {
      name: "bridge_archive",
      description: "Archive a processed message",
      inputSchema: {
        type: "object",
        properties: {
          inbox: { type: "string", enum: ALL_VALID_TARGETS, description: "Which agent's inbox" },
          filename: { type: "string", description: "Message filename" }
        },
        required: ["inbox", "filename"]
      },
      annotations: { readOnlyHint: false, openWorldHint: false, destructiveHint: true }
    },
    {
      name: "bridge_approve",
      description: "Approve a message: updates status to approved, notifies sender, archives original",
      inputSchema: {
        type: "object",
        properties: {
          inbox: { type: "string", enum: ALL_VALID_TARGETS, description: "Inbox containing the message" },
          filename: { type: "string", description: "Message filename" }
        },
        required: ["inbox", "filename"]
      },
      annotations: { readOnlyHint: false, openWorldHint: false, destructiveHint: false }
    },
    {
      name: "bridge_reject",
      description: "Reject a message with a reason: updates status, notifies sender, keeps in inbox for rework",
      inputSchema: {
        type: "object",
        properties: {
          inbox: { type: "string", enum: ALL_VALID_TARGETS, description: "Inbox containing the message" },
          filename: { type: "string", description: "Message filename" },
          reason: { type: "string", description: "Rejection reason" }
        },
        required: ["inbox", "filename", "reason"]
      },
      annotations: { readOnlyHint: false, openWorldHint: false, destructiveHint: false }
    },
    {
      name: "bridge_update_status",
      description: "Update a message's status following the state machine: pending→claimed→building→review→approved→merged (rejected→building for rework)",
      inputSchema: {
        type: "object",
        properties: {
          inbox: { type: "string", enum: ALL_VALID_TARGETS, description: "Inbox containing the message" },
          filename: { type: "string", description: "Message filename" },
          new_status: { type: "string", enum: ["pending", "claimed", "building", "review", "approved", "rejected", "merged"], description: "New status" }
        },
        required: ["inbox", "filename", "new_status"]
      },
      annotations: { readOnlyHint: false, openWorldHint: false, destructiveHint: false }
    },
    {
      name: "bridge_cleanup",
      description: "Archive stale messages older than max_age_hours (default: 24) from all inboxes or a specific inbox",
      inputSchema: {
        type: "object",
        properties: {
          inbox: { type: "string", enum: [...ALL_VALID_TARGETS, "all"], description: "Which inbox to clean (default: all)", default: "all" },
          max_age_hours: { type: "number", description: "Archive messages older than this many hours (default: 24)", default: 24 }
        },
        required: []
      }
    },
    {
      name: "bridge_dashboard",
      description: "View a summary dashboard of all messages across inboxes and archive: counts by status, by agent, and recent activity",
      inputSchema: {
        type: "object",
        properties: {},
        required: []
      },
      annotations: { readOnlyHint: true, openWorldHint: false, destructiveHint: false }
    },
    {
      name: "bridge_repair",
      description: "Scan inbox for malformed messages (missing YAML frontmatter) and rewrite them with proper frontmatter. Preserves content, adds missing metadata.",
      inputSchema: {
        type: "object",
        properties: {
          inbox: { type: "string", enum: [...ALL_VALID_TARGETS, "all"], description: "Which inbox to repair (default: all)", default: "all" },
          dry_run: { type: "boolean", description: "If true, report what would be fixed without writing (default: false)", default: false }
        },
        required: []
      },
      annotations: { readOnlyHint: false, openWorldHint: false, destructiveHint: false }
    }
  ]
}));

// Handle tool calls
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const identity = getIdentity();

  try {
    switch (name) {
      case "bridge_send": {
        const resolvedTo = resolveAgent(args.to);
        const id = generateId(args.subject);
        const timestamp = new Date().toISOString();
        const msgType = args.type || "task";

        const projectLine = args.project ? `\nproject: ${args.project}` : "";
        const content = `---
id: ${id}
from: ${identity}
to: ${resolvedTo}
type: ${msgType}
subject: ${args.subject}
priority: ${args.priority || "normal"}
status: pending
created: ${timestamp}${projectLine}
---

${args.body}
`;

        const targetDir = path.join(BRIDGE_ROOT, "inbox", resolvedTo);
        await fs.mkdir(targetDir, { recursive: true });
        const filePath = path.join(targetDir, `${id}.md`);
        await atomicWrite(filePath, content);

        return { content: [{ type: "text", text: `Message sent to ${resolvedTo}: ${filePath}` }] };
      }

      case "bridge_send_with_diff": {
        const resolvedTo = resolveAgent(args.to);
        const id = generateId(args.subject);
        const timestamp = new Date().toISOString();
        const gitRef = args.git_ref || "HEAD~1..HEAD";
        const msgType = args.type || "task";

        // Try to get git diff
        let diffSection = "";
        try {
          const diff = execSync(`git diff ${gitRef}`, {
            cwd: args.project,
            encoding: "utf8",
            timeout: 15000,
            maxBuffer: 1024 * 1024,
          });
          if (diff.trim()) {
            diffSection = `\n\n## Git Diff\n\n\`\`\`diff\n${diff}\n\`\`\`\n`;
          } else {
            diffSection = "\n\n## Git Diff\n\n_No changes detected for `" + gitRef + "`_\n";
          }
        } catch (err) {
          diffSection = `\n\n## Git Diff\n\n_Failed to get diff: ${err.message}_\n`;
        }

        const content = `---
id: ${id}
from: ${identity}
to: ${resolvedTo}
type: ${msgType}
subject: ${args.subject}
priority: ${args.priority || "normal"}
status: pending
created: ${timestamp}
project: ${args.project}
---

${args.body}${diffSection}`;

        const targetDir = path.join(BRIDGE_ROOT, "inbox", resolvedTo);
        await fs.mkdir(targetDir, { recursive: true });
        const filePath = path.join(targetDir, `${id}.md`);
        await atomicWrite(filePath, content);

        return { content: [{ type: "text", text: `Message with diff sent to ${resolvedTo}: ${filePath}` }] };
      }

      case "bridge_list": {
        const resolvedInbox = resolveAgent(args.inbox);
        const inboxPath = path.join(BRIDGE_ROOT, "inbox", resolvedInbox);
        const maxAgeHours = args.max_age_hours !== undefined ? args.max_age_hours : 24;
        const now = Date.now();

        // Diagnostics — track why files are included/excluded
        const diag = {
          inbox: resolvedInbox,
          path: inboxPath,
          filters: { max_age_hours: maxAgeHours, status: args.status || "(none)" },
          total_files: 0,
          md_files: 0,
          skipped_status: 0,
          skipped_age: 0,
          skipped_error: [],
          returned: 0,
        };

        const messages = [];
        let files;
        try {
          files = await fs.readdir(inboxPath);
        } catch (err) {
          diag.readdir_error = `${err.code || err.message}`;
          return { content: [{ type: "text", text: JSON.stringify({ messages: [], _diag: diag }, null, 2) }] };
        }

        diag.total_files = files.length;
        const mdFiles = files.filter(f => f.endsWith(".md"));
        diag.md_files = mdFiles.length;

        for (const file of mdFiles) {
          try {
            const content = await fs.readFile(path.join(inboxPath, file), "utf8");
            const parsed = parseFrontmatter(content) || parsePlainMarkdown(content, file);
            const fm = parsed.frontmatter;

            // Status filter (malformed files always pass — don't hide them)
            if (!fm._malformed && args.status !== "all" && args.status && fm.status !== args.status) {
              diag.skipped_status++;
              continue;
            }

            // Age filter (malformed files always pass — they have no created date)
            if (!fm._malformed && maxAgeHours > 0 && fm.created) {
              const createdAt = new Date(fm.created).getTime();
              if (!isNaN(createdAt) && (now - createdAt) > maxAgeHours * 3600 * 1000) {
                diag.skipped_age++;
                continue;
              }
            }

            const entry = {
              filename: file,
              inbox: resolvedInbox,
              subject: fm.subject,
              from: fm.from,
              status: fm.status,
              priority: fm.priority || "unknown",
              created: fm.created,
            };
            if (fm._malformed) entry._warning = "No YAML frontmatter — use bridge_send or bridge_repair to fix";
            messages.push(entry);
          } catch (err) {
            diag.skipped_error.push({ file, error: err.message });
          }
        }

        diag.returned = messages.length;
        return { content: [{ type: "text", text: JSON.stringify({ messages, _diag: diag }, null, 2) }] };
      }

      case "bridge_read": {
        const resolvedInbox = resolveAgent(args.inbox);
        const filePath = path.join(BRIDGE_ROOT, "inbox", resolvedInbox, args.filename);
        const content = await fs.readFile(filePath, "utf8");
        return { content: [{ type: "text", text: content }] };
      }

      case "bridge_reply": {
        const resolvedInbox = resolveAgent(args.original_inbox);
        const filePath = path.join(BRIDGE_ROOT, "inbox", resolvedInbox, args.original_filename);
        const originalContent = await fs.readFile(filePath, "utf8");
        const original = parseFrontmatter(originalContent);

        if (!original) throw new Error("Could not parse original message");

        const resolvedSender = resolveAgent(original.frontmatter.from);
        const replyId = generateId(`re-${original.frontmatter.subject}`);
        const timestamp = new Date().toISOString();

        const replyContent = `---
id: ${replyId}
from: ${identity}
to: ${resolvedSender}
type: response
subject: Re: ${original.frontmatter.subject}
priority: ${original.frontmatter.priority || "normal"}
status: pending
created: ${timestamp}
in_reply_to: ${original.frontmatter.id}
---

${args.body}
`;

        // All replies go to inbox/{sender}/
        const replyDir = path.join(BRIDGE_ROOT, "inbox", resolvedSender);
        await fs.mkdir(replyDir, { recursive: true });
        const replyPath = path.join(replyDir, `${replyId}.md`);
        await atomicWrite(replyPath, replyContent);

        return { content: [{ type: "text", text: `Reply sent to ${resolvedSender}: ${replyPath}` }] };
      }

      case "bridge_archive": {
        const resolvedInbox = resolveAgent(args.inbox);
        const srcPath = path.join(BRIDGE_ROOT, "inbox", resolvedInbox, args.filename);
        const destPath = path.join(BRIDGE_ROOT, "archive", `${resolvedInbox}-${args.filename}`);
        await fs.rename(srcPath, destPath);
        return { content: [{ type: "text", text: `Archived: ${destPath}` }] };
      }

      case "bridge_approve": {
        const resolvedInbox = resolveAgent(args.inbox);
        const filePath = path.join(BRIDGE_ROOT, "inbox", resolvedInbox, args.filename);
        const content = await fs.readFile(filePath, "utf8");
        const parsed = parseFrontmatter(content);
        if (!parsed) throw new Error("Could not parse message");

        // Update status to approved
        parsed.frontmatter.status = "approved";
        const updatedContent = serializeFrontmatter(parsed.frontmatter, parsed.body);
        await atomicWrite(filePath, updatedContent);

        // Send approval notification to original sender
        const sender = resolveAgent(parsed.frontmatter.from);
        if (sender && AGENTS.includes(sender)) {
          const notifyId = generateId(`approved-${parsed.frontmatter.subject}`);
          const timestamp = new Date().toISOString();
          const notifyContent = `---
id: ${notifyId}
from: ${identity}
to: ${sender}
type: response
subject: Approved: ${parsed.frontmatter.subject}
priority: ${parsed.frontmatter.priority || "normal"}
status: pending
created: ${timestamp}
in_reply_to: ${parsed.frontmatter.id}
---

Your submission has been **approved**.

**Original:** ${parsed.frontmatter.subject}
`;
          const notifyPath = path.join(BRIDGE_ROOT, "inbox", sender, `${notifyId}.md`);
          await atomicWrite(notifyPath, notifyContent);
        }

        // Archive the original
        const destPath = path.join(BRIDGE_ROOT, "archive", `${resolvedInbox}-${args.filename}`);
        await fs.rename(filePath, destPath);

        return { content: [{ type: "text", text: `Approved and archived: ${parsed.frontmatter.subject}. Notification sent to ${sender}.` }] };
      }

      case "bridge_reject": {
        const resolvedInbox = resolveAgent(args.inbox);
        const filePath = path.join(BRIDGE_ROOT, "inbox", resolvedInbox, args.filename);
        const content = await fs.readFile(filePath, "utf8");
        const parsed = parseFrontmatter(content);
        if (!parsed) throw new Error("Could not parse message");

        // Update status to rejected (keep in inbox for rework)
        parsed.frontmatter.status = "rejected";
        const updatedContent = serializeFrontmatter(parsed.frontmatter, parsed.body);
        await atomicWrite(filePath, updatedContent);

        // Send rejection notification to original sender
        const sender = resolveAgent(parsed.frontmatter.from);
        if (sender && AGENTS.includes(sender)) {
          const notifyId = generateId(`rejected-${parsed.frontmatter.subject}`);
          const timestamp = new Date().toISOString();
          const notifyContent = `---
id: ${notifyId}
from: ${identity}
to: ${sender}
type: response
subject: Rejected: ${parsed.frontmatter.subject}
priority: ${parsed.frontmatter.priority || "normal"}
status: pending
created: ${timestamp}
in_reply_to: ${parsed.frontmatter.id}
---

Your submission has been **rejected**.

**Original:** ${parsed.frontmatter.subject}

**Reason:** ${args.reason}
`;
          const notifyPath = path.join(BRIDGE_ROOT, "inbox", sender, `${notifyId}.md`);
          await atomicWrite(notifyPath, notifyContent);
        }

        return { content: [{ type: "text", text: `Rejected: ${parsed.frontmatter.subject}. Kept in inbox for rework. Notification sent to ${sender}.` }] };
      }

      case "bridge_update_status": {
        const resolvedInbox = resolveAgent(args.inbox);
        const filePath = path.join(BRIDGE_ROOT, "inbox", resolvedInbox, args.filename);
        const content = await fs.readFile(filePath, "utf8");
        const parsed = parseFrontmatter(content);
        if (!parsed) throw new Error("Could not parse message");

        const currentStatus = parsed.frontmatter.status;
        const newStatus = args.new_status;

        // Validate state transition
        const allowed = VALID_TRANSITIONS[currentStatus];
        if (!allowed) {
          throw new Error(`Unknown current status: ${currentStatus}`);
        }
        if (!allowed.includes(newStatus)) {
          throw new Error(`Invalid transition: ${currentStatus} → ${newStatus}. Allowed: ${allowed.join(", ") || "none (terminal state)"}`);
        }

        // Update status atomically
        parsed.frontmatter.status = newStatus;
        const updatedContent = serializeFrontmatter(parsed.frontmatter, parsed.body);
        await atomicWrite(filePath, updatedContent);

        return { content: [{ type: "text", text: `Status updated: ${currentStatus} → ${newStatus} for ${args.filename}` }] };
      }

      case "bridge_cleanup": {
        const maxAgeHours = args.max_age_hours || 24;
        const now = Date.now();
        const cutoff = maxAgeHours * 3600 * 1000;
        const targetAgents = args.inbox === "all" || !args.inbox ? AGENTS : [resolveAgent(args.inbox)];
        let archived = 0;
        const details = [];

        for (const agent of targetAgents) {
          const dir = path.join(BRIDGE_ROOT, "inbox", agent);
          const files = await fs.readdir(dir).catch(() => []);
          const mdFiles = files.filter(f => f.endsWith(".md"));

          for (const file of mdFiles) {
            try {
              const content = await fs.readFile(path.join(dir, file), "utf8");
              const parsed = parseFrontmatter(content) || parsePlainMarkdown(content, file);
              const fm = parsed.frontmatter;

              // Malformed files with no created date: use file mtime as fallback
              let createdAt;
              if (fm.created) {
                createdAt = new Date(fm.created).getTime();
              } else {
                const stat = await fs.stat(path.join(dir, file));
                createdAt = stat.mtimeMs;
              }

              if (!isNaN(createdAt) && (now - createdAt) > cutoff) {
                const destPath = path.join(BRIDGE_ROOT, "archive", `${agent}-${file}`);
                await fs.rename(path.join(dir, file), destPath);
                archived++;
                details.push(`${agent}/${file} (${fm.subject})${fm._malformed ? " [malformed]" : ""}`);
              }
            } catch { /* skip */ }
          }
        }

        const summary = archived === 0
          ? `No stale messages found (threshold: ${maxAgeHours}h).`
          : `Archived ${archived} stale message(s):\n${details.map(d => `  - ${d}`).join("\n")}`;

        return { content: [{ type: "text", text: summary }] };
      }

      case "bridge_dashboard": {
        const statusCounts = {};
        const agentCounts = {};
        const allMessages = [];
        const dashDiag = { scanned: {}, errors: [] };

        // Scan all agent inboxes
        for (const agent of AGENTS) {
          const dirPath = path.join(BRIDGE_ROOT, "inbox", agent);
          let files;
          try {
            files = await fs.readdir(dirPath);
          } catch (err) {
            dashDiag.scanned[agent] = { error: err.code || err.message };
            continue;
          }
          const mdFiles = files.filter(f => f.endsWith(".md"));
          dashDiag.scanned[agent] = { total: files.length, md: mdFiles.length, parsed: 0, errors: 0 };

          for (const file of mdFiles) {
            try {
              const content = await fs.readFile(path.join(dirPath, file), "utf8");
              const parsed = parseFrontmatter(content) || parsePlainMarkdown(content, file);
              const fm = parsed.frontmatter;
              const status = fm.status || "unknown";
              statusCounts[status] = (statusCounts[status] || 0) + 1;
              agentCounts[agent] = (agentCounts[agent] || 0) + 1;
              dashDiag.scanned[agent].parsed++;
              allMessages.push({
                inbox: agent,
                filename: file,
                subject: fm.subject,
                status,
                from: fm.from,
                created: fm.created
              });
            } catch (err) {
              dashDiag.scanned[agent].errors++;
              dashDiag.errors.push({ agent, file, error: err.message });
            }
          }
        }

        // Scan archive
        const archivePath = path.join(BRIDGE_ROOT, "archive");
        const archiveFiles = await fs.readdir(archivePath).catch(() => []);
        const archiveMd = archiveFiles.filter(f => f.endsWith(".md"));
        let archiveCount = archiveMd.length;

        // Sort by created date descending, take last 5
        allMessages.sort((a, b) => (b.created || "").localeCompare(a.created || ""));
        const recent = allMessages.slice(0, 5);

        // Build markdown dashboard
        let dashboard = "# MyndAIX Bridge Dashboard\n\n";

        dashboard += "## Messages by Status\n\n";
        dashboard += "| Status | Count |\n|--------|-------|\n";
        for (const [status, count] of Object.entries(statusCounts).sort()) {
          dashboard += `| ${status} | ${count} |\n`;
        }
        dashboard += `| _archived_ | ${archiveCount} |\n`;

        dashboard += "\n## Messages by Agent Inbox\n\n";
        dashboard += "| Agent | Inbox Count |\n|-------|-------------|\n";
        for (const agent of AGENTS) {
          dashboard += `| ${agent} | ${agentCounts[agent] || 0} |\n`;
        }

        dashboard += "\n## Recent Activity (Last 5)\n\n";
        dashboard += "| Inbox | From | Subject | Status | Created |\n|-------|------|---------|--------|---------|\n";
        for (const msg of recent) {
          dashboard += `| ${msg.inbox} | ${msg.from} | ${msg.subject} | ${msg.status} | ${msg.created || "?"} |\n`;
        }

        // Append diagnostics
        dashboard += "\n## Diagnostics\n\n";
        dashboard += "| Inbox | Total Files | .md Files | Parsed | Errors |\n|-------|-------------|-----------|--------|--------|\n";
        for (const agent of AGENTS) {
          const d = dashDiag.scanned[agent] || {};
          if (d.error) {
            dashboard += `| ${agent} | ERROR: ${d.error} | - | - | - |\n`;
          } else {
            dashboard += `| ${agent} | ${d.total || 0} | ${d.md || 0} | ${d.parsed || 0} | ${d.errors || 0} |\n`;
          }
        }
        if (dashDiag.errors.length > 0) {
          dashboard += "\n**Parse errors:**\n";
          for (const e of dashDiag.errors) {
            dashboard += `- ${e.agent}/${e.file}: ${e.error}\n`;
          }
        }

        return { content: [{ type: "text", text: dashboard }] };
      }

      case "bridge_repair": {
        const targetAgents = args.inbox === "all" || !args.inbox ? AGENTS : [resolveAgent(args.inbox)];
        const dryRun = args.dry_run || false;
        let repaired = 0;
        const details = [];

        for (const agent of targetAgents) {
          const dir = path.join(BRIDGE_ROOT, "inbox", agent);
          const files = await fs.readdir(dir).catch(() => []);
          const mdFiles = files.filter(f => f.endsWith(".md"));

          for (const file of mdFiles) {
            try {
              const filePath = path.join(dir, file);
              const content = await fs.readFile(filePath, "utf8");
              const parsed = parseFrontmatter(content);
              if (parsed) continue; // already valid

              // Extract what we can from the plain markdown
              const stat = await fs.stat(filePath);
              const lines = content.split("\n").filter(l => l.trim());
              const heading = lines.find(l => l.startsWith("# "));
              const subject = heading ? heading.replace(/^#\s*/, "").slice(0, 80) : file.replace(/\.md$/, "");

              // Look for "From:" or "**From:**" lines in the body
              const fromLine = lines.find(l => /^\*{0,2}from\*{0,2}:/i.test(l));
              const from = fromLine ? fromLine.replace(/^\*{0,2}from\*{0,2}:\*{0,2}\s*/i, "").replace(/\*+/g, "").replace(/[^\w\s-]/g, "").trim().toLowerCase() : "unknown";

              const newContent = serializeFrontmatter({
                id: file.replace(/\.md$/, ""),
                from: resolveAgent(from) || from,
                to: agent,
                type: "task",
                subject,
                priority: "normal",
                status: "pending",
                created: stat.mtime.toISOString(),
                _repaired: "true",
              }, "\n" + content);

              if (dryRun) {
                details.push(`[dry-run] ${agent}/${file} — would rewrite with frontmatter (subject: "${subject}")`);
              } else {
                await atomicWrite(filePath, newContent);
                details.push(`${agent}/${file} — repaired (subject: "${subject}")`);
              }
              repaired++;
            } catch { /* skip */ }
          }
        }

        const summary = repaired === 0
          ? "All messages have valid frontmatter. Nothing to repair."
          : `${dryRun ? "Would repair" : "Repaired"} ${repaired} file(s):\n${details.map(d => `  - ${d}`).join("\n")}`;

        return { content: [{ type: "text", text: summary }] };
      }

      default:
        throw new Error(`Unknown tool: ${name}`);
    }
  } catch (error) {
    return { content: [{ type: "text", text: `Error: ${error.message}` }], isError: true };
  }
});

// Main
async function main() {
  await ensureDirs();
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("MyndAIX Bridge MCP server running (v3.1.0)");
}

main().catch(console.error);
