// PM2 ecosystem for MyndAIX Bridge.
//
// Covers ONLY processes that live in this repo. External services
// (the Lobster Discord notifier at ~/.myndaix/lobster-bot/, OpenClaw,
// etc.) are documented separately in SETUP.md as optional Tier-2
// dependencies.
//
// Usage:
//   pm2 start ecosystem.config.js
//   pm2 save
//   pm2 logs myndaix-daemon
//
// The daemon is the long-running MCP bridge server that mediates
// inbox/outbox events for all per-agent watchers.

module.exports = {
  apps: [
    {
      name: 'myndaix-daemon',
      script: 'myndaix-daemon.js',
      cwd: process.env.BRIDGE_DIR || `${process.env.HOME}/.myndaix/bridge`,
      autorestart: true,
      max_restarts: 10,
      min_uptime: '30s',
      // Restart with exponential backoff if the daemon thrashes.
      exp_backoff_restart_delay: 1000,
      env: {
        NODE_ENV: 'production',
      },
      // PM2 owns this daemon. The competing ai.myndaix.daemon LaunchAgent
      // (if present) must be disabled to avoid a restart race; SETUP.md
      // covers this.
    },
  ],
};
