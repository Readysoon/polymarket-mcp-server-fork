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

### Polymarket Proxy Wallet (irrelevant für das automatische Trading)
- **Adresse:** `0xA94Fe7429BDBDed0DBbDecB49d12806a062fCC8C`
- **Was es ist:** Automatisch von Polymarket erstelltes Wallet beim Login mit MetaMask auf polymarket.com
- **Kein Private Key** exportierbar — wird intern von Polymarket verwaltet
- Nur relevant für **manuelles Trading** auf der Polymarket Website
- Der MCP-Server kann damit **nicht** handeln → für die Automatisierung vollständig ignorieren

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

> ⚠️ **NICHT über Polymarket Deposit einzahlen** — das landet auf dem Proxy Wallet (`0xA94Fe7...`), nicht auf dem Trading Wallet! Der MCP kann auf Proxy-Wallet-Geld **nicht** zugreifen.

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

## 🕐 Aktive Cron-Jobs

| Job | Intervall | Aufgabe |
|-----|-----------|---------|
| **Live Monitor** | alle 2 Min | ESPN Live-Buy + Stop-Loss + Redeem |
| **Trading** | alle 2h | Brave Picks + Pre-Game Trades |
| **Watchlist Scanner** | alle 6h | Polymarket-Märkte direkt laden (kein Brave) |
| **Wochenbericht** | Mo 10:00 | Summary per Telegram |

---

## 🎯 ESPN Live-Buy System (Hauptstrategie)

**Prinzip:** ESPN Live-Win-% zeigt 94% → Polymarket-Preis noch bei 50¢ → Latenz-Arbitrage kaufen.

### Funnel (alle 2 Minuten)

```
ESPN Scoreboard (NBA/NHL/NCAAB/MLB)
→ 8 Teams in laufenden Spielen
→ Gezielte Polymarket-Suche pro Team
→ ~8 Märkte (Moneyline only, kein Spread/O/U)
→ 2-3 Kandidaten (ESPN ≥ 90%)
→ 1-2 (nach Spielende-Check + Edge-Check ≥10%)
→ Claude AI entscheidet YES/NO Token
→ Quarter Kelly Sizing
→ Trade via CLOB Live-Preis
```

### 3 Kaufstufen pro Spiel (je einmal)

| Stufe | ESPN Schwelle | Sizing |
|-------|--------------|--------|
| T1 | ≥ 90% | Quarter Kelly × Divergenz-Mult |
| T2 | ≥ 95% | Quarter Kelly × Divergenz-Mult |
| T3 | ≥ 98% | Quarter Kelly × Divergenz-Mult |

### Divergenz-Multiplikator (Edge = ESPN% − CLOB-Preis)

| Edge | Multiplikator |
|------|--------------|
| 10–19% | ×1.0 |
| 20–34% | ×1.5 |
| ≥ 35% | ×2.0 |

Kein fixer Cap — Quarter Kelly bestimmt die Größe.

### Stop-Loss
- ESPN Win-% unserer Seite < 22% → sofort verkaufen (FOK-Ladder: bid-1¢ → bid-3¢ → bid-5¢ → bid)
- Journal wird automatisch auf `SOLD` gesetzt

### Benachrichtigungen (stumm außer Wochenbericht)
- Trades: kein Telegram
- Stop-Loss: kein Telegram
- Wochenbericht montags: W/L diese Woche + Gesamt + Positionen + Bankroll

---

## 📊 Pre-Game Trading (Dimers/Moneypuck)

Läuft alle **2 Stunden**.

**Erlaubte Märkte:** Nur `[Team A] vs. [Team B]` Moneyline ✅
**Verboten:** Spread, O/U, Crypto, Politik ❌

**Quellen:**
- NBA: Dimers / FanDuel / numberFire (via Brave AI)
- NHL: Moneypuck (via Brave AI)

**Sizing:** Quarter Kelly, EV-Check: `conf/100 >= preis + 0.08`

**EV-Beispiele:**
| Confidence | Preis | Einsatz ($150 Bankroll) |
|------------|-------|---------|
| 65% | 52¢ | ~$4 |
| 72% | 55¢ | ~$6 |
| 85% | 52¢ | ~$14 |

---

## 💾 Paper Trading

Aktiv seit 30.03.2026. Alle Trades werden simuliert, kein echtes Geld bewegt.

- Bankroll-Tracking: `trading/paper_bankroll.json`
- Outcomes werden via Polymarket-API resolved
- Umschalten: `"paper_trading": false` in `trading/config.json`

**Performance (Stand 04.04.2026):**
- Paper PnL: +$152.47
- Paper Bankroll: $301.65 (Start: $149.18)

---

## 📁 Scripts

| Script | Beschreibung |
|--------|-------------|
| `trading/live_monitor.sh` | ESPN Live-Monitor: Stop-Loss + Live-Buy |
| `trading/market_watcher.sh` | Pre-Game Trade Execution |
| `trading/redeem.sh` | Auto-Redeem + Journal-Update |
| `trading/scanner.sh` | Polymarket Markt-Scanner |
| `trading/journal.json` | Trade-History (echt + paper) |
| `trading/paper_bankroll.json` | Paper Bankroll History |
| `trading/config.json` | Trading-Parameter + Paper-Mode |

---

## ⚙️ Trading Config (`config.json`)

```json
{
  "paper_trading": true,
  "min_yes_price": 0.35,
  "max_yes_price": 0.80,
  "max_spread": 0.05,
  "min_bet_usd": 2.50,
  "stop_loss_threshold": 0.22
}
```

**Bankroll:** Paper-Bankroll aus `paper_bankroll.json` (Paper-Modus) oder Wallet USDC.e via Polygon RPC (echter Modus)

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
