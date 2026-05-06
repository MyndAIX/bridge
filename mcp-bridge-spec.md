# MyndAIX Bridge MCP Server Specification

## Purpose
Enable autonomous inter-agent communication through file-based message passing.

## Directory Structure
```
~/.myndaix/bridge/
├── inbox/
│   ├── claude/          # Messages TO Claude
│   ├── codex/           # Messages TO Codex/ChatGPT
│   └── gemini/          # Messages TO Gemini
├── outbox/
│   ├── claude/          # Messages FROM Claude
│   ├── codex/           # Messages FROM Codex
│   └── gemini/          # Messages FROM Gemini
└── mcp-bridge-server.js # The MCP server
```

## MCP Tools

### 1. `bridge_send`
Send a message to another agent.

```typescript
{
  name: "bridge_send",
  description: "Send a message to another agent via the bridge",
  inputSchema: {
    type: "object",
    properties: {
      to: {
        type: "string",
        enum: ["codex", "gemini", "claude"],
        description: "Target agent"
      },
      subject: {
        type: "string",
        description: "Message subject/title"
      },
      body: {
        type: "string",
        description: "Message content (markdown)"
      },
      priority: {
        type: "string",
        enum: ["normal", "urgent"],
        default: "normal"
      }
    },
    required: ["to", "subject", "body"]
  }
}
```

### 2. `bridge_check`
Check for new messages in inbox.

```typescript
{
  name: "bridge_check",
  description: "Check for new messages from other agents",
  inputSchema: {
    type: "object",
    properties: {
      from: {
        type: "string",
        enum: ["codex", "gemini", "all"],
        description: "Filter by sender"
      }
    }
  }
}
```

### 3. `bridge_read`
Read a specific message.

```typescript
{
  name: "bridge_read",
  description: "Read a message from inbox",
  inputSchema: {
    type: "object",
    properties: {
      message_id: {
        type: "string",
        description: "Message filename or ID"
      }
    },
    required: ["message_id"]
  }
}
```

## Message Format
```markdown
---
id: 20260203_192345_debug_request
from: claude
to: codex
subject: Photo Gallery Memory Crash Debug
priority: urgent
timestamp: 2026-02-03T19:23:45Z
project: ~/Desktop/FieldVision
status: pending
---

# Message Body

[markdown content here]

## Files Referenced
- /path/to/file1.swift
- /path/to/file2.swift

## Expected Response
[what kind of response is needed]
```

## Slash Command: /bridge

```
/bridge send codex "Debug this photo gallery crash"
/bridge check
/bridge read <message_id>
```

## Implementation
Node.js MCP server using @modelcontextprotocol/sdk

```javascript
// mcp-bridge-server.js
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import fs from "fs/promises";
import path from "path";

const BRIDGE_ROOT = path.join(process.env.HOME, ".myndaix/bridge");

// ... implementation
```

## Claude Code Settings Addition
```json
{
  "mcpServers": {
    "myndaix-bridge": {
      "command": "node",
      "args": ["~/.myndaix/bridge/mcp-bridge-server.js"]
    }
  }
}
```
