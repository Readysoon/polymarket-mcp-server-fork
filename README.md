# Polymarket MCP Dashboard

Automated prediction market trading system with dashboard.

---

## 💰 Geld einzahlen: Binance → Polymarket

### Schritt 1: Binance → MetaMask (Polygon)
1. Binance öffnen → **Wallet → Auszahlen**
2. Token: **USDC**
3. Netzwerk: **Polygon** (nicht Ethereum!)
4. Adresse: `0xe0Eab2BE1bfCbB0cDAF87B436DDE6FCa6752E958`
5. Betrag eingeben → Senden
6. Warten (~1-2 Minuten bis Polygon bestätigt)

### Schritt 2: MetaMask → Polymarket
1. [polymarket.com](https://polymarket.com) aufmachen
2. MetaMask verbinden (oben rechts)
3. **Deposit** klicken
4. USDC auswählen, Betrag eingeben
5. MetaMask-Transaktion bestätigen
6. Fertig — USDC erscheint in deinem Polymarket-Konto

> ⚠️ **Immer Polygon-Netzwerk wählen!** Ethereum Mainnet = hohe Fees + manuelles Bridging nötig.

---

## 🤖 System-Übersicht

### Scanner
- Läuft täglich um **00:00 Innsbrucker Zeit** (23:00 UTC winter, 22:00 UTC sommer)
- Scannt die nächsten **28 Stunden** nach handelbaren Märkten
- Filtert nach: Volumen >$50k, Spread <10%, YES-Preis 40-85¢
- Sendet Zusammenfassung per Telegram mit **Innsbruck-Lokalzeit**
- Bei technischen Fehlern: **Auto-Fix** → git push → Telegram-Meldung

### Watcher
- Erster Check **4 Stunden vor Marktschluss**
- Retries alle **15 Minuten**
- Löst automatisch gewonnene Positionen ein (Redeem) bevor getradet wird
- **AI-Analyse** via `analyze_market_opportunity` vor jedem Trade — BUY/SELL/SKIP je nach Empfehlung
- Confidence < 55% → kein Trade
- Benachrichtigt nach **jedem Check** mit Ergebnis (TRADED, NO_TRADE + Grund, oder Fehler)
- Bei technischen Fehlern: **Auto-Fix** → git push → Telegram-Meldung

### Position Sizing
- Bankroll < $50: **50% pro Trade**
- Bankroll ≥ $50: **20% pro Trade**
- Min Bet: $0.50 | Max Bet: $25.00

### Dashboard
- Läuft auf dem Fly.io-Server
- Zeigt Portfolio, Trades, Activity Timeline, Pending Markets mit Countdown

---

## 📁 Scripts

| Script | Beschreibung |
|--------|-------------|
| `openclaw/workspace/trading/scanner.sh` | Täglicher Markt-Scanner |
| `openclaw/workspace/trading/market_watcher.sh` | Einzelmarkt-Watcher + Trader |
| `openclaw/workspace/trading/redeem.sh` | Auto-Redeem gewonnener Positionen |
| `openclaw/workspace/trading/config.json` | Trading-Parameter |

---

## ⚙️ Config (`config.json`)

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
/home/node/.openclaw/workspace/     ← Alias für den Workspace (OpenClaw)
/data/openclaw/workspace/           ← Echter Workspace
├── AGENTS.md, SOUL.md, USER.md    ← Agent-Dateien (live, werden genutzt)
├── MEMORY.md                       ← Langzeitgedächtnis des Agenten
├── memory/                         ← Tägliche Memory-Logs
├── trading/                        ← Trading Scripts (live)
└── repo/                           ← Git Repo Clone
    ├── src/polymarket_mcp/         ← MCP Server Code
    ├── openclaw/workspace/         ← Kopie der Agent-Dateien (im Repo versioniert)
    └── trading/ (via openclaw/)    ← Kopie der Trading Scripts (im Repo versioniert)
```

**Wichtig:** Die live genutzten Dateien liegen im Workspace (`/data/openclaw/workspace/`).
Das Repo unter `repo/` ist der Git-Clone. Nach Änderungen im Workspace müssen die
relevanten Dateien ins Repo kopiert und gepusht werden:

```bash
cp /home/node/.openclaw/workspace/trading/*.sh /data/openclaw/workspace/repo/openclaw/workspace/trading/
cd /data/openclaw/workspace/repo && git add -A && git commit -m "..." && git push
```
