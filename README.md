# Polymarket MCP Server + Autonomous Trading Bot

[![Python 3.10+](https://img.shields.io/badge/python-3.10+-blue.svg)](https://www.python.org/downloads/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![MCP Protocol](https://img.shields.io/badge/MCP-1.0-purple.svg)](https://modelcontextprotocol.io)

AI-powered trading platform for Polymarket prediction markets. Trade via Claude, monitor via web dashboard, chat via Telegram.

> Fork of [caiovicentino/polymarket-mcp-server](https://github.com/caiovicentino/polymarket-mcp-server) — extended with OpenClaw Telegram bot, treemap dashboard, event sniper, and autonomous trading loop.

---

## Architecture

```
┌──────────────┐     ┌─────────────────────────────────────┐     ┌───────────────────┐
│   Telegram   │────▶│          OpenClaw Gateway            │────▶│  Polymarket MCP   │
│   (you)      │◀────│          (Node.js agent)             │◀────│  Server (45 tools)│
└──────────────┘     │                                       │     └────────┬──────────┘
                     │  ┌─────────┐  ┌───────────────────┐  │              │
                     │  │  Cron   │  │     mcporter       │  │     ┌────────▼──────────┐
                     │  │ Scheduler│  │  (MCP bridge)      │  │     │  Polymarket APIs  │
                     │  └────┬────┘  └───────────────────┘  │     │  CLOB · Gamma ·   │
                     │       │                               │     │  WebSocket · Chain │
                     └───────┼───────────────────────────────┘     └───────────────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
     ┌────────▼────┐ ┌──────▼──────┐ ┌─────▼───────┐
     │   scanner   │ │   market    │ │    Web       │
     │   .sh       │ │  watcher.sh │ │  Dashboard   │
     │  (daily 8am)│ │  (per-event)│ │  (FastAPI)   │
     └─────────────┘ └─────────────┘ └─────────────┘
```

**Deployment:** Single Fly.io machine (Amsterdam, 2GB) running the official OpenClaw Docker image with Python/Polymarket overlay. The entrypoint starts the web dashboard as a background process and the OpenClaw gateway in the foreground.

**Key components:**
- **OpenClaw Gateway** — Node.js agent that connects to Telegram and Claude (Sonnet 4.6). Handles conversations, tool calls, and cron scheduling.
- **mcporter** — Bridges OpenClaw to the Polymarket MCP server via stdio. Exposes all 45 MCP tools to the agent.
- **Cron Scheduler** — Built into OpenClaw. Runs jobs at scheduled times, each in an isolated agent session.
- **Web Dashboard** — FastAPI app on port 8080 with treemap portfolio view and balance chart.

## Autonomous Trading Loop

The bot runs an **event sniper** — a cron-driven trading pipeline with no polling:

### 1. Daily Scanner (`scanner.sh`, cron: 8am Berlin)

Runs every morning via OpenClaw cron. Binary-searches the Gamma API to find all markets closing in the next 7 days, then filters:
- YES price between 55-80¢ (configurable in `config.json`)
- CLOB liquidity > $10K
- Excludes "Up or Down" price markets

Outputs a `watchlist.json` (typically 50-100 candidates) and schedules one-shot cron jobs for each — timed 6 hours before market close.

### 2. Market Watcher (`market_watcher.sh`, one-shot per event)

Each cron fires a watcher for a single market. The watcher:

1. **Checks expiry** — skips if market already closed
2. **Fetches orderbook** via mcporter → `polymarket.get_orderbook`
3. **Evaluates spread** — must be < 5% (initial gate) and < 3% (trade gate)
4. **If not ready** — reschedules itself in 15-30 min (up to market close)
5. **If ready** — checks price range, portfolio balance, duplicate trades
6. **Places limit order** via mcporter → `polymarket.create_limit_order`
7. **Logs everything** to `trading/log.json` with full context (spread, mid price, hours left, result)
8. **Notifies on Telegram** — TRADED or ALERT lines trigger a message to you

### 3. Trade Lifecycle

```
scanner.sh (daily 8am)
  │
  ├─ fetches Gamma API (binary search for date range)
  ├─ filters: price 0.55-0.80, liquidity >$10K
  ├─ writes watchlist.json (50-100 markets)
  └─ schedules one-shot cron per market (6h before close)
       │
       ▼
market_watcher.sh (fires per event)
  │
  ├─ orderbook check via mcporter → get_orderbook
  ├─ spread > 5%? → reschedule in 30min
  ├─ spread < 5% but > 3%? → reschedule in 15min
  ├─ spread < 3% + price in range + balance OK?
  │     ├─ YES → create_limit_order (12% of portfolio, max $25)
  │     │        log TRADED → Telegram notification
  │     └─ NO  → log NO_TRADE reason → silent
  └─ < 30min left + still not ready? → log TIMEOUT → abandon
```

### Trading Config (`config.json`)

```json
{
  "bet_pct_of_balance": 0.12,
  "min_bet_usd": 0.50,
  "max_bet_usd": 25,
  "min_yes_price": 0.55,
  "max_yes_price": 0.80,
  "min_liquidity_usd": 10000,
  "max_spread": 0.03
}
```

The bot only wakes up when there's an opportunity — no wasted API calls, no constant polling.

## Web Dashboard

Polydupe-style treemap showing all positions at a glance:

- **Treemap view** with tiles sized by P&L or value (bigger bet = bigger tile)
- **Green/red gradient** intensity shows profit/loss magnitude
- **Active/Closed** tabs with resolved positions shown as dashed borders
- **Wallet balances**: USDC, USDC.e, POL across MetaMask and Polymarket
- **Balance history chart** with live tracking
- **Monitoring tab**: MCP status, rate limits, system health

<details>
<summary>📸 Dashboard Screenshots (click to expand)</summary>

### Portfolio Overview
![Dashboard Header](docs/screenshots/dashboard-header.png)
*Profile stats, wallet balances (USDC, USDC.e, POL), P&L display, and live account balance chart.*

### Treemap Positions
![Dashboard Treemap](docs/screenshots/dashboard-treemap.png)
*Squarified treemap — tile size reflects bet size, green = profit, red = loss. Active/Closed filter, Size by P&L or Value.*

### Treemap Detail
![Dashboard Detail](docs/screenshots/dashboard-detail.png)
*50 positions showing gradient intensity scaling — deeper color = larger P&L. Each tile links to Polymarket, TX links to Polygonscan.*

</details>

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
