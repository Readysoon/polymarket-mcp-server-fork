#!/bin/bash
set -e

DATA_DIR="/data"
OC_DIR="$DATA_DIR/openclaw"
export OC_DIR
export OPENCLAW_STATE_DIR="$OC_DIR"

# ── Persistent volume bootstrap ──────────────────────────────────────
# /data is a Fly.io volume that survives restarts and deploys.
# /defaults contains the image-baked files (workspace, config, credentials).
# We only copy files that don't already exist — never overwrite user changes.

echo "Bootstrapping persistent storage at $DATA_DIR ..."

mkdir -p "$OC_DIR/workspace" "$OC_DIR/memory" "$OC_DIR/cron" \
         "$OC_DIR/logs" "$OC_DIR/agents/main/sessions" "$OC_DIR/telegram" \
         "$OC_DIR/credentials" "/home/node/.config/mcporter"

# Copy workspace defaults (only missing files, never overwrite)
if [ -d /defaults/workspace ]; then
    cp -rn /defaults/workspace/ "$OC_DIR/workspace/" 2>/dev/null || \
    rsync -a --ignore-existing /defaults/workspace/ "$OC_DIR/workspace/" 2>/dev/null || true
    echo "  Workspace: synced defaults (existing files preserved)"
fi

# Copy credentials (only if missing)
if [ -d /defaults/credentials ]; then
    cp -rn /defaults/credentials/ "$OC_DIR/credentials/" 2>/dev/null || \
    rsync -a --ignore-existing /defaults/credentials/ "$OC_DIR/credentials/" 2>/dev/null || true
fi

# Config template (always update — it's a template, secrets get injected below)
cp /defaults/openclaw.json.template "$OC_DIR/openclaw.json.template" 2>/dev/null || true

# mcporter config
cp -n /defaults/mcporter.json /home/node/.config/mcporter/mcporter.json 2>/dev/null || true

# Init git repo in workspace if not present
# Git setup for workspace
cd "$OC_DIR/workspace"
if [ ! -d ".git" ]; then
    echo "  Cloning workspace repo..."
    if [ -n "$GIT_REMOTE_TOKEN" ]; then
        git clone "https://$GIT_REMOTE_TOKEN@github.com/Readysoon/polymarket-mcp-server-fork.git" /tmp/repo
        cp -rn /tmp/repo/.git "$OC_DIR/workspace/.git" 2>/dev/null || \
        rsync -a --ignore-existing /tmp/repo/.git/ "$OC_DIR/workspace/.git/" 2>/dev/null || true
        rm -rf /tmp/repo
    else
        git init
        echo "  WARNING: GIT_REMOTE_TOKEN not set — no remote configured"
    fi
fi
git config user.email "openclaw@bot"
git config user.name "OpenClaw"
if [ -n "$GIT_REMOTE_TOKEN" ]; then
    git remote set-url origin "https://$GIT_REMOTE_TOKEN@github.com/Readysoon/polymarket-mcp-server-fork.git" 2>/dev/null || \
    git remote add origin "https://$GIT_REMOTE_TOKEN@github.com/Readysoon/polymarket-mcp-server-fork.git" 2>/dev/null || true
    git fetch origin 2>/dev/null || true
    echo "  Git remote: origin configured (Readysoon/polymarket-mcp-server-fork)"
fi
cd /

# Symlink so OpenClaw finds its state dir at the expected path
ln -sfn "$OC_DIR" /home/node/.openclaw

chown -R node:node "$OC_DIR" /home/node/.config 2>/dev/null || true

echo "  Persistent volume ready. Workspace files: $(ls "$OC_DIR/workspace/" | wc -l)"

# ── Inject secrets into openclaw config ──────────────────────────────
python3 - << 'PYEOF'
import json, os

oc_dir = os.environ.get('OC_DIR', '/data/openclaw')
template_path = f'{oc_dir}/openclaw.json.template'
config_path = f'{oc_dir}/openclaw.json'

with open(template_path) as f:
    config = json.load(f)

if os.getenv('TELEGRAM_BOT_TOKEN'):
    config['channels']['telegram']['botToken'] = os.getenv('TELEGRAM_BOT_TOKEN')

token = os.getenv('GATEWAY_TOKEN') or os.getenv('OPENCLAW_GATEWAY_TOKEN')
if token:
    config['gateway']['auth']['token'] = token

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)

print("OpenClaw config injected successfully")
PYEOF

# Debug: show config summary
echo "Config check:"
python3 -c "
import json
c = json.load(open('$OC_DIR/openclaw.json'))
tg = c.get('channels',{}).get('telegram',{})
print(f'  Telegram enabled: {tg.get(\"enabled\")}')
print(f'  dmPolicy: {tg.get(\"dmPolicy\")}')
print(f'  botToken set: {bool(tg.get(\"botToken\") and tg[\"botToken\"] != \"INJECT_AT_RUNTIME\")}')
print(f'  allowFrom: {tg.get(\"allowFrom\")}')
gw = c.get('gateway',{})
print(f'  Gateway port: {gw.get(\"port\")}')
print(f'  Gateway bind: {gw.get(\"bind\")}')
print(f'  Gateway auth token set: {bool(gw.get(\"auth\",{}).get(\"token\") and gw[\"auth\"][\"token\"] != \"INJECT_AT_RUNTIME\")}')
"

echo "ANTHROPIC_API_KEY set: $([ -n "$ANTHROPIC_API_KEY" ] && echo yes || echo no)"
echo "OPENCLAW_NO_RESPAWN: $OPENCLAW_NO_RESPAWN"
echo "Node version: $(node --version)"

# Start dashboard in background
echo "Starting Polymarket dashboard on port 8080..."
cd /polymarket
python3 -c "from polymarket_mcp.web.app import start; start()" &

# Start OpenClaw gateway in foreground
echo "Starting OpenClaw gateway (exec)..."
cd /app
export OPENCLAW_NO_RESPAWN=1
export OPENCLAW_NODE_OPTIONS_READY=1
export OPENCLAW_LOG_LEVEL=trace
export DEBUG="openclaw:*"
export MCPORTER_CONFIG=/home/node/.config/mcporter/mcporter.json
node --trace-warnings openclaw.mjs gateway --allow-unconfigured --port 18789 --bind lan --verbose 2>&1 | tee /tmp/openclaw-gateway.log
