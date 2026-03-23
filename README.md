# Polymarket Trading System

Automatisches Prediction Market Trading System mit AI-Agent (Delta Δ) und Web-Dashboard.

---

## 🔑 Wallets & Adressen

### MetaMask Wallet (Trading Wallet)
- **Adresse:** `0xe0Eab2BE1bfCbB0cDAF87B436DDE6FCa6752E958`
- **Netzwerk:** Polygon Mainnet
- **Verwendung:** Der MCP Server signiert alle Trades mit diesem Wallet

### Polymarket Proxy Wallet (irrelevant für automatisches Trading)
- **Adresse:** `0xA94Fe7429BDBDed0DBbDecB49d12806a062fCC8C`
- Nur für manuelles Trading auf polymarket.com — der Bot ignoriert es

---

## 💰 Geld einzahlen

**Binance → MetaMask Wallet (empfohlen):**
1. Binance → Wallet → Auszahlen → USDC → **Netzwerk: Polygon**
2. Adresse: `0xe0Eab2BE1bfCbB0cDAF87B436DDE6FCa6752E958`

> ⚠️ Immer Polygon-Netzwerk! Nie über Polymarket Deposit (landet auf Proxy Wallet).

---

## 🔐 Fly.io Secrets

```
POLYGON_PRIVATE_KEY     = MetaMask Private Key (64 hex chars, ohne 0x)
POLYGON_ADDRESS         = 0xe0Eab2BE1bfCbB0cDAF87B436DDE6FCa6752E958
POLYMARKET_API_KEY      = L2 API Key (UUID)
POLYMARKET_API_SECRET   = L2 API Secret (base64)
POLYMARKET_PASSPHRASE   = L2 Passphrase (hex string)
POLYMARKET_CHAIN_ID     = 137
```

---

## 🤖 System-Übersicht

### Delta Δ (AI Agent)
- Läuft auf OpenClaw (Fly.io), erreichbar via Telegram (@Bikiniboy)
- Memory in `/home/node/.openclaw/workspace/MEMORY.md`

### Scanner (täglich 00:00 Innsbruck)
1. Scannt Märkte (Volumen >$50k, Spread <5%, Preis 50-80¢)
2. Macht Web-Research für jeden Kandidaten (covers.com, hltv.org etc.)
3. Berechnet Kapitalallokation: **20% Reserve** (unantastbar), 80% nach Confidence verteilt
4. Schreibt research.json mit `allocated_usd` pro Markt
5. Registriert Watcher-Jobs (mit spezifischen Daten, nicht ganzer research.json)
6. Sendet Tagesbericht per Telegram

### Watcher-Agent (startet 4h vor Marktschluss)
- Bekommt: Markt, Preis, Research-Summary, Confidence, Budget, Red Flags
- Prüft aktuellen Preis via mcporter
- Entscheidet selbst Timing + Einsatz (max: allocated_usd, min: $2.50)
- Registriert Outcome-Checker 30 Min nach Event-Ende

### Take-Profit Monitor (alle 5 Minuten)
- Prüft alle offenen Positionen
- **Preis ≥ 0.95 → sofort verkaufen** (kein Warten auf Oracle/Redeem!)
- Preis ≤ 0.05 → als verloren markieren
- Keine offenen Trades → schläft still
- Benachrichtigt Philipp bei jedem Sell oder Loss

### Outcome-Checker (30 Min nach Event-Ende)
- Nur Preis-Check (kein redeem)
- Falls noch nicht resolved → retry in 30 Min

### Kapitalallokation
| Confidence | Gewichtung |
|---|---|
| 80-100% | 30% |
| 70-79% | 20% |
| 65-69% | 10% |
| < 65% | SKIP |

Min: $2.50 | Max: $10 pro Trade | 20% Cash-Reserve immer geschützt

---

## 📁 Scripts

| Script | Beschreibung |
|---|---|
| `trading/scanner.sh` | Täglicher Scanner + Research + Kapitalallokation |
| `trading/market_watcher.sh` | Trade-Ausführung |
| `trading/sell_winner.sh` | Take-Profit Sell (Preis ≥ 0.95) |
| `trading/redeem.sh` | Legacy Redeem (für alte Positionen) |
| `trading/config.json` | Trading-Parameter |

---

## 🔧 Git Workflow

- Repo: `Readysoon/polymarket-mcp-server-fork`
- Branch `main`: stabiler Code
- Branch `high-speed-trading`: Take-Profit + neue Features (aktuell aktiv)

```bash
# Zurück zu main:
git checkout main

# Änderungen pushen:
git add -A && git commit -m "..." && git push
```

---

## 🚀 Deployment

```bash
flyctl deploy --app polymarket-mcp-dashboard
flyctl secrets set KEY=VALUE --app polymarket-mcp-dashboard
flyctl logs --app polymarket-mcp-dashboard
```
