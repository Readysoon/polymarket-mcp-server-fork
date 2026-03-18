"""
FastAPI Web Dashboard for Polymarket MCP Server.

Provides web UI for:
- Configuration management
- Real-time monitoring
- Market discovery and analysis
- Connection testing
- Subscription management
"""
import asyncio
import json
import logging
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, Optional, List
import os

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request, Form, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
import uvicorn
from pydantic import BaseModel, ValidationError

from ..config import load_config, PolymarketConfig
from ..auth import create_polymarket_client, PolymarketClient
from ..utils import get_rate_limiter, create_safety_limits_from_config, SafetyLimits
from ..tools import market_discovery, market_analysis

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Initialize FastAPI app
app = FastAPI(
    title="Polymarket MCP Dashboard",
    description="Web dashboard for Polymarket MCP Server",
    version="0.1.0"
)

# Template and static file directories
BASE_DIR = Path(__file__).parent
STATIC_DIR = BASE_DIR / "static"
TEMPLATES_DIR = BASE_DIR / "templates"

# Mount static files
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")
templates = Jinja2Templates(directory=str(TEMPLATES_DIR))

# Global state
config: Optional[PolymarketConfig] = None
client: Optional[PolymarketClient] = None
safety_limits: Optional[SafetyLimits] = None
active_websockets: list[WebSocket] = []

# Statistics tracking
stats = {
    "requests_total": 0,
    "markets_viewed": 0,
    "api_calls": 0,
    "errors": 0,
    "uptime_start": datetime.now(),
}


class ConfigUpdateRequest(BaseModel):
    """Request model for configuration updates"""
    max_order_size_usd: float
    max_total_exposure_usd: float
    max_position_size_per_market: float
    min_liquidity_required: float
    max_spread_tolerance: float
    enable_autonomous_trading: bool
    require_confirmation_above_usd: float
    auto_cancel_on_large_spread: bool


async def load_mcp_config():
    """Load MCP configuration on startup"""
    global config, client, safety_limits

    try:
        logger.info("Loading MCP configuration...")
        config = load_config()

        # Initialize client - load .env for API_SECRET which isn't in the config model
        from dotenv import load_dotenv
        load_dotenv()
        api_secret = os.environ.get("POLYMARKET_API_SECRET", config.POLYMARKET_PASSPHRASE)
        client = create_polymarket_client(
            private_key=config.POLYGON_PRIVATE_KEY,
            address=config.POLYGON_ADDRESS,
            chain_id=config.POLYMARKET_CHAIN_ID,
            api_key=config.POLYMARKET_API_KEY,
            api_secret=api_secret,
            passphrase=config.POLYMARKET_PASSPHRASE,
        )

        # Initialize safety limits
        safety_limits = create_safety_limits_from_config(config)

        logger.info(f"Configuration loaded for address: {config.POLYGON_ADDRESS}")

    except Exception as e:
        logger.error(f"Failed to load configuration: {e}")
        logger.warning("Dashboard running without MCP connection")


@app.on_event("startup")
async def startup_event():
    """Initialize dashboard on startup"""
    await load_mcp_config()
    logger.info("Polymarket MCP Dashboard started")


@app.on_event("shutdown")
async def shutdown_event():
    """Cleanup on shutdown"""
    # Close all websockets
    for ws in active_websockets:
        await ws.close()
    logger.info("Dashboard shutdown complete")


# ============================================================================
# HTML Pages
# ============================================================================

@app.get("/", response_class=HTMLResponse)
async def dashboard_home(request: Request):
    """Dashboard home page"""
    stats["requests_total"] += 1

    # Calculate uptime
    uptime = datetime.now() - stats["uptime_start"]

    # Get MCP status
    mcp_status = {
        "connected": config is not None and client is not None,
        "mode": "FULL" if (client and client.has_api_credentials()) else "READ-ONLY",
        "address": config.POLYGON_ADDRESS if config else "Not configured",
        "chain_id": config.POLYMARKET_CHAIN_ID if config else None,
        "tools_available": 45 if (client and client.has_api_credentials()) else 25,
    }

    return templates.TemplateResponse("index.html", {
        "request": request,
        "mcp_status": mcp_status,
        "stats": stats,
        "uptime": str(uptime).split('.')[0],  # Remove microseconds
    })


@app.get("/config", response_class=HTMLResponse)
async def config_page(request: Request):
    """Configuration management page"""
    stats["requests_total"] += 1

    current_config = None
    if config and safety_limits:
        current_config = {
            "safety_limits": {
                "max_order_size_usd": safety_limits.max_order_size_usd,
                "max_total_exposure_usd": safety_limits.max_total_exposure_usd,
                "max_position_size_per_market": safety_limits.max_position_size_per_market,
                "min_liquidity_required": safety_limits.min_liquidity_required,
                "max_spread_tolerance": safety_limits.max_spread_tolerance,
            },
            "trading_controls": {
                "enable_autonomous_trading": config.ENABLE_AUTONOMOUS_TRADING,
                "require_confirmation_above_usd": config.REQUIRE_CONFIRMATION_ABOVE_USD,
                "auto_cancel_on_large_spread": config.AUTO_CANCEL_ON_LARGE_SPREAD,
            },
            "wallet": {
                "address": config.POLYGON_ADDRESS,
                "chain_id": config.POLYMARKET_CHAIN_ID,
            },
            "has_api_credentials": client.has_api_credentials() if client else False,
        }

    return templates.TemplateResponse("config.html", {
        "request": request,
        "config": current_config,
    })


@app.get("/markets", response_class=HTMLResponse)
async def markets_page(request: Request):
    """Markets discovery and analysis page"""
    stats["requests_total"] += 1

    return templates.TemplateResponse("markets.html", {
        "request": request,
    })


@app.get("/monitoring", response_class=HTMLResponse)
async def monitoring_page(request: Request):
    """System monitoring and analytics page"""
    stats["requests_total"] += 1

    # Get rate limiter status
    rate_limiter = get_rate_limiter()
    rate_status = rate_limiter.get_status() if config else {}

    # System info
    import sys
    import platform

    system_info = {
        "python_version": sys.version.split()[0],
        "platform": platform.platform(),
        "mcp_version": "0.1.0",
        "uptime": str(datetime.now() - stats["uptime_start"]).split('.')[0],
    }

    # MCP status
    mcp_status = {
        "connected": config is not None and client is not None,
        "mode": "FULL" if (client and client.has_api_credentials()) else "READ-ONLY",
        "address": config.POLYGON_ADDRESS if config else "Not configured",
        "chain_id": config.POLYMARKET_CHAIN_ID if config else None,
        "tools_available": 45 if (client and client.has_api_credentials()) else 25,
    }

    return templates.TemplateResponse("monitoring.html", {
        "request": request,
        "stats": stats,
        "rate_status": rate_status,
        "system_info": system_info,
        "mcp_status": mcp_status,
    })


# ============================================================================
# API Endpoints
# ============================================================================

@app.get("/api/portfolio")
async def get_portfolio():
    """Get active positions and trade history"""
    stats["api_calls"] += 1

    if not client or not client.has_api_credentials():
        return JSONResponse({"positions": [], "balance": 0, "error": "Not authenticated"})

    try:
        import httpx

        # Get trades from CLOB API
        clob = client.get_client()
        trades = clob.get_trades()

        # Get on-chain balances: USDC, USDC.e, POL
        address = config.POLYGON_ADDRESS
        usdc_contract = "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359"
        usdce_contract = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
        balance_selector = "0x70a08231" + address[2:].lower().zfill(64)

        async with httpx.AsyncClient() as http_client:
            # Fetch all balances in parallel
            rpc_calls = [
                # USDC (native)
                http_client.post("https://1rpc.io/matic", json={
                    "jsonrpc": "2.0", "method": "eth_call",
                    "params": [{"to": usdc_contract, "data": balance_selector}, "latest"], "id": 1
                }, timeout=10.0),
                # USDC.e (bridged)
                http_client.post("https://1rpc.io/matic", json={
                    "jsonrpc": "2.0", "method": "eth_call",
                    "params": [{"to": usdce_contract, "data": balance_selector}, "latest"], "id": 2
                }, timeout=10.0),
                # POL (native token balance)
                http_client.post("https://1rpc.io/matic", json={
                    "jsonrpc": "2.0", "method": "eth_getBalance",
                    "params": [address, "latest"], "id": 3
                }, timeout=10.0),
            ]
            results = await asyncio.gather(*rpc_calls, return_exceptions=True)

            def parse_balance(resp, decimals=6):
                if isinstance(resp, Exception):
                    return 0.0
                val = resp.json().get("result", "0x0")
                return int(val, 16) / 10**decimals if val and val != "0x" else 0.0

            usdc_balance = parse_balance(results[0], 6)
            usdce_balance = parse_balance(results[1], 6)
            pol_balance = parse_balance(results[2], 18)

        # Group trades by market and resolve market names
        market_trades = {}
        for trade in trades:
            market_id = trade.get("market", "unknown")
            if market_id not in market_trades:
                market_trades[market_id] = []
            market_trades[market_id].append(trade)

        # Resolve market names from Gamma API
        positions = []
        async with httpx.AsyncClient() as http_client:
            for market_id, mkt_trades in market_trades.items():
                # Try to get market name and resolution status
                market_name = market_id[:20] + "..."
                market_resolved = False
                market_active = True
                market_url = ""
                try:
                    r = await http_client.get(
                        "https://gamma-api.polymarket.com/markets",
                        params={"clob_token_ids": mkt_trades[0].get("asset_id", "")},
                        timeout=5.0
                    )
                    markets = r.json()
                    if markets:
                        market_name = markets[0].get("question", market_name)
                        market_active = markets[0].get("active", True)
                        market_resolved = markets[0].get("closed", False)
                        # Build Polymarket URL: /event/{event_slug}/{market_slug}
                        market_slug = markets[0].get("slug", "")
                        event_slug = ""
                        events = markets[0].get("events", [])
                        if events and isinstance(events, list):
                            event_slug = events[0].get("slug", "")
                        if event_slug and market_slug:
                            market_url = f"https://polymarket.com/event/{event_slug}/{market_slug}"
                        elif event_slug:
                            market_url = f"https://polymarket.com/event/{event_slug}"
                        elif market_slug:
                            market_url = f"https://polymarket.com/event/{market_slug}"
                except Exception:
                    pass

                # Calculate position
                total_shares = 0
                total_cost = 0
                outcome = mkt_trades[0].get("outcome", "Yes")
                for t in mkt_trades:
                    size = float(t.get("size", 0))
                    price = float(t.get("price", 0))
                    if t.get("side") == "BUY":
                        total_shares += size
                        total_cost += size * price
                    else:
                        total_shares -= size
                        total_cost -= size * price

                # Find last trade date for this market
                last_trade_date = ""
                for t in mkt_trades:
                    ts_str = t.get("match_time") or t.get("created_at") or t.get("timestamp", "")
                    try:
                        if isinstance(ts_str, (int, float)):
                            ts = datetime.utcfromtimestamp(ts_str)
                        elif ts_str:
                            ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00").replace("+00:00", ""))
                        else:
                            continue
                        d = ts.strftime("%Y-%m-%d")
                        if d > last_trade_date:
                            last_trade_date = d
                    except Exception:
                        pass

                if total_shares > 0:
                    avg_price = total_cost / total_shares if total_shares else 0

                    # Get current price
                    current_price = avg_price  # fallback
                    try:
                        r = await http_client.get(
                            "https://gamma-api.polymarket.com/markets",
                            params={"clob_token_ids": mkt_trades[0].get("asset_id", "")},
                            timeout=5.0
                        )
                        markets = r.json()
                        if markets:
                            # outcomePrices is a JSON string like "[\"0.57\",\"0.43\"]"
                            prices_str = markets[0].get("outcomePrices", "")
                            if prices_str:
                                import json as _json
                                prices = _json.loads(prices_str)
                                if outcome == "Yes" and len(prices) > 0:
                                    current_price = float(prices[0])
                                elif outcome == "No" and len(prices) > 1:
                                    current_price = float(prices[1])
                    except Exception:
                        pass

                    current_value = total_shares * current_price
                    pnl = current_value - total_cost
                    pnl_pct = (pnl / total_cost * 100) if total_cost > 0 else 0

                    positions.append({
                        "market": market_name,
                        "outcome": outcome,
                        "shares": round(total_shares, 4),
                        "avg_price": round(avg_price, 4),
                        "current_price": round(current_price, 4),
                        "cost": round(total_cost, 2),
                        "value": round(current_value, 2),
                        "pnl": round(pnl, 2),
                        "pnl_pct": round(pnl_pct, 1),
                        "realized": market_resolved or not market_active,
                        "market_active": market_active,
                        "tx": mkt_trades[0].get("transaction_hash", ""),
                        "market_url": market_url,
                        "last_trade_date": last_trade_date,
                    })

        total_value = usdc_balance + usdce_balance + sum(p["value"] for p in positions)

        # Save balance snapshot for history chart
        _save_balance_snapshot(
            total_value=round(total_value, 2),
            usdc=round(usdc_balance, 6),
            usdce=round(usdce_balance, 6),
            pol=round(pol_balance, 4),
            positions_value=round(sum(p["value"] for p in positions), 2),
            pnl=round(sum(p["pnl"] for p in positions), 2),
        )

        return JSONResponse({
            "positions": positions,
            "usdc_balance": round(usdc_balance, 6),
            "usdce_balance": round(usdce_balance, 6),
            "pol_balance": round(pol_balance, 4),
            "total_value": round(total_value, 2),
            "total_pnl": round(sum(p["pnl"] for p in positions), 2),
            "trade_count": len(trades),
        })

    except Exception as e:
        logger.error(f"Portfolio fetch failed: {e}")
        stats["errors"] += 1
        return JSONResponse({"positions": [], "balance": 0, "error": str(e)})


# ============================================================================
# Balance History
# ============================================================================

HISTORY_FILE = Path(__file__).parent / "balance_history.json"
_SNAPSHOT_INTERVAL = 300  # minimum seconds between snapshots (5 min)
_last_snapshot_time = 0.0


def _load_balance_history() -> List[Dict]:
    """Load balance history from JSON file."""
    if HISTORY_FILE.exists():
        try:
            return json.loads(HISTORY_FILE.read_text())
        except Exception:
            return []
    return []


def _save_balance_snapshot(total_value, usdc, usdce, pol, positions_value, pnl):
    """Save a balance snapshot if enough time has passed since the last one."""
    import time
    global _last_snapshot_time
    now = time.time()
    if now - _last_snapshot_time < _SNAPSHOT_INTERVAL:
        return
    _last_snapshot_time = now

    history = _load_balance_history()
    history.append({
        "t": datetime.utcnow().isoformat() + "Z",
        "total": total_value,
        "usdc": usdc,
        "usdce": usdce,
        "pol": pol,
        "positions": positions_value,
        "pnl": pnl,
    })
    # Keep max 2000 entries (~7 days at 5-min intervals)
    if len(history) > 2000:
        history = history[-2000:]
    try:
        HISTORY_FILE.write_text(json.dumps(history))
    except Exception as e:
        logger.error(f"Failed to save balance history: {e}")


@app.get("/api/watchlist")
async def get_watchlist():
    """Get current market watchlist - candidates found by the scanner."""
    stats["api_calls"] += 1

    try:
        wl_paths = [
            Path(os.environ.get("OPENCLAW_STATE_DIR", "/home/node/.openclaw")) / "workspace" / "trading" / "watchlist.json",
            Path(__file__).parent.parent.parent.parent / "openclaw" / "workspace" / "trading" / "watchlist.json",
        ]

        data = {"markets": [], "last_scanned": None}
        for wp in wl_paths:
            if wp.exists():
                try:
                    data = json.loads(wp.read_text())
                    break
                except Exception:
                    continue

        # Also read log.json to find which condition_ids have been traded/processed
        log_paths = [
            Path(os.environ.get("OPENCLAW_STATE_DIR", "/home/node/.openclaw")) / "workspace" / "trading" / "log.json",
            Path(__file__).parent.parent.parent.parent / "openclaw" / "workspace" / "trading" / "log.json",
        ]
        processed_ids = set()
        check_counts: dict = {}  # condition_id -> count of NOT_READY checks
        last_check_times: dict = {}  # condition_id -> last check timestamp
        for lp in log_paths:
            if lp.exists():
                try:
                    for entry in json.loads(lp.read_text()):
                        cid = entry.get("condition_id", "")
                        if entry.get("result") in ("TRADED", "EXPIRED", "TIMEOUT"):
                            processed_ids.add(cid)
                        if cid:
                            check_counts[cid] = check_counts.get(cid, 0) + 1
                            ts = entry.get("timestamp", "")
                            if ts > last_check_times.get(cid, ""):
                                last_check_times[cid] = ts
                except Exception:
                    pass
                break

        # Read cron jobs to find next scheduled check per condition_id
        next_check_times: dict = {}
        try:
            import subprocess as sp
            cron_out = sp.run(["openclaw", "cron", "list", "--json"], capture_output=True, text=True, timeout=5)
            if cron_out.returncode == 0:
                cron_jobs = json.loads(cron_out.stdout) if cron_out.stdout.strip() else []
                for job in cron_jobs:
                    name = job.get("name", "")
                    if name.startswith("watch:"):
                        cid_prefix = name[6:]  # strip "watch:"
                        fire_at = job.get("schedule", {}).get("at") or job.get("nextRunAt") or ""
                        if fire_at:
                            # Match full condition_id by prefix
                            for full_cid in list(check_counts.keys()) + [m.get("condition_id","") for m in data.get("markets",[])]:
                                if full_cid.startswith(cid_prefix):
                                    next_check_times[full_cid] = fire_at
        except Exception:
            pass

        # Filter: only markets not yet processed, and not already expired
        now = datetime.utcnow()
        pending = []
        for m in data.get("markets", []):
            cid = m.get("condition_id", "")
            if cid in processed_ids:
                continue
            # Check if end_datetime is still in the future
            try:
                end = datetime.fromisoformat(m.get("end_datetime", "").replace("Z", "+00:00").replace("+00:00", ""))
                if end < now:
                    continue
            except Exception:
                pass
            pending.append({
                "question": m.get("question", "Unknown"),
                "yes_price": m.get("yes_price"),
                "liquidity": m.get("liquidity"),
                "end_date": m.get("end_date"),
                "end_datetime": m.get("end_datetime"),
                "volume_24h": m.get("volume_24h"),
                "condition_id": cid,
                "slug": m.get("slug", ""),
                "check_count": check_counts.get(cid, 0),
                "last_check": last_check_times.get(cid, None),
                "next_check": next_check_times.get(cid, None),
            })

        return JSONResponse({
            "markets": pending,
            "count": len(pending),
            "total_scanned": len(data.get("markets", [])),
            "last_scanned": data.get("last_scanned"),
        })

    except Exception as e:
        logger.error(f"Watchlist fetch failed: {e}")
        stats["errors"] += 1
        return JSONResponse({"markets": [], "error": str(e)})


@app.get("/api/scan-results")
async def get_scan_results(date: Optional[str] = None):
    """Get market scanner results from log.json, filtered by date. Defaults to today."""
    stats["api_calls"] += 1

    try:
        # Read log.json from the workspace on the filesystem
        log_paths = [
            Path(os.environ.get("OPENCLAW_STATE_DIR", "/home/node/.openclaw")) / "workspace" / "trading" / "log.json",
            Path(__file__).parent.parent.parent.parent / "openclaw" / "workspace" / "trading" / "log.json",
        ]

        entries = []
        for lp in log_paths:
            if lp.exists():
                try:
                    entries = json.loads(lp.read_text())
                    break
                except Exception:
                    continue

        # Parse filter date (default: today)
        if date:
            try:
                filter_date = datetime.strptime(date, "%Y-%m-%d").date()
            except ValueError:
                filter_date = datetime.utcnow().date()
        else:
            filter_date = datetime.utcnow().date()

        # Filter and format entries
        results = []
        for entry in entries:
            ts_str = entry.get("timestamp", "")
            try:
                ts = datetime.fromisoformat(ts_str)
                if ts.date() != filter_date:
                    continue
            except Exception:
                continue

            # Truncate long error reasons and strip internal tool errors
            reason = entry.get("reason", "")
            if "\n" in reason:
                reason = reason.split("\n")[0]
            # Strip noisy internal mcporter errors
            if "[mcporter]" in reason or "Unknown MCP server" in reason:
                reason = reason.split(":")[0].strip()  # keep only the prefix e.g. "No orderbook available"
            if len(reason) > 120:
                reason = reason[:117] + "..."

            results.append({
                "time": ts.strftime("%H:%M:%S"),
                "timestamp": ts.isoformat(),
                "question": entry.get("question", "Unknown"),
                "result": entry.get("result", "UNKNOWN"),
                "reason": reason,
                "action": entry.get("action", ""),
                "hours_left": entry.get("hours_left"),
                "end_datetime": entry.get("end_datetime"),
                "best_bid": entry.get("best_bid"),
                "best_ask": entry.get("best_ask"),
                "spread": entry.get("spread"),
                "mid": entry.get("mid"),
                "bet_size_usd": entry.get("bet_size_usd"),
                "order_id": entry.get("order_id"),
                "condition_id": entry.get("condition_id", ""),
            })

        # Sort by time
        results.sort(key=lambda x: x["timestamp"])

        # Count by result type
        result_counts = {}
        for r in results:
            result_counts[r["result"]] = result_counts.get(r["result"], 0) + 1

        return JSONResponse({
            "results": results,
            "date": filter_date.isoformat(),
            "count": len(results),
            "counts_by_result": result_counts,
        })

    except Exception as e:
        logger.error(f"Scan results fetch failed: {e}")
        stats["errors"] += 1
        return JSONResponse({"results": [], "error": str(e)})


@app.get("/api/balance-history")
async def get_balance_history():
    """Get balance history for charting."""
    history = _load_balance_history()
    return JSONResponse({"history": history})


@app.get("/api/status")
async def get_status():
    """Get MCP connection status"""
    stats["api_calls"] += 1

    if not config or not client:
        return JSONResponse({
            "connected": False,
            "error": "MCP not configured"
        })

    return JSONResponse({
        "connected": True,
        "address": config.POLYGON_ADDRESS,
        "chain_id": config.POLYMARKET_CHAIN_ID,
        "has_api_credentials": client.has_api_credentials(),
        "mode": "FULL" if client.has_api_credentials() else "READ-ONLY",
        "tools_available": 45 if client.has_api_credentials() else 25,
        "rate_limits": get_rate_limiter().get_status(),
    })


@app.get("/api/test-connection")
async def test_connection():
    """Test Polymarket API connection"""
    stats["api_calls"] += 1

    if not client:
        stats["errors"] += 1
        raise HTTPException(status_code=500, detail="MCP client not initialized")

    try:
        # Try to fetch trending markets as connection test
        result = await market_discovery.handle_tool("get_trending_markets", {"limit": 5})

        return JSONResponse({
            "success": True,
            "message": "Connection successful",
            "markets_found": len(result),
        })
    except Exception as e:
        stats["errors"] += 1
        logger.error(f"Connection test failed: {e}")
        return JSONResponse({
            "success": False,
            "error": str(e)
        }, status_code=500)


@app.get("/api/markets/trending")
async def get_trending_markets(limit: int = 10):
    """Get trending markets"""
    stats["api_calls"] += 1

    try:
        result = await market_discovery.handle_tool("get_trending_markets", {"limit": limit})
        stats["markets_viewed"] += 1

        # Extract text content from MCP response
        if result and len(result) > 0:
            import json
            data = json.loads(result[0].text)
            return JSONResponse(data)

        return JSONResponse({"markets": []})

    except Exception as e:
        stats["errors"] += 1
        logger.error(f"Failed to get trending markets: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/markets/search")
async def search_markets(q: str, limit: int = 20):
    """Search markets by query"""
    stats["api_calls"] += 1

    try:
        result = await market_discovery.handle_tool("search_markets", {
            "query": q,
            "limit": limit
        })
        stats["markets_viewed"] += 1

        if result and len(result) > 0:
            import json
            data = json.loads(result[0].text)
            return JSONResponse(data)

        return JSONResponse({"markets": []})

    except Exception as e:
        stats["errors"] += 1
        logger.error(f"Search failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/markets/{market_id}")
async def get_market_details(market_id: str):
    """Get detailed market information"""
    stats["api_calls"] += 1

    try:
        result = await market_analysis.handle_tool("get_market_details", {
            "market_id": market_id
        })

        if result and len(result) > 0:
            import json
            data = json.loads(result[0].text)
            return JSONResponse(data)

        raise HTTPException(status_code=404, detail="Market not found")

    except Exception as e:
        stats["errors"] += 1
        logger.error(f"Failed to get market details: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/markets/{market_id}/analyze")
async def analyze_market(market_id: str):
    """Analyze market opportunity"""
    stats["api_calls"] += 1

    try:
        result = await market_analysis.handle_tool("analyze_market_opportunity", {
            "market_id": market_id
        })

        if result and len(result) > 0:
            import json
            data = json.loads(result[0].text)
            return JSONResponse(data)

        raise HTTPException(status_code=404, detail="Market not found")

    except Exception as e:
        stats["errors"] += 1
        logger.error(f"Market analysis failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/config")
async def update_config(config_update: ConfigUpdateRequest):
    """Update configuration (saves to .env file)"""
    stats["api_calls"] += 1

    try:
        # Update environment file
        env_file = Path(".env")

        if not env_file.exists():
            stats["errors"] += 1
            raise HTTPException(status_code=404, detail=".env file not found")

        # Read current .env
        env_lines = env_file.read_text().split('\n')
        updated_lines = []

        # Update values
        updates = {
            "MAX_ORDER_SIZE_USD": str(config_update.max_order_size_usd),
            "MAX_TOTAL_EXPOSURE_USD": str(config_update.max_total_exposure_usd),
            "MAX_POSITION_SIZE_PER_MARKET": str(config_update.max_position_size_per_market),
            "MIN_LIQUIDITY_REQUIRED": str(config_update.min_liquidity_required),
            "MAX_SPREAD_TOLERANCE": str(config_update.max_spread_tolerance),
            "ENABLE_AUTONOMOUS_TRADING": str(config_update.enable_autonomous_trading).lower(),
            "REQUIRE_CONFIRMATION_ABOVE_USD": str(config_update.require_confirmation_above_usd),
            "AUTO_CANCEL_ON_LARGE_SPREAD": str(config_update.auto_cancel_on_large_spread).lower(),
        }

        for line in env_lines:
            updated = False
            for key, value in updates.items():
                if line.startswith(f"{key}="):
                    updated_lines.append(f"{key}={value}")
                    updated = True
                    break
            if not updated:
                updated_lines.append(line)

        # Write back
        env_file.write_text('\n'.join(updated_lines))

        # Reload config
        await load_mcp_config()

        return JSONResponse({
            "success": True,
            "message": "Configuration updated successfully. Restart MCP server for changes to take effect."
        })

    except Exception as e:
        stats["errors"] += 1
        logger.error(f"Config update failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/stats")
async def get_stats():
    """Get dashboard statistics"""
    return JSONResponse({
        **stats,
        "uptime": str(datetime.now() - stats["uptime_start"]).split('.')[0],
        "uptime_seconds": (datetime.now() - stats["uptime_start"]).total_seconds(),
    })


# ============================================================================
# WebSocket for Real-time Updates
# ============================================================================

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    """WebSocket for real-time dashboard updates"""
    await websocket.accept()
    active_websockets.append(websocket)

    try:
        # Send initial status
        safe_stats = {k: (v.isoformat() if isinstance(v, datetime) else v) for k, v in stats.items()}
        await websocket.send_json({
            "type": "status",
            "data": {
                "connected": config is not None,
                "stats": safe_stats,
            }
        })

        # Keep connection alive and send periodic updates
        while True:
            await asyncio.sleep(5)  # Update every 5 seconds

            # Send stats update
            safe_stats = {k: (v.isoformat() if isinstance(v, datetime) else v) for k, v in stats.items()}
            await websocket.send_json({
                "type": "stats_update",
                "data": {
                    "stats": safe_stats,
                    "timestamp": datetime.now().isoformat(),
                }
            })

    except WebSocketDisconnect:
        active_websockets.remove(websocket)
        logger.info("WebSocket client disconnected")
    except Exception as e:
        logger.error(f"WebSocket error: {e}")
        if websocket in active_websockets:
            active_websockets.remove(websocket)


async def broadcast_update(message: dict):
    """Broadcast message to all connected WebSocket clients"""
    disconnected = []
    for ws in active_websockets:
        try:
            await ws.send_json(message)
        except Exception as e:
            logger.error(f"Failed to send to WebSocket: {e}")
            disconnected.append(ws)

    # Remove disconnected clients
    for ws in disconnected:
        active_websockets.remove(ws)


# ============================================================================
# Server Startup
# ============================================================================

def start(host: str = "0.0.0.0", port: int = 8080):
    """Start the web dashboard server"""
    logger.info(f"Starting Polymarket MCP Dashboard on http://{host}:{port}")
    uvicorn.run(app, host=host, port=port)


if __name__ == "__main__":
    start()
