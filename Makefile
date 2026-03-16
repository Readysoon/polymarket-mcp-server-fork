# Polymarket MCP Server + OpenClaw - Makefile
# Quick commands for dashboard, bot, and trading

.PHONY: help dashboard bot bot-stop bot-status bot-logs portfolio markets status push security

.DEFAULT_GOAL := help

# Paths
VENV := /Users/philipp/polymarket-mcp-server/venv/bin
NODE22 := /opt/homebrew/opt/node@22/bin
PROJECT := /Users/philipp/polymarket-mcp-server

## help: Show this help message
help:
	@echo "Polymarket MCP + OpenClaw Commands"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@awk '/^##/ {desc = substr($$0, 4); getline; printf "  \033[36m%-18s\033[0m %s\n", $$1, desc}' $(MAKEFILE_LIST)

# ── Dashboard ──

## dashboard: Start the web dashboard (localhost:8080)
dashboard:
	@echo "Starting dashboard at http://localhost:8080 ..."
	@cd $(PROJECT) && $(VENV)/polymarket-web

## dashboard-bg: Start dashboard in background
dashboard-bg:
	@echo "Starting dashboard in background..."
	@cd $(PROJECT) && $(VENV)/polymarket-web &
	@echo "Dashboard running at http://localhost:8080"

## dashboard-stop: Stop the web dashboard
dashboard-stop:
	@pkill -f "polymarket-web" 2>/dev/null && echo "Dashboard stopped" || echo "Dashboard not running"

# ── OpenClaw Telegram Bot ──

## bot: Start the OpenClaw gateway (foreground)
bot:
	@echo "Starting OpenClaw gateway..."
	@PATH=$(NODE22):$$PATH openclaw gateway --force

## bot-bg: Start the OpenClaw gateway in background
bot-bg:
	@PATH=$(NODE22):$$PATH openclaw gateway --force &
	@echo "Bot running in background"

## bot-stop: Stop the OpenClaw gateway
bot-stop:
	@pkill -f "openclaw" 2>/dev/null && echo "Bot stopped" || echo "Bot not running"

## bot-status: Check bot and channel status
bot-status:
	@PATH=$(NODE22):$$PATH openclaw status

## bot-logs: Tail bot logs
bot-logs:
	@PATH=$(NODE22):$$PATH openclaw logs

## bot-configure: Open interactive config wizard
bot-configure:
	@PATH=$(NODE22):$$PATH openclaw configure

# ── Polymarket Trading ──

## portfolio: Check your portfolio positions
portfolio:
	@PATH=$(NODE22):$$PATH mcporter call polymarket.get_all_positions

## markets: Show trending markets
markets:
	@PATH=$(NODE22):$$PATH mcporter call polymarket.get_trending_markets

## search: Search markets (usage: make search q="trump")
search:
	@PATH=$(NODE22):$$PATH mcporter call polymarket.search_markets query="$(q)"

## orders: Check open orders
orders:
	@PATH=$(NODE22):$$PATH mcporter call polymarket.get_open_orders

## history: Show trade history
history:
	@PATH=$(NODE22):$$PATH mcporter call polymarket.get_trade_history

# ── Combined ──

## start: Start dashboard + bot together
start: dashboard-bg bot-bg
	@echo ""
	@echo "✅ Dashboard: http://localhost:8080"
	@echo "✅ Bot: @PolyClawTrader_Bot on Telegram"

## stop: Stop everything
stop: dashboard-stop bot-stop
	@echo "All services stopped"

## status: Show all service status
status:
	@echo "── Dashboard ──"
	@curl -s -o /dev/null -w "  HTTP %{http_code}\n" http://localhost:8080/ 2>/dev/null || echo "  Not running"
	@echo ""
	@echo "── OpenClaw Bot ──"
	@PATH=$(NODE22):$$PATH openclaw channels status --probe 2>/dev/null || echo "  Not running"

# ── Git ──

## push: Commit and push changes to GitHub
push:
	@cd $(PROJECT) && git add -A && git status --short
	@echo ""
	@read -p "Commit message: " msg; \
	cd $(PROJECT) && git commit -m "$$msg" && git push origin main

# ── Security ──

## security: Run security checks
security:
	@echo "── Git secrets check ──"
	@cd $(PROJECT) && git log --all --diff-filter=A -- .env && echo "  ✅ .env never committed" || true
	@echo ""
	@echo "── .gitignore check ──"
	@grep -q "\.env" $(PROJECT)/.gitignore && echo "  ✅ .env in .gitignore" || echo "  ❌ .env NOT in .gitignore!"
	@echo ""
	@echo "── OpenClaw security ──"
	@PATH=$(NODE22):$$PATH openclaw security audit 2>/dev/null || echo "  Run manually: openclaw security audit"

# ── Docker (legacy) ──

## docker-up: Start Docker services
docker-up:
	@docker compose up -d

## docker-down: Stop Docker services
docker-down:
	@docker compose down

## docker-logs: View Docker logs
docker-logs:
	@docker compose logs -f
