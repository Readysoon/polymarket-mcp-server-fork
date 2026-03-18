#!/bin/bash
set -e

OC_HOME="${HOME:-/home/node}"
OC_DIR="${OPENCLAW_STATE_DIR:-$OC_HOME/.openclaw}"
export OC_DIR

# Inject secrets into openclaw config from environment variables
python3 - << 'PYEOF'
import json, os

oc_dir = os.environ.get('OC_DIR', '/home/node/.openclaw')
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

mkdir -p "$OC_DIR/agents/main/sessions" "$OC_DIR/telegram"
sed -i 's|/Users/philipp/polymarket-mcp-server|/polymarket|g' "$OC_DIR/workspace/TOOLS.md" 2>/dev/null || true

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

echo "ANTHROPIC_API_KEY set: $([ -n \"$ANTHROPIC_API_KEY\" ] && echo yes || echo no)"
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
exec node --trace-warnings openclaw.mjs gateway --allow-unconfigured --port 18789 --bind lan --verbose 2>&1
