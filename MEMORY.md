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
- **Scanner** (täglich 23:00 UTC = 00:00 Innsbruck): filtert Märkte >$50k Volumen, Spread <10%, YES 40-85¢
- **Market Watcher**: 4h vor Schluss, AI-Analyse, Confidence <55% = Skip
- **Position Sizing**: Bankroll <$50 → 50% | ≥$50 → 20% | Min $0.50 | Max $25
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
- **Take-Profit / Swing Trading:** YES-Positionen nicht bis zur Resolution halten, sondern bei +20-30% Preisanstieg automatisch verkaufen (SELL Order). Sofortiger USDC-Rückfluss ohne 72h Oracle-Wait. Implementierung: 30-60 Min nach Trade einen Preis-Check-Cron registrieren → wenn Preis ≥ Einkauf + 25% → automatisch verkaufen via `create_market_order side=SELL`.
- **Confidence-basierte Kapitalallokation:** Scanner macht erst Research für ALLE Kandidaten des Tages → dann verfügbares Kapital nach Confidence einteilen. Beispiel: 80%+ bekommt 30% des Kapitals, 70-79% bekommt 20%, 65-69% bekommt 10%. So geht das meiste Geld in die besten Picks statt gleichmäßig verteilt.

## Präferenzen / Gelerntes
- Mitternacht Innsbruck = 23:00 UTC (Winter), 22:00 UTC (Sommer)
- Chat-Logging: Sessions-History auf Abruf (kein Cron-Job)
- Philipp mag es wenn ich direkt handle, nicht frage
- Erst gestern (2026-03-19) gestartet — erste Session
