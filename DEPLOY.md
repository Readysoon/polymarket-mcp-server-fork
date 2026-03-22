# Deploy: Fresh Setup

From zero to running on Fly.io.

## Prerequisites

- [flyctl](https://fly.io/docs/getting-started/installing-flyctl/) installed
- GitHub PAT with repo access (for the bot to clone/push)
- Telegram bot token (from @BotFather)
- Anthropic API key
- Polymarket API credentials

## 1. Clone & Setup

```bash
git clone https://github.com/Readysoon/polymarket-mcp-server-fork.git
cd polymarket-mcp-server-fork
fly launch --no-deploy    # creates the app, don't deploy yet
```

## 2. Create Persistent Volume

```bash
fly volumes create openclaw_data --region ams --size 1 --yes
```

This volume stores the bot's workspace (identity, memory, trading scripts) and a full clone of the repo that the bot can read and modify.

## 3. Set Secrets

```bash
fly secrets set \
  ANTHROPIC_API_KEY=sk-ant-... \
  TELEGRAM_BOT_TOKEN=1234:ABC... \
  GATEWAY_TOKEN=<random-string> \
  GIT_REMOTE_TOKEN=ghp_... \
  POLYMARKET_API_KEY=... \
  POLYMARKET_API_SECRET=... \
  POLYMARKET_PASSPHRASE=... \
  POLYMARKET_CHAIN_ID=137 \
  POLYGON_ADDRESS=0x... \
  POLYGON_PRIVATE_KEY=...
```

## 4. Deploy

```bash
fly deploy
```

## What happens on first deploy

The entrypoint (`openclaw/entrypoint.sh`) bootstraps the persistent volume:

1. Copies workspace defaults (IDENTITY.md, SOUL.md, trading scripts) to `/data/openclaw/workspace/`
2. Clones the full repo into `/data/openclaw/workspace/repo/` — the bot reads and edits code here
3. Injects secrets into OpenClaw config (Telegram token, gateway auth)
4. Starts the Polymarket dashboard (port 8080) and OpenClaw gateway (Telegram bot)

## Architecture on Fly

```
Docker Image (rebuilt every deploy):
  /polymarket/     ← Python MCP server (baked in)
  /app/            ← OpenClaw binary (baked in)

Persistent Volume /data/ (survives deploys):
  /data/openclaw/
  ├── workspace/
  │   ├── IDENTITY.md, SOUL.md, ...   ← Bot state
  │   ├── trading/                     ← Trading scripts
  │   └── repo/                        ← Full git clone (bot can read/edit/push)
  ├── openclaw.json                    ← Runtime config (secrets injected)
  ├── memory/                          ← Bot memory
  └── logs/
```

**Local (your machine):** You develop, push to GitHub, run `fly deploy`.
**Online (Fly container):** The bot (Delta) has its own clone under `workspace/repo/`, can read code, make changes, commit, and push.

Both push to the same GitHub repo. On each deploy, the entrypoint runs `git pull` to sync the bot's clone with your latest changes.

## Redeploying

```bash
fly deploy
```

The volume persists — bot state, memory, and the repo clone survive. Only the Docker image (MCP server + OpenClaw binary) gets rebuilt. New workspace defaults are copied only if they don't already exist (`cp -rn`).

## Useful commands

```bash
fly status                    # App status
fly logs                      # Live logs
fly ssh console               # SSH into container
fly ssh console -C "bash -c 'cat /data/openclaw/workspace/IDENTITY.md'"
```
