# HEARTBEAT.md

## Checks

1. Read `/home/node/.openclaw/workspace/trading/log.json` — show last 5 entries if anything happened in the last 2 hours
2. Read `/home/node/.openclaw/workspace/trading/error_queue.json` — alert if not empty
3. If anything notable: message Philipp. Otherwise: HEARTBEAT_OK.
