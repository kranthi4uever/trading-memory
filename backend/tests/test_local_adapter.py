import asyncio
import unittest
from datetime import date, datetime, timezone

from fastapi import HTTPException

from app import main


class LocalAdapterHelperTests(unittest.TestCase):
    def test_as_iso_supports_date_and_datetime(self):
        self.assertEqual(main._as_iso(date(2026, 10, 10)), "2026-10-10")
        self.assertEqual(
            main._as_iso(datetime(2026, 10, 10, 9, 30, tzinfo=timezone.utc)),
            "2026-10-10",
        )

    def test_parse_date_rejects_invalid_value(self):
        self.assertEqual(main._parse_date("2026-10-10"), date(2026, 10, 10))
        self.assertIsNone(main._parse_date("not-a-date"))
        self.assertIsNone(main._parse_date(None))

    def test_safe_float_does_not_fabricate_missing_value(self):
        self.assertEqual(main._safe_float("123.45"), 123.45)
        self.assertIsNone(main._safe_float(None))
        self.assertIsNone(main._safe_float("unavailable"))

    def test_depth_price_uses_best_level_only_when_positive(self):
        quote = {"depth": {"buy": [{"price": 101.25}], "sell": [{"price": 101.5}]}}
        self.assertEqual(main._depth_price(quote, "buy"), 101.25)
        self.assertEqual(main._depth_price(quote, "sell"), 101.5)
        self.assertIsNone(main._depth_price({"depth": {"buy": []}}, "buy"))

    def test_invalid_ca_bundle_override_is_removed_without_disabling_tls(self):
        names = ("REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "SSL_CERT_FILE")
        previous = {name: __import__("os").environ.get(name) for name in names}
        try:
            import os
            for name in names:
                os.environ.pop(name, None)
            os.environ["REQUESTS_CA_BUNDLE"] = "/definitely/missing/cert.pem"
            main._normalize_ca_bundle_environment()
            repaired = os.environ.get("REQUESTS_CA_BUNDLE")
            self.assertTrue(repaired is None or __import__("pathlib").Path(repaired).is_file())
            self.assertNotEqual(os.environ.get("PYTHONHTTPSVERIFY"), "0")
        finally:
            import os
            for name, value in previous.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value

    def test_local_api_token_is_required(self):
        previous = main.LOCAL_API_TOKEN
        try:
            main.LOCAL_API_TOKEN = "test-token"
            main._require_local_token("test-token")
            with self.assertRaises(HTTPException) as error:
                main._require_local_token("wrong-token")
            self.assertEqual(error.exception.status_code, 401)
        finally:
            main.LOCAL_API_TOKEN = previous


    def test_position_estimate_uses_hypothetical_margin_and_charge_apis(self):
        class FakeRequest:
            async def json(self):
                return {
                    "expiry": "2026-10-13",
                    "legs": [
                        {"strike": 22500, "option_type": "CE", "side": "SELL", "quantity": 65, "entry_price": 100, "exit_price": 40},
                        {"strike": 22700, "option_type": "CE", "side": "BUY", "quantity": 65, "entry_price": 40, "exit_price": 15},
                    ],
                }

        class FakeKite:
            def __init__(self):
                self.margin_calls = 0
                self.charge_calls = 0

            def basket_order_margins(self, orders, consider_positions=True):
                self.margin_calls += 1
                self.assert_orders = orders
                return {"initial": {"total": 15000}, "final": {"total": 8500}}

            def get_virtual_contract_note(self, orders):
                self.charge_calls += 1
                self.charge_orders = orders
                return [{"charges": {"total": 20}}, {"charges": {"total": 22}}]

        fake = FakeKite()
        original_connected = main._connected_kite
        original_options = main._nifty_options
        try:
            main._connected_kite = lambda: fake
            main._nifty_options = lambda client: [
                {"expiry": date(2026, 10, 13), "strike": 22500, "instrument_type": "CE", "tradingsymbol": "NIFTYTEST22500CE", "lot_size": 65},
                {"expiry": date(2026, 10, 13), "strike": 22700, "instrument_type": "CE", "tradingsymbol": "NIFTYTEST22700CE", "lot_size": 65},
            ]
            result = asyncio.run(main.nifty_position_estimate(FakeRequest()))
            self.assertEqual(result["margin"]["initial"], 15000)
            self.assertEqual(result["margin"]["final"], 8500)
            self.assertEqual(result["charges"]["total"], 42)
            self.assertEqual(fake.margin_calls, 1)
            self.assertEqual(fake.charge_calls, 1)
            self.assertEqual(len(fake.assert_orders), 2)
            self.assertEqual(len(fake.charge_orders), 4)
            self.assertEqual(result["source"], "Kite Connect hypothetical calculation; no orders placed")
        finally:
            main._connected_kite = original_connected
            main._nifty_options = original_options

    def test_expiry_lookup_uses_exchange_instrument_master(self):
        class FakeKite:
            def instruments(self, exchange):
                self.exchange = exchange
                return [
                    {"name": "SENSEX", "segment": "BFO-OPT", "instrument_type": "CE", "tradingsymbol": "SENSEXTESTCE", "strike": 82000, "expiry": date(2026, 10, 15)},
                    {"name": "OTHER", "segment": "BFO-OPT", "instrument_type": "PE", "tradingsymbol": "OTHERTESTPE", "strike": 82000, "expiry": date(2026, 10, 15)},
                ]

        previous_cache = main._exchange_instruments_cache.copy()
        previous_loaded = main._exchange_instruments_loaded_at.copy()
        try:
            main._exchange_instruments_cache.pop("BFO", None)
            main._exchange_instruments_loaded_at.pop("BFO", None)
            exchange, options = main._options_for_underlying(FakeKite(), "SENSEX")
            self.assertEqual(exchange, "BFO")
            self.assertEqual(len(options), 1)
            self.assertEqual(options[0]["tradingsymbol"], "SENSEXTESTCE")
        finally:
            main._exchange_instruments_cache.clear()
            main._exchange_instruments_cache.update(previous_cache)
            main._exchange_instruments_loaded_at.clear()
            main._exchange_instruments_loaded_at.update(previous_loaded)

    def test_position_estimate_resolves_each_leg_expiry_for_calendar_spread(self):
        far_expiry = date(2026, 10, 20)

        class FakeRequest:
            async def json(self):
                return {
                    "expiry": "2026-10-13",
                    "legs": [
                        {"expiry": "2026-10-13", "strike": 22500, "option_type": "CE", "side": "SELL", "quantity": 65, "entry_price": 100, "exit_price": 40},
                        {"expiry": "2026-10-20", "strike": 22500, "option_type": "CE", "side": "BUY", "quantity": 65, "entry_price": 140, "exit_price": 120},
                    ],
                }

        class FakeKite:
            def basket_order_margins(self, orders, consider_positions=True):
                self.margin_orders = orders
                return {"initial": {"total": 18000}, "final": {"total": 12000}}

            def get_virtual_contract_note(self, orders):
                self.charge_orders = orders
                return [{"charges": {"total": 25}} for _ in orders]

        fake = FakeKite()
        original_connected = main._connected_kite
        original_options = main._nifty_options
        try:
            main._connected_kite = lambda: fake
            main._nifty_options = lambda client: [
                {"expiry": date(2026, 10, 13), "strike": 22500, "instrument_type": "CE", "tradingsymbol": "NIFTYNEAR22500CE", "lot_size": 65, "exchange": "NFO"},
                {"expiry": far_expiry, "strike": 22500, "instrument_type": "CE", "tradingsymbol": "NIFTYFAR22500CE", "lot_size": 65, "exchange": "NFO"},
            ]
            result = asyncio.run(main.nifty_position_estimate(FakeRequest()))
            self.assertEqual(result["margin"]["initial"], 18000)
            self.assertEqual([order["tradingsymbol"] for order in fake.margin_orders], ["NIFTYNEAR22500CE", "NIFTYFAR22500CE"])
            self.assertEqual(len(fake.charge_orders), 4)
        finally:
            main._connected_kite = original_connected
            main._nifty_options = original_options


if __name__ == "__main__":
    unittest.main()
