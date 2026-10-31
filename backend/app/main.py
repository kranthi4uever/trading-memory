from __future__ import annotations

import hmac
import math
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
from datetime import date, datetime, timezone
from functools import lru_cache
from typing import Any
from urllib.parse import urlencode

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, RedirectResponse

load_dotenv()

API_KEY         = os.getenv("KITE_API_KEY", "").strip()
API_SECRET      = os.getenv("KITE_API_SECRET", "").strip()
LOCAL_API_TOKEN = os.getenv("TRADING_MEMORY_LOCAL_API_TOKEN", "").strip()
REDIRECT_URL    = os.getenv(
    "KITE_REDIRECT_URL", "http://127.0.0.1:8765/api/kite/callback"
).strip()

app = FastAPI(title="Trading Memory Local Market Data", version="0.1.0")

_kite: Any | None = None

# Keep the daily Kite access token outside the repository and backend/.env.
# On macOS use the login Keychain; on other development platforms use a
# private user-owned file with restrictive permissions.
_TOKEN_KEYCHAIN_SERVICE = "com.tradingmemory.kite-access-token"
_TOKEN_FILE             = Path.home() / ".trading-memory" / "kite_access_token"


def _load_persisted_access_token() -> str | None:
    if not API_KEY:
        return None
    if sys.platform == "darwin":
        try:
            result = subprocess.run(
                ["/usr/bin/security", "find-generic-password", "-s", _TOKEN_KEYCHAIN_SERVICE,
                 "-a", API_KEY, "-w"],
                capture_output=True, text=True, timeout=5, check=True,
            )
            token = result.stdout.strip()
            return token or None
        except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
            return None
    try:
        token = _TOKEN_FILE.read_text(encoding="utf-8").strip()
        return token or None
    except (FileNotFoundError, OSError):
        return None


def _persist_access_token(token: str) -> None:
    if sys.platform == "darwin":
        subprocess.run(
            ["/usr/bin/security", "add-generic-password", "-U", "-s", _TOKEN_KEYCHAIN_SERVICE,
             "-a", API_KEY, "-w", token],
            capture_output=True, text=True, timeout=5, check=True,
        )
        return
    _TOKEN_FILE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(_TOKEN_FILE.parent, 0o700)
    temporary = _TOKEN_FILE.with_suffix(".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(token)
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, _TOKEN_FILE)
        os.chmod(_TOKEN_FILE, 0o600)
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


def _clear_persisted_access_token() -> None:
    if sys.platform == "darwin":
        try:
            subprocess.run(
                ["/usr/bin/security", "delete-generic-password", "-s", _TOKEN_KEYCHAIN_SERVICE,
                 "-a", API_KEY],
                capture_output=True, text=True, timeout=5, check=False,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass
        return
    try:
        _TOKEN_FILE.unlink(missing_ok=True)
    except OSError:
        pass


_access_token: str | None = _load_persisted_access_token()
_instruments_cache: list[dict[str, Any]] = []
_instruments_loaded_at: datetime | None = None
_exchange_instruments_cache: dict[str, list[dict[str, Any]]] = {}
_exchange_instruments_loaded_at: dict[str, datetime] = {}


def _normalize_ca_bundle_environment() -> None:
    """Remove stale CA-bundle environment overrides without disabling TLS verification.

    A broken REQUESTS_CA_BUNDLE/CURL_CA_BUNDLE/SSL_CERT_FILE override makes
    requests (and therefore Kite Connect) fail before any quote is retrieved.
    Let requests use its normal certifi/system default when an override points
    to a missing file. Never turn certificate verification off.
    """
    for variable in ("REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "SSL_CERT_FILE"):
        configured = os.environ.get(variable, "").strip()
        if configured and not Path(configured).is_file():
            os.environ.pop(variable, None)

    # Some Python installs retain a certifi path after its bundle has been
    # moved or removed. Prefer a real OS CA bundle if certifi's path is broken.
    try:
        import certifi
        certifi_path = Path(certifi.where())
    except (ImportError, OSError):
        certifi_path = Path("/nonexistent/trading-memory-ca-bundle")
    if not certifi_path.is_file():
        defaults = ssl.get_default_verify_paths()
        candidates = [
            Path(defaults.cafile) if defaults.cafile else None,
            Path("/etc/ssl/cert.pem"),
            Path("/etc/ssl/certs/ca-certificates.crt"),
            Path("/opt/homebrew/etc/openssl@3/cert.pem"),
            Path("/usr/local/etc/openssl@3/cert.pem"),
        ]
        system_bundle = next((candidate for candidate in candidates if candidate and candidate.is_file()), None)
        if system_bundle is not None:
            os.environ["REQUESTS_CA_BUNDLE"] = str(system_bundle)


def _kite_client() -> Any:
    global _kite
    _normalize_ca_bundle_environment()
    if not API_KEY:
        raise HTTPException(503, "KITE_API_KEY is not configured in backend/.env")
    if _kite is None:
        try:
            from kiteconnect import KiteConnect
        except ImportError as exc:  # pragma: no cover - environment setup error
            raise HTTPException(503, "Install backend requirements.txt first") from exc
        _kite = KiteConnect(api_key=API_KEY)
    return _kite


def _connected_kite() -> Any:
    if not _access_token:
        raise HTTPException(
            401,
            "Zerodha is not connected. Open http://127.0.0.1:8765/api/kite/login "
            "in a browser on your Mac, complete login, then refresh the app.",
        )
    client = _kite_client()
    client.set_access_token(_access_token)
    return client


def _require_local_token(
    x_trading_memory_token: str | None = Header(default=None),
) -> None:
    if not LOCAL_API_TOKEN:
        raise HTTPException(
            503,
            "TRADING_MEMORY_LOCAL_API_TOKEN is not configured in backend/.env",
        )
    if not x_trading_memory_token or not hmac.compare_digest(
        x_trading_memory_token, LOCAL_API_TOKEN
    ):
        raise HTTPException(401, "Missing or invalid local app token")


def _as_iso(value: Any) -> str | None:
    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        return value.date().isoformat()
    if isinstance(value, date):
        return value.isoformat()
    text = str(value)
    return text[:10] if len(text) >= 10 else text


def _parse_date(value: Any) -> date | None:
    iso = _as_iso(value)
    if not iso:
        return None
    try:
        return date.fromisoformat(iso)
    except ValueError:
        return None


def _get_instruments(client: Any) -> list[dict[str, Any]]:
    global _instruments_cache, _instruments_loaded_at
    now = datetime.now(timezone.utc)
    if (
        _instruments_cache
        and _instruments_loaded_at
        and (now - _instruments_loaded_at).total_seconds() < 12 * 60 * 60
    ):
        return _instruments_cache
    try:
        _instruments_cache = client.instruments("NFO")
        _instruments_loaded_at = now
    except Exception as exc:
        raise HTTPException(502, f"Could not load Zerodha instrument master: {exc}") from exc
    return _instruments_cache


def _nifty_options(client: Any) -> list[dict[str, Any]]:
    rows = _get_instruments(client)
    result = []
    for row in rows:
        if row.get("name") != "NIFTY":
            continue
        if row.get("segment") != "NFO-OPT":
            continue
        if row.get("instrument_type") not in ("CE", "PE"):
            continue
        if not row.get("tradingsymbol") or row.get("strike") in (None, ""):
            continue
        expiry = _parse_date(row.get("expiry"))
        if expiry is None or expiry < date.today():
            continue
        result.append(row)
    return result



def _get_exchange_instruments(client: Any, exchange: str) -> list[dict[str, Any]]:
    """Load/cache a broker instrument master for the requested derivatives exchange."""
    global _instruments_cache, _instruments_loaded_at
    if exchange == "NFO":
        return _get_instruments(client)
    now = datetime.now(timezone.utc)
    loaded_at = _exchange_instruments_loaded_at.get(exchange)
    cached = _exchange_instruments_cache.get(exchange)
    if cached and loaded_at and (now - loaded_at).total_seconds() < 12 * 60 * 60:
        return cached
    try:
        rows = client.instruments(exchange)
    except Exception as exc:
        raise HTTPException(502, f"Could not load Zerodha {exchange} instrument master: {exc}") from exc
    _exchange_instruments_cache[exchange] = rows
    _exchange_instruments_loaded_at[exchange] = now
    if exchange == "NFO":
        _instruments_cache = rows
        _instruments_loaded_at = now
    return rows


def _options_for_underlying(client: Any, underlying: str) -> tuple[str, list[dict[str, Any]]]:
    exchange = "BFO" if underlying == "SENSEX" else "NFO"
    rows = _get_exchange_instruments(client, exchange)
    result = []
    for row in rows:
        if row.get("name") != underlying or row.get("segment") != f"{exchange}-OPT":
            continue
        if row.get("instrument_type") not in ("CE", "PE") or not row.get("tradingsymbol") or row.get("strike") in (None, ""):
            continue
        expiry = _parse_date(row.get("expiry"))
        if expiry is None or expiry < date.today():
            continue
        result.append(row)
    return exchange, result

def _quote_batches(client: Any, keys: list[str]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    # Kite quote accepts at most 500 instruments per request; keep batches below that.
    for start in range(0, len(keys), 400):
        batch = keys[start : start + 400]
        try:
            quoted = client.quote(*batch)
            if isinstance(quoted, dict):
                result.update(quoted)
        except Exception as quote_error:
            # LTP is a useful fallback when full quote/depth is unavailable.
            try:
                ltp_result = client.ltp(*batch)
                if isinstance(ltp_result, dict):
                    for symbol, value in ltp_result.items():
                        result[symbol] = {**(result.get(symbol) or {}), **(value or {})}
            except Exception as ltp_error:
                raise HTTPException(
                    502,
                    f"Zerodha quote and LTP requests failed: {quote_error}; {ltp_error}",
                ) from ltp_error
        # A quote object may exist without a usable last_price. Supplement only
        # those symbols with LTP so existing depth and timestamps are preserved.
        missing = [
            symbol for symbol in batch
            if not isinstance(result.get(symbol), dict)
            or _safe_float(result[symbol].get("last_price")) is None
            or _safe_float(result[symbol].get("last_price")) <= 0
        ]
        if missing:
            try:
                ltp_result = client.ltp(*missing)
                if isinstance(ltp_result, dict):
                    for symbol, value in ltp_result.items():
                        if not isinstance(value, dict):
                            continue
                        existing = result.get(symbol) or {}
                        price = _safe_float(value.get("last_price"))
                        if price is not None and price > 0:
                            existing["last_price"] = price
                            existing.setdefault("instrument_token", value.get("instrument_token"))
                            result[symbol] = existing
            except Exception:
                # Preserve partial quote results; the API reports unavailable
                # prices as null rather than fabricating a value.
                pass
    return result


def _depth_price(quote: dict[str, Any], side: str) -> float | None:
    depth = quote.get("depth") or {}
    entries = depth.get(side) or []
    if not entries:
        return None
    try:
        value = float(entries[0].get("price", 0))
        return value if value > 0 else None
    except (TypeError, ValueError):
        return None


def _safe_float(value: Any) -> float | None:
    try:
        if value is None or value == "":
            return None
        return float(value)
    except (TypeError, ValueError):
        return None


@app.get("/health")
def health() -> dict[str, Any]:
    return {"status": "ok", "service": "trading-memory-kite-local", "version": "0.1.0"}


@app.get("/api/status", dependencies=[Depends(_require_local_token)])
def status() -> dict[str, Any]:
    return {
        "kite_connected": bool(_access_token),
        "instrument_master_loaded": bool(_instruments_cache),
        "redirect_url": REDIRECT_URL,
    }


@app.get("/api/kite/login")
def kite_login(request: Request) -> RedirectResponse:
    # The callback uses loopback; start the login in a browser on the Mac running this service.
    if request.client and request.client.host not in ("127.0.0.1", "::1", "localhost"):
        raise HTTPException(
            403,
            "For safety, start Zerodha login in a browser on the Mac: "
            "http://127.0.0.1:8765/api/kite/login",
        )
    if not API_KEY or not API_SECRET:
        raise HTTPException(503, "Set KITE_API_KEY and KITE_API_SECRET in backend/.env")
    return RedirectResponse(
        url=f"https://kite.zerodha.com/connect/login?v=3&{urlencode({'api_key': API_KEY})}",
        status_code=302,
    )


@app.get("/api/kite/callback", response_class=HTMLResponse)
def kite_callback(request: Request, request_token: str | None = None, status: str | None = None) -> HTMLResponse:
    global _access_token
    if request.client and request.client.host not in ("127.0.0.1", "::1", "localhost"):
        raise HTTPException(403, "Kite callback must reach the local Mac backend")
    if status and status != "success":
        return HTMLResponse(
            "<h2>Trading Memory: Zerodha login was not completed</h2><p>Close this tab and try again.</p>",
            status_code=400,
        )
    if not request_token:
        return HTMLResponse(
            "<h2>Trading Memory: missing request token</h2><p>Start login again from the Mac.</p>",
            status_code=400,
        )
    if not API_SECRET:
        return HTMLResponse("<h2>KITE_API_SECRET is not configured.</h2>", status_code=503)
    try:
        client = _kite_client()
        session = client.generate_session(request_token, api_secret=API_SECRET)
        _access_token = session["access_token"]
        client.set_access_token(_access_token)
        try:
            _persist_access_token(_access_token)
        except (OSError, subprocess.SubprocessError) as persistence_error:
            # Do not leak the token or command output; login still works for this process.
            print(f"WARNING: Kite token could not be persisted securely ({type(persistence_error).__name__}).")
    except Exception:
        # Do not return request tokens, secrets, access tokens or raw broker errors to the browser.
        return HTMLResponse(
            "<h2>Trading Memory: Zerodha authentication failed</h2>"
            "<p>Check the backend terminal, API credentials and registered redirect URL, then retry.</p>",
            status_code=401,
        )
    return HTMLResponse(
        "<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'>"
        "<title>Trading Memory connected</title></head><body style='font:16px system-ui;padding:2rem'>"
        "<h2>Trading Memory is connected to Zerodha</h2>"
        "<p>Your session is available to the local backend. On macOS, the token is saved in your login Keychain so ordinary backend restarts do not require another login.</p>"
        "<p>Kite access tokens still expire daily; a fresh Zerodha login is required after expiry or if Zerodha invalidates the session.</p></body></html>"
    )


@app.get("/api/nifty/expiries", dependencies=[Depends(_require_local_token)])
def nifty_expiries() -> dict[str, Any]:
    client = _connected_kite()
    options = _nifty_options(client)
    expiries = sorted(
        {expiry.isoformat() for row in options if (expiry := _parse_date(row.get("expiry"))) is not None}
    )
    return {
        "underlying": "NIFTY",
        "expiries": expiries,
        "instrument_master_loaded_at": _instruments_loaded_at.isoformat() if _instruments_loaded_at else None,
    }


@app.get("/api/expiries", dependencies=[Depends(_require_local_token)])
def expiries_for_underlying(underlying: str = Query(..., pattern="^(NIFTY|BANKNIFTY|SENSEX)$")) -> dict[str, Any]:
    """Return upcoming expiries from Zerodha's exchange instrument master.

    This is the exchange-listed source of truth, so holiday-shifted expiries are
    reflected in the dates rather than guessed from a weekday calendar.
    """
    client = _connected_kite()
    exchange, options = _options_for_underlying(client, underlying)
    expiries = sorted({expiry.isoformat() for row in options if (expiry := _parse_date(row.get("expiry"))) is not None})
    loaded_at = _instruments_loaded_at if exchange == "NFO" else _exchange_instruments_loaded_at.get(exchange)
    return {
        "underlying": underlying,
        "exchange": exchange,
        "expiries": expiries,
        "instrument_master_loaded_at": loaded_at.isoformat() if loaded_at else None,
    }


@app.post("/api/nifty/position-estimate", dependencies=[Depends(_require_local_token)])
async def nifty_position_estimate(request: Request) -> dict[str, Any]:
    """Read-only Kite basket-margin and virtual-contract-note estimate.
    Each leg may carry its own expiry for calendar/diagonal spreads.

    This endpoint never places orders. It asks Kite to calculate hypothetical
    margins and charges for a NIFTY option basket.
    """
    client = _connected_kite()
    try:
        payload = await request.json()
    except Exception as exc:
        raise HTTPException(400, "Request body must be JSON") from exc
    if not isinstance(payload, dict) or not isinstance(payload.get("legs"), list):
        raise HTTPException(422, "Provide a legs array")
    try:
        requested_expiry = date.fromisoformat(str(payload.get("expiry", "")))
    except ValueError as exc:
        raise HTTPException(422, "expiry must be YYYY-MM-DD") from exc
    if not payload["legs"] or len(payload["legs"]) > 20:
        raise HTTPException(422, "Provide between 1 and 20 option legs")

    instruments = _nifty_options(client)
    by_contract = {
        (_parse_date(row.get("expiry")), int(round(float(row.get("strike", 0)))), str(row.get("instrument_type"))): row
        for row in instruments
    }
    margin_orders: list[dict[str, Any]] = []
    charge_orders: list[dict[str, Any]] = []
    for index, leg in enumerate(payload["legs"]):
        if not isinstance(leg, dict):
            raise HTTPException(422, f"Leg {index + 1} must be an object")
        try:
            strike = int(leg["strike"])
            leg_expiry = date.fromisoformat(str(leg.get("expiry", requested_expiry.isoformat())))
            option_type = str(leg["option_type"]).upper()
            side = str(leg["side"]).upper()
            quantity = int(leg["quantity"])
            entry_price = float(leg["entry_price"])
            exit_price_raw = leg.get("exit_price")
            exit_price = None if exit_price_raw is None else float(exit_price_raw)
        except (KeyError, TypeError, ValueError) as exc:
            raise HTTPException(422, f"Leg {index + 1} has invalid fields") from exc
        if option_type not in ("CE", "PE") or side not in ("BUY", "SELL"):
            raise HTTPException(422, f"Leg {index + 1} has invalid option type or side")
        if quantity <= 0 or not math.isfinite(entry_price) or entry_price < 0:
            raise HTTPException(422, f"Leg {index + 1} has invalid quantity or entry price")
        if exit_price is not None and (not math.isfinite(exit_price) or exit_price < 0):
            raise HTTPException(422, f"Leg {index + 1} has invalid hypothetical exit price")
        instrument = by_contract.get((leg_expiry, strike, option_type))
        if instrument is None:
            raise HTTPException(404, f"Contract not found in current NIFTY instrument master: {leg_expiry.isoformat()} {strike} {option_type}")
        lot_size = int(instrument.get("lot_size") or 0)
        if lot_size > 0 and quantity % lot_size != 0:
            raise HTTPException(422, f"Quantity for {strike} {option_type} must be a multiple of lot size {lot_size}")
        symbol = str(instrument["tradingsymbol"])
        base_order = {
            "exchange": str(instrument.get("exchange") or "NFO"),
            "tradingsymbol": symbol,
            "variety": "regular",
            "product": "NRML",
            "order_type": "MARKET",
            "quantity": quantity,
            "price": 0,
            "trigger_price": 0,
        }
        margin_orders.append({**base_order, "transaction_type": side})
        if entry_price > 0:
            charge_orders.append({
                "order_id": f"tm-entry-{index}",
                "exchange": str(instrument.get("exchange") or "NFO"),
                "tradingsymbol": symbol,
                "transaction_type": side,
                "variety": "regular",
                "product": "NRML",
                "order_type": "MARKET",
                "quantity": quantity,
                "average_price": entry_price,
            })
        if exit_price is not None and exit_price > 0:
            charge_orders.append({
                "order_id": f"tm-exit-{index}",
                "exchange": str(instrument.get("exchange") or "NFO"),
                "tradingsymbol": symbol,
                "transaction_type": "SELL" if side == "BUY" else "BUY",
                "variety": "regular",
                "product": "NRML",
                "order_type": "MARKET",
                "quantity": quantity,
                "average_price": exit_price,
            })

    response: dict[str, Any] = {
        "underlying": "NIFTY",
        "expiry": requested_expiry.isoformat(),
        "source": "Kite Connect hypothetical calculation; no orders placed",
        "margin": None,
        "margin_error": None,
        "charges": None,
        "charges_error": None,
        "charges_scope": "entry and hypothetical exit" if any(leg.get("exit_price") is not None for leg in payload["legs"] if isinstance(leg, dict)) else "entry only; reference spot unavailable",
    }
    try:
        margin_data = client.basket_order_margins(margin_orders, consider_positions=False)
        if isinstance(margin_data, dict):
            response["margin"] = {
                "initial": (margin_data.get("initial") or {}).get("total"),
                "final": (margin_data.get("final") or {}).get("total"),
                "initial_breakdown": margin_data.get("initial"),
                "final_breakdown": margin_data.get("final"),
            }
        else:
            response["margin_error"] = "Kite returned an unexpected basket-margin response"
    except Exception as exc:
        response["margin_error"] = f"Kite basket-margin calculation failed: {exc}"
    if charge_orders:
        try:
            charge_data = client.get_virtual_contract_note(charge_orders)
            if not isinstance(charge_data, list) or not charge_data:
                response["charges_error"] = "Kite returned an unexpected or empty virtual contract-note response"
            elif any(not isinstance(row, dict) or not isinstance(row.get("charges"), dict) or row["charges"].get("total") is None for row in charge_data):
                response["charges_error"] = "Kite virtual contract-note response did not contain total charges for every order"
            else:
                total = sum(float(row["charges"]["total"]) for row in charge_data)
                if not math.isfinite(total) or total < 0:
                    response["charges_error"] = "Kite returned an invalid total for virtual contract-note charges"
                else:
                    response["charges"] = {"total": total, "orders": charge_data}
        except Exception as exc:
            response["charges_error"] = f"Kite charge calculation failed: {exc}"
    else:
        response["charges_error"] = "Entry premium is zero for every leg; Kite's virtual contract note requires a non-zero average price"
    return response


@app.post("/api/positions/live-quotes", dependencies=[Depends(_require_local_token)])
def live_position_quotes(payload: dict[str, Any]) -> dict[str, Any]:
    """Return current quotes for exact contracts held by open position states.

    Contract identity is resolved against the current broker instrument master;
    client-supplied trading symbols are never trusted.
    """
    requested = payload.get("contracts")
    if not isinstance(requested, list) or not requested:
        raise HTTPException(422, "contracts must be a non-empty list")
    if len(requested) > 400:
        raise HTTPException(422, "A maximum of 400 contracts can be requested at once")

    normalized: dict[str, dict[str, Any]] = {}
    exchanges: set[str] = set()
    for item in requested:
        if not isinstance(item, dict):
            continue
        underlying = str(item.get("underlying", "")).strip().upper()
        expiry = _parse_date(item.get("expiry"))
        try:
            strike = int(item.get("strike"))
        except (TypeError, ValueError):
            continue
        option_type = str(item.get("option_type", "")).strip().lower()
        if underlying not in ("NIFTY", "BANKNIFTY", "FINNIFTY", "MIDCPNIFTY", "SENSEX"):
            continue
        if expiry is None or option_type not in ("call", "put") or strike <= 0:
            continue
        key = f"{underlying}|{expiry.isoformat()}|{strike}|{option_type}"
        normalized[key] = {"underlying": underlying, "expiry": expiry, "strike": strike, "option_type": option_type}
        exchanges.add("BFO" if underlying == "SENSEX" else "NFO")
    if not normalized:
        raise HTTPException(422, "No valid option contracts were supplied")

    client = _connected_kite()
    instruments_by_key: dict[str, dict[str, Any]] = {}
    for exchange in exchanges:
        rows = _get_exchange_instruments(client, exchange)
        for row in rows:
            underlying = str(row.get("name", "")).upper()
            expiry = _parse_date(row.get("expiry"))
            try:
                strike = int(round(float(row.get("strike", 0))))
            except (TypeError, ValueError):
                continue
            instrument_type = str(row.get("instrument_type", "")).upper()
            option_type = "call" if instrument_type == "CE" else "put" if instrument_type == "PE" else None
            if expiry is None or option_type is None:
                continue
            key = f"{underlying}|{expiry.isoformat()}|{strike}|{option_type}"
            if key in normalized:
                instruments_by_key[key] = row

    symbols = [
        f"{'BFO' if item['underlying'] == 'SENSEX' else 'NFO'}:{row['tradingsymbol']}"
        for key, row in instruments_by_key.items()
        for item in [normalized[key]]
    ]
    quotes = _quote_batches(client, symbols) if symbols else {}
    results: dict[str, Any] = {}
    for key, row in instruments_by_key.items():
        item = normalized[key]
        symbol = f"{'BFO' if item['underlying'] == 'SENSEX' else 'NFO'}:{row['tradingsymbol']}"
        quote = quotes.get(symbol, {})
        timestamp = quote.get("timestamp")
        results[key] = {
            "last_price": _safe_float(quote.get("last_price")),
            "best_bid": _depth_price(quote, "buy"),
            "best_ask": _depth_price(quote, "sell"),
            "quote_timestamp": timestamp.isoformat() if isinstance(timestamp, datetime) else str(timestamp) if timestamp else None,
            "quote_available": bool(quote),
        }
    return {"fetched_at": datetime.now(timezone.utc).isoformat(), "quotes": results}


@app.get("/api/nifty/chain", dependencies=[Depends(_require_local_token)])
def nifty_option_chain(
    expiry: str = Query(..., description="Expiry date in YYYY-MM-DD format"),
    center: float | None = Query(default=None),
    wing_count: int = Query(default=12, ge=3, le=30),
) -> dict[str, Any]:
    client = _connected_kite()
    try:
        requested_expiry = date.fromisoformat(expiry)
    except ValueError as exc:
        raise HTTPException(422, "expiry must be YYYY-MM-DD") from exc

    options = [
        row for row in _nifty_options(client)
        if _parse_date(row.get("expiry")) == requested_expiry
    ]
    if not options:
        raise HTTPException(404, "No NIFTY option contracts found for that expiry")

    try:
        spot_response = client.quote("NSE:NIFTY 50")
    except Exception as exc:
        raise HTTPException(502, f"Could not retrieve NIFTY spot quote: {exc}") from exc
    spot_quote = spot_response.get("NSE:NIFTY 50", {})
    spot = _safe_float(spot_quote.get("last_price"))
    # India VIX is a scenario baseline only; it is not the implied volatility
    # of every individual option. Failure to retrieve VIX must not block the chain.
    vix_quote: dict[str, Any] = {}
    try:
        vix_response = client.quote("NSE:INDIA VIX")
        vix_quote = vix_response.get("NSE:INDIA VIX", {})
    except Exception:
        vix_quote = {}
    india_vix = _safe_float(vix_quote.get("last_price"))

    strikes = sorted({int(round(float(row["strike"]))) for row in options})
    center_value = center if center is not None else spot
    if center_value is None:
        visible_strikes = strikes
    else:
        nearest_index = min(range(len(strikes)), key=lambda i: abs(strikes[i] - center_value))
        low = max(0, nearest_index - wing_count)
        high = min(len(strikes), nearest_index + wing_count + 1)
        visible_strikes = strikes[low:high]
    visible_set = set(visible_strikes)
    selected = [row for row in options if int(round(float(row["strike"]))) in visible_set]

    symbols = [f"NFO:{row['tradingsymbol']}" for row in selected]
    quotes = _quote_batches(client, symbols)
    rows_by_strike: dict[int, dict[str, Any]] = {}
    for row in selected:
        strike = int(round(float(row["strike"])))
        option_type = row["instrument_type"]
        key = f"NFO:{row['tradingsymbol']}"
        quote = quotes.get(key, {})
        last_price = _safe_float(quote.get("last_price"))
        quote_timestamp = quote.get("timestamp")
        last_trade_time = quote.get("last_trade_time")
        instrument = {
            "tradingsymbol": row["tradingsymbol"],
            "instrument_token": int(row["instrument_token"]),
            "lot_size": int(row.get("lot_size") or 0),
            "last_price": last_price,
            "best_bid": _depth_price(quote, "buy"),
            "best_ask": _depth_price(quote, "sell"),
            "volume": int(quote.get("volume") or 0) if quote else None,
            "open_interest": int(quote.get("oi") or 0) if quote else None,
            "quote_timestamp": quote_timestamp.isoformat() if isinstance(quote_timestamp, datetime) else str(quote_timestamp) if quote_timestamp else None,
            "last_trade_time": last_trade_time.isoformat() if isinstance(last_trade_time, datetime) else str(last_trade_time) if last_trade_time else None,
            "quote_available": bool(quote),
        }
        row_payload = rows_by_strike.setdefault(strike, {"strike": strike, "call": None, "put": None})
        row_payload["call" if option_type == "CE" else "put"] = instrument

    return {
        "underlying": "NIFTY",
        "expiry": requested_expiry.isoformat(),
        "spot": spot,
        "spot_last_trade_time": spot_quote.get("last_trade_time").isoformat() if isinstance(spot_quote.get("last_trade_time"), datetime) else str(spot_quote.get("last_trade_time")) if spot_quote.get("last_trade_time") else None,
        "india_vix": india_vix,
        "india_vix_timestamp": vix_quote.get("last_trade_time").isoformat() if isinstance(vix_quote.get("last_trade_time"), datetime) else str(vix_quote.get("last_trade_time")) if vix_quote.get("last_trade_time") else None,
        "snapshot_fetched_at": datetime.now(timezone.utc).isoformat(),
        "quote_mode": "REST snapshot; refresh manually for a newer snapshot",
        "strikes": [rows_by_strike[strike] for strike in visible_strikes if strike in rows_by_strike],
    }