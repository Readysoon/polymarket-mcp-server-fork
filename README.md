# Polymarket MCP Dashboard

Automatisches Prediction Market Trading System mit AI-Agent (Delta Δ) und Web-Dashboard.

---

## 🔑 Wallets & Adressen

### MetaMask Wallet (Trading Wallet)
- **Adresse:** `0xe0Eab2BE1bfCbB0cDAF87B436DDE6FCa6752E958`
- **Netzwerk:** Polygon Mainnet
- **Verwendung:** Der MCP Server signiert alle Trades mit diesem Wallet
- **USDC Typen:** Hält Native USDC (`0x3c499c...`) + Bridged USDC.e (`0x2791Bc...`)
- ⚠️ **Geld muss auf diese Adresse**, nicht auf das Polymarket Proxy Wallet!

### Polymarket Proxy Wallet
- **Adresse:** `0xA94Fe7429BDBDed0DBbDecB49d12806a062fCC8C`
- **Was es ist:** Automatisch von Polymarket erstelltes Wallet beim Login mit MetaMask
- **Kein Private Key** — wird intern von Polymarket verwaltet
- ⚠️ Der MCP kann **nicht** mit diesem Wallet handeln — Geld muss auf das MetaMask Wallet!

### USDC auf Polygon
| Token | Adresse | Beschreibung |
|-------|---------|-------------|
| Native USDC | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` | Neuere Version, von Circle ausgegeben |
| Bridged USDC.e | `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174` | Ältere Bridged Version |

**Polymarket akzeptiert beide.** Der MCP liest beide Balances und summiert sie.

---

## 💰 Geld einzahlen

### Option A: Binance → direkt auf MetaMask Wallet (empfohlen)
1. Binance öffnen → **Wallet → Auszahlen**
2. Token: **USDC**
3. Netzwerk: **Polygon** (nicht Ethereum!)
4. Adresse: `0xe0Eab2BE1bfCbB0cDAF87B436DDE6FCa6752E958`
5. Betrag eingeben → Senden
6. ~1-2 Minuten warten

### Option B: Polymarket Withdraw → MetaMask Wallet
1. [polymarket.com](https://polymarket.com) aufmachen → Profil → Withdraw
2. Betrag eingeben
3. Zieladresse: `0xe0Eab2BE1bfCbB0cDAF87B436DDE6FCa6752E958`
4. Bestätigen

> ⚠️ **Immer Polygon-Netzwerk!** Ethereum Mainnet = hohe Fees + manuelles Bridging.

> ⚠️ **Nicht über Polymarket Deposit einzahlen** — das landet auf dem Proxy Wallet, nicht auf dem Trading Wallet!

---

## 🔐 API Keys & Credentials

### Polymarket L2 API Key
- Wird vom Private Key des MetaMask Wallets **deterministisch abgeleitet**
- Erstellt/abgerufen via: `client.create_or_derive_api_creds()`
- Konfiguriert als Fly.io Secrets: `POLYMARKET_API_KEY`, `POLYMARKET_API_SECRET`, `POLYMARKET_PASSPHRASE`
- Falls ein neuer Relayer Key auf polymarket.com erstellt wird → L2 Key wird **invalidiert** → neu ableiten nötig

### Fly.io Secrets (Environment Variables)
```
POLYGON_PRIVATE_KEY     = MetaMask Private Key (64 hex chars, ohne 0x)
POLYGON_ADDRESS         = 0xe0Eab2BE1bfCbB0cDAF87B436DDE6FCa6752E958
POLYMARKET_API_KEY      = L2 API Key (UUID)
POLYMARKET_API_SECRET   = L2 API Secret (base64)
POLYMARKET_PASSPHRASE   = L2 Passphrase (hex string)
POLYMARKET_CHAIN_ID     = 137
```

Secrets updaten:
```bash
flyctl secrets set KEY=VALUE --app polymarket-mcp-dashboard
```

---

## 🤖 System-Übersicht

### Delta Δ (AI Agent)
- Läuft auf OpenClaw (Fly.io)
- Erreichbar via **Telegram** (@Bikiniboy)
- Verwaltet Scanner-Crons, Watcher-Jobs, antwortet auf Fragen
- Memory in `/home/node/.openclaw/workspace/MEMORY.md`

### Scanner
- Läuft täglich um **00:00 Innsbrucker Zeit** (23:00 UTC Winter, 22:00 UTC Sommer)
- Scannt die nächsten **28 Stunden** nach handelbaren Märkten
- Filtert: Volumen >$50k, Spread <10%, YES-Preis 40-85¢
- Registriert Watcher-Jobs automatisch in OpenClaw Cron
- Sendet Zusammenfassung per Telegram (Innsbruck-Zeit)
- Bei Fehlern: **Auto-Fix** → git push → Telegram-Meldung

### Watcher
- Startet **4 Stunden vor Marktschluss**
- Retries alle **15 Minuten**
- Auto-Redeem gewonnener Positionen vor jedem Trade
- **AI-Analyse** vor jedem Trade — BUY/SELL/SKIP
- Confidence < 55% → kein Trade
- Benachrichtigt **nur bei TRADED oder Fehler** (kein Spam für NO_TRADE)
- Bei Fehlern: sofortiger Auto-Fix → git push → Telegram-Meldung

### Position Sizing
| Bankroll | Bet-Größe |
|----------|-----------|
| < $50 | 50% pro Trade |
| ≥ $50 | 20% pro Trade |
| Min | $0.50 |
| Max | $25.00 |

### Web Dashboard
- Läuft auf Fly.io: `polymarket-mcp-dashboard.fly.dev`
- Zeigt: Portfolio-Balance (USDC + USDC.e), offene Positionen mit P&L, Trade-History

---

## 📁 Scripts

| Script | Beschreibung |
|--------|-------------|
| `openclaw/workspace/trading/scanner.sh` | Täglicher Markt-Scanner |
| `openclaw/workspace/trading/market_watcher.sh` | Einzelmarkt-Watcher + Trader |
| `openclaw/workspace/trading/redeem.sh` | Auto-Redeem gewonnener Positionen |
| `openclaw/workspace/trading/config.json` | Trading-Parameter |

---

## ⚙️ Trading Config (`config.json`)

```json
{
  "min_yes_price": 0.40,
  "max_yes_price": 0.85,
  "max_spread": 0.10,
  "min_bet_usd": 0.50,
  "max_bet_usd": 25,
  "bet_pct_small": 0.50,
  "bet_pct_normal": 0.20,
  "balance_threshold": 50
}
```

---

## 🔧 Git Workflow

- Repo: `Readysoon/polymarket-mcp-server-fork`
- Bei jeder Änderung: `git pull` → ändern → `git commit` → `git push`

### Verzeichnisstruktur (deployed auf Fly.io)

```
/home/node/.openclaw/workspace/     ← Workspace (symlink auf /data/...)
/data/openclaw/workspace/           ← Echter Workspace
├── AGENTS.md, SOUL.md, USER.md    ← Agent-Dateien (live)
├── MEMORY.md                       ← Langzeitgedächtnis des Agenten
├── memory/                         ← Tägliche Memory-Logs
├── trading/                        ← Trading Scripts (live ausgeführt)
└── repo/                           ← Git Repo Clone
    ├── src/polymarket_mcp/         ← MCP Server Code
    └── openclaw/workspace/         ← Kopie der Agent-Dateien (versioniert)
```

Nach Änderungen an Trading Scripts:
```bash
cp /home/node/.openclaw/workspace/trading/*.sh /data/openclaw/workspace/repo/openclaw/workspace/trading/
cd /data/openclaw/workspace/repo && git add -A && git commit -m "..." && git push
```

---

## 🚀 Deployment

```bash
# Code-Änderungen deployen
flyctl deploy --app polymarket-mcp-dashboard

# Secrets updaten (kein Re-Deploy nötig, nur Restart)
flyctl secrets set POLYGON_ADDRESS=0x... --app polymarket-mcp-dashboard

# Logs checken
flyctl logs --app polymarket-mcp-dashboard
```
