# Polymarket MCP Server + Autonomous Trading Bot

[![Python 3.10+](https://img.shields.io/badge/python-3.10+-blue.svg)](https://www.python.org/downloads/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![MCP Protocol](https://img.shields.io/badge/MCP-1.0-purple.svg)](https://modelcontextprotocol.io)

AI-powered trading platform for Polymarket prediction markets. Trade via Claude, monitor via web dashboard, chat via Telegram.

> Fork of [caiovicentino/polymarket-mcp-server](https://github.com/caiovicentino/polymarket-mcp-server) — extended with OpenClaw Telegram bot, treemap dashboard, event sniper, and autonomous trading loop.

---

## Architecture

```
┌──────────────┐     ┌──────────────────┐     ┌───────────────────┐
│   Telegram   │────▶│    OpenClaw       │────▶│  Polymarket MCP   │
│   (you)      │◀────│    Gateway        │◀────│  Server (Python)  │
└──────────────┘     │  (Node.js agent)  │     └────────┬──────────┘
                     │                    │              │
                     │  ┌──────────────┐ │     ┌────────▼──────────┐
                     │  │ Event Sniper │ │     │  Polymarket APIs   │
                     │  │ (cron-based) │ │     │  CLOB · Gamma ·   │
                     │  └──────────────┘ │     │  WebSocket · Chain │
                     └──────────────────┘     └───────────────────┘
                              │
                     ┌────────▼────────┐
                     │  Web Dashboard  │
                     │  (FastAPI)      │
                     │  localhost:8080  │
                     └─────────────────┘
```

## Autonomous Trading Loop

The bot runs an **event sniper** — a smart, trigger-based trading system:

1. **Weekly Scanner** (every Monday): fetches all markets closing in the next 7 days, filters for CLOB liquidity >$10K and favorable odds (55-80¢)
2. **Targeted Crons**: instead of polling every 30 min, the scanner schedules one-shot wake-ups 2 hours before each event (e.g. NBA tipoff, election deadline)
3. **Pre-trade Check**: when a cron fires, the bot verifies the CLOB orderbook has real liquidity and tight spreads (<5%)
4. **Execution**: if conditions are met, places a limit order and pings you on Telegram
5. **Post-trade Monitor**: watches for resolution, reports P&L

```
Weekly Scanner → finds 50+ candidates
       ↓
Schedule targeted crons (2h before event)
       ↓
Cron fires → check CLOB spread & liquidity
       ↓
Conditions met? → place bet → notify on Telegram
       ↓
Market resolves → report P&L
```

The bot only wakes up when there's an opportunity — no wasted API calls.

## Web Dashboard

Polydupe-style treemap showing all positions at a glance:

- **Treemap view** with tiles sized by P&L or value (bigger bet = bigger tile)
- **Green/red gradient** intensity shows profit/loss magnitude
- **Active/Closed** tabs with resolved positions shown as dashed borders
- **Wallet balances**: USDC, USDC.e, POL across MetaMask and Polymarket
- **Monitoring tab**: MCP status, rate limits, system health

## Quick Start

```bash
# Clone
git clone https://github.com/Readysoon/polymarket-mcp-server-fork.git
cd polymarket-mcp-server-fork

# Install
python -m venv venv && source venv/bin/activate
pip install -e .

# Configure
cp .env.example .env
# Edit .env with your Polygon wallet + Polymarket API credentials

# Run
make start    # starts dashboard + telegram bot
```

## Makefile Commands

```
make start          # Start dashboard + bot together
make stop           # Stop everything
make status         # Check all services

make dashboard      # Start web dashboard (localhost:8080)
make bot            # Start Telegram bot (foreground)
make bot-status     # Check bot + channel health
make bot-logs       # View bot logs

make portfolio      # Check your positions
make markets        # Trending markets
make search q="..."   # Search markets
make orders         # Open orders
make history        # Trade history

make push           # Commit and push to GitHub
make security       # Run security audit
```

## Configuration

### Environment Variables (`.env`)

```env
# Wallet
POLYGON_PRIVATE_KEY=your_private_key
POLYGON_ADDRESS=0xYourAddress

# Polymarket CLOB API (get from polymarket.com/settings)
POLYMARKET_API_KEY=your_api_key
POLYMARKET_API_SECRET=your_api_secret
POLYMARKET_PASSPHRASE=your_passphrase

# Safety limits
MAX_ORDER_SIZE_USD=1000
MAX_TOTAL_EXPOSURE_USD=5000
REQUIRE_CONFIRMATION_ABOVE_USD=500
```

### OpenClaw Telegram Bot

```bash
# Install OpenClaw (requires Node 22+)
npm install -g openclaw@latest
openclaw onboard   # wizard: set Claude API key, scan Telegram QR

# Or use Makefile
make bot-configure
```

### Claude Desktop Integration

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "polymarket": {
      "command": "/path/to/venv/bin/python",
      "args": ["-m", "polymarket_mcp.server"],
      "cwd": "/path/to/polymarket-mcp-server"
    }
  }
}
```

## MCP Tools (45 total)

| Category | Tools | Examples |
|----------|-------|---------|
| Market Discovery | 8 | search, trending, closing soon, by category |
| Market Analysis | 10 | prices, spreads, orderbook, AI recommendations |
| Trading | 12 | limit/market orders, batch, smart trade, cancel |
| Portfolio | 8 | positions, P&L, risk analysis, optimization |
| Real-time | 7 | WebSocket prices, order status, alerts |

## Server Deployment (Docker)

Docker configs for Hetzner/VPS deployment are in `~/.openclaw/workspace/docker/`:

```bash
# On the server
docker compose up -d    # runs OpenClaw + MCP server + dashboard
```

## Security

- Private key and API credentials stored in `.env` (gitignored, never committed)
- Telegram bot restricted to specific user IDs via `allowFrom`
- OpenClaw gateway on localhost only
- All trades require CLOB orderbook verification before execution
- Configurable safety limits (max order size, exposure caps, spread tolerance)

## Credits

- Original MCP server by [Caio Vicentino](https://github.com/caiovicentino)
- Fork maintained by [Readysoon](https://github.com/Readysoon)
- Built with [Claude Code](https://claude.ai/code) and [OpenClaw](https://openclaw.ai)

## Disclaimer

This software is for educational purposes. Trading prediction markets involves financial risk. Only invest what you can afford to lose. This is not financial advice.

## License

MIT — see [LICENSE](LICENSE)
