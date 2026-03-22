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
- **Scanner** (täglich 11:00 Innsbruck): filtert Märkte >$100k Volumen, Spread <5%, YES 50-80¢
- **Market Watcher**: 4h vor Schluss, Web Research (Forebet/Sofascore/Reddit/ESPN), Confidence <65% = Skip
- **Position Sizing**: Bankroll <$50 → 50% | ≥$50 → 20% | Min $0.50 | Max $25
- **Redeem**: Auto-Redeemer alle 2h (Cron b883aced)
- **Auto-Redeemer**: `b883aced` — alle 2h, nur Nachricht wenn echtes USDC reingekommen

## Aktive Cron Jobs
- `9dc6664a` — Daily Market Scanner, täglich 11:00 Innsbruck-Zeit (Europe/Vienna Timezone, passt sich Sommerzeit an), Timeout 300s
- `7cb15a18` — Outcome Checker, täglich 08:00 UTC (= 09:00 Innsbruck)

## Git Workflow (PFLICHT)
Zwei Branches im selben Repo (`Readysoon/polymarket-mcp-server-fork`):
- **`workspace`** → Agent-Dateien (MEMORY, SOUL, USER, memory/, trading/) — Repo: `/home/node/.openclaw/workspace`
- **`main`** → MCP Server Code, Trading Scripts — Repo: `/data/openclaw/workspace/repo/`

1. Session-Start → `git pull` in beiden Repos
2. Vor jeder Änderung → `git pull`
3. Nach Änderungen → `git commit` + `git push` im richtigen Repo

## Geplante Features
- **Confidence vs. Return Analyse**: Wenn >20 Trades mit Confidence vorhanden, vergleiche:
  - Vorhergesagte Confidence (z.B. 78%) vs. tatsächlicher Return (z.B. +92% oder -100%)
  - Pro Confidence-Bucket (60-70%, 70-80%, 80%+): avg. Return, Win Rate, Expected Value
  - Ziel: ab welcher Confidence ist EV positiv? → Schwelle anpassen
  - Daten liegen in `trading/log.json` als `RESEARCH` (confidence_pct) und `TRADED` Einträge

## Präferenzen / Gelerntes
- Mitternacht Innsbruck = 23:00 UTC (Winter), 22:00 UTC (Sommer)
- Chat-Logging: Sessions-History auf Abruf (kein Cron-Job)
- Philipp mag es wenn ich direkt handle, nicht frage
- Erst gestern (2026-03-19) gestartet — erste Session
