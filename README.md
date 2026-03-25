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

### Polymarket Runner (aktives System)
Läuft alle **2 Stunden** (Europe/Vienna). Führt folgende Schritte aus:

1. 💰 **Redeem** — löst gewonnene Positionen automatisch ein
2. 🔍 **Scanner** — scannt Märkte (Volumen >$50k, Spread <10%, YES 40-85¢)
3. 📰 **Research** — AI analysiert jeden Kandidaten (covers.com, hltv.org, etc.)
4. 💵 **Kapital aufteilen** — nach Confidence gewichtet (80%+ → 30%, 70-79% → 20%, 65-69% → 10%)
5. ⚡ **Sofort kaufen** — wenn EV positiv (confidence ≥ preis + 8%)
6. 📱 **Pflichtbericht** — sendet nach jedem Run eine Zusammenfassung per Telegram

**EV-Formel:** `confidence/100 >= current_price + 0.08`

**Position Sizing:**
| Confidence | Gewicht | Max pro Trade |
|------------|---------|--------------|
| 80-100% | 30 | $10.00 |
| 70-79% | 20 | $10.00 |
| 65-69% | 10 | $10.00 |
| Min | — | $2.50 |

**Bankroll:** Wallet USDC.e Balance via Polygon RPC (nicht Polymarket-internes Cash)

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

## 📊 Strategie & Kelly Kriterium

### Optimales Trade-Verhältnis

Das **Kelly Kriterium** gibt den optimalen Kapitaleinsatz pro Trade:

```
f = (p × b - (1-p)) / b
```

- `p` = Win-Rate (z.B. 0.70 = 70%)
- `b` = Gewinn pro Dollar Einsatz (z.B. bei 65¢ Preis: b = 0.54)
- `f` = optimaler % des Bankrolls pro Trade

**Beispiel bei 65¢ Marktpreis:**
| Win-Rate | Kelly % | Empfehlung |
|----------|---------|------------|
| 75% | ~19% | Guter Edge |
| 70% | ~9% | Moderater Edge |
| 65% | ~0% | Break-even — kein Trade! |

→ Deshalb unser **+8% EV-Buffer**: bei 65¢ brauchst du ≥73% Confidence für positiven EV.

### Qualität vs. Quantität

| Strategie | Trades/Tag | Min. Confidence | Monatl. Wachstum |
|-----------|------------|-----------------|-----------------|
| Sehr selektiv | 1-2 | ≥80% | ~25% |
| **Moderat (aktuell)** | 3-4 | ≥65% | ~20% |
| Aggressiv | 8-10 | ≥55% | riskant |

**Fazit:** Weniger, aber bessere Trades schlagen mehr schlechtere Trades fast immer. Optimum: **2-4 Trades/Tag mit ≥70% Confidence**.

### Wachstumsprognose (ab $210 Startkapital)

| Monat | 20%/Monat | 30%/Monat |
|-------|-----------|-----------|
| Start | $210 | $210 |
| +3 | $363 | $461 |
| +6 | $627 | $1.014 |
| +9 | $1.082 | $2.228 |

> ⚠️ Prognosen basieren auf historischen Win-Rates. Für valide Statistiken brauchen wir 50+ abgeschlossene Trades.

### Dynamische Kapitalallokation nach Kelly

Je größer der Bankroll, desto größer sollte der Max-Trade sein (konstant ~3-4% des Kapitals):

| Bankroll | Max/Trade (4%) | Min/Trade | Trades gleichzeitig |
|----------|---------------|-----------|---------------------|
| $60-100 | $4-10 (Cap $10) | $2.50 | 3-6 |
| $100-300 | $10-12 | $3.00 | 6-10 |
| $300-600 | $12-20 | $4.00 | 8-12 |
| $600-1.000 | $20-30 | $5.00 | 10-15 |
| $1.000+ | $30-40 | $5.00 | 10-20 |

**Wann den Cap erhöhen:**
- Bei $300 → Max auf $15 setzen
- Bei $600 → Max auf $25 setzen
- Bei $1.000 → Max auf $40 setzen

**Config anpassen:**
```bash
# In /home/node/.openclaw/workspace/trading/config.json
"max_bet_usd": 15  # bei $300 Bankroll
```

> Halbes Kelly (f/2) ist oft sicherer in der Praxis — weniger Volatilität, ~75% der Rendite.

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
