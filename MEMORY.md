# MEMORY.md — Delta's Langzeitgedächtnis

## Wer ich bin
- Name: **Delta** (Δ)
- Rolle: AI Trading Assistant für Polymarket
- Vibe: Sharp, efficient, kein Fluff

## Philipp
- Name: Philipp
- Telegram: @Bikiniboy
- Standort: **Innsbruck, Österreich** (UTC+1 Winter, UTC+2 Sommer)
- Interesse: Polymarket Prediction Market Trading
- Präferenz: Wenig Compute-Overhead, klare Antworten, kein Blabla

## Projekt
- GitHub: `Readysoon/polymarket-mcp-server-fork`
- Polymarket MCP Server (Python) + Bash Trading Scripts
- Dashboard auf Fly.io

## Trading System
- **Live Monitor** (alle 5 Min): ESPN win% ≥90% → Kauf, kein Bet-Cap, Quarter Kelly × ESPN-Divergenz-Multiplikator
- **Position Sizing**: Quarter Kelly × Divergenz-Mult (1.0x/1.5x/2.0x), kein Cap
- **Paper Trading: DEAKTIVIERT seit 2026-04-05 09:51 UTC** — ab jetzt echtes Geld
- **Redeem**: automatisch vor jedem Trade

## Aktive Cron Jobs
- `9dc6664a` — Daily Market Scanner, täglich 09:00 UTC (= 10:00 Innsbruck), Timeout 300s, Zeiten in Innsbruck-Zeit
- `7cb15a18` — Outcome Checker, täglich 08:00 UTC (= 09:00 Innsbruck)

## Git Workflow (PFLICHT)
Ein einziges Repo (`Readysoon/polymarket-mcp-server-fork`, Branch `main`):
- **`/home/node/.openclaw/workspace`** → alles: Agent-Dateien, Trading Scripts, Dashboard Code (src/)
- `/data/openclaw/workspace/repo` existiert NICHT mehr — wurde konsolidiert

1. Session-Start → `git pull` in `/home/node/.openclaw/workspace`
2. Vor jeder Änderung → `git pull`
3. Nach Änderungen → `git commit` + `git push`

## Watcher-Agent Design (NICHT ÄNDERN!)
- Der Watcher-Job ist ein **Claude-Agent** mit web_fetch Tool
- Er macht das Research SELBST via web_fetch (covers.com, hltv.org, liquipedia etc.)
- Das market_watcher.sh Script ist NUR für den Trade zuständig — kein Research im Script!
- Ablauf: Agent fetcht Seiten → analysiert Expert-Picks → schreibt research.json → startet Script
- NIEMALS den Prompt so ändern dass das Script das Research übernimmt
- Das Python httpx Research im Script ist ein Fallback, aber der Agent soll primär forschen

## Ideen für demnächst
- **Market Making:** Polymarket CLOB als MM nutzen — gleichzeitig Bid + Ask stellen, Spread kassieren ohne direktionales Risiko. Collateral für beide Seiten nötig. Beste Chance in illiquiden Märkten wo Spread groß ist. Eigenes System neben dem aktuellen directional Trading. Vorsicht: adverse selection wenn informierte Trader gegen uns traden.
- **Alternative Research APIs (besser als Brave):**
  - **Perplexity API** — Spezialisiert auf Web-Antworten mit Quellen, ~$20/Monat für 5000 Anfragen. Sehr gut für Sports Research.
  - **Gemini 2.0 Flash + Google Search Grounding** — Günstigste Option (~$0.001/Query), Google hat beste Sports-Datenbank (ESPN direkt). Sehr zu empfehlen wenn wir skalieren.
  - **OpenAI GPT-4o mit Browsing** — Intelligenteste Option aber teuer ($0.01-0.03/Query).
  - Aktuell: Brave AI Answers ist gut genug. Bei >$200 Bankroll oder schlechterer Performance testen.
- **Pre-Research + Kapitalallokation im Scanner:** Scanner macht Research für alle Kandidaten VOR dem Registrieren der Watcher-Jobs. Dann verfügbares Cash (80%, 20% Reserve) nach Confidence gewichten: 80-100%→30%, 70-79%→20%, 65-69%→10%. `allocated_usd` pro Markt in research.json schreiben. Watcher bekommt nur spezifische Daten (kein Zugriff auf ganze research.json). Implementiert in `high-speed-trading` Branch, noch nicht in main.


- **Take-Profit / Swing Trading:** YES-Positionen nicht bis zur Resolution halten, sondern bei +20-30% Preisanstieg automatisch verkaufen (SELL Order). Sofortiger USDC-Rückfluss ohne 72h Oracle-Wait. Implementierung: 30-60 Min nach Trade einen Preis-Check-Cron registrieren → wenn Preis ≥ Einkauf + 25% → automatisch verkaufen via `create_market_order side=SELL`.
- **Confidence-basierte Kapitalallokation:** Scanner macht erst Research für ALLE Kandidaten des Tages → dann verfügbares Kapital nach Confidence einteilen. Beispiel: 80%+ bekommt 30% des Kapitals, 70-79% bekommt 20%, 65-69% bekommt 10%. So geht das meiste Geld in die besten Picks statt gleichmäßig verteilt.

## Präferenzen / Gelerntes
- Mitternacht Innsbruck = 23:00 UTC (Winter), 22:00 UTC (Sommer)
- Chat-Logging: Sessions-History auf Abruf (kein Cron-Job)
- Philipp mag es wenn ich direkt handle, nicht frage
- Erst gestern (2026-03-19) gestartet — erste Session
