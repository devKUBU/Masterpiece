import time
import random
import logging
import urllib.request
import json
from typing import Optional
import numpy as np

logger = logging.getLogger(__name__)


class PriceBar:
    __slots__ = ("timestamp", "open", "high", "low", "close", "volume")

    def __init__(self, timestamp: float, open_: float, high: float, low: float, close: float, volume: float = 0):
        self.timestamp = timestamp
        self.open = open_
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume


class DemoFeed:
    """Simulates live price data with realistic OHLC generation."""

    def __init__(self, pair: str, base_price: float, volatility: float = 0.0005):
        self.pair = pair
        self.price = base_price
        self.volatility = volatility
        self.bars: list[PriceBar] = []
        self._seed_history(200)

    def _seed_history(self, count: int) -> None:
        t = time.time() - count * 60
        for _ in range(count):
            change = random.gauss(0, self.volatility)
            open_ = self.price
            self.price = max(0.0001, self.price * (1 + change))
            high = max(open_, self.price) * (1 + abs(random.gauss(0, self.volatility / 2)))
            low = min(open_, self.price) * (1 - abs(random.gauss(0, self.volatility / 2)))
            self.bars.append(PriceBar(t, open_, high, low, self.price, random.randint(100, 5000)))
            t += 60

    def next_bar(self) -> PriceBar:
        change = random.gauss(0, self.volatility)
        open_ = self.price
        self.price = max(0.0001, self.price * (1 + change))
        high = max(open_, self.price) * (1 + abs(random.gauss(0, self.volatility / 2)))
        low = min(open_, self.price) * (1 - abs(random.gauss(0, self.volatility / 2)))
        bar = PriceBar(time.time(), open_, high, low, self.price, random.randint(100, 5000))
        self.bars.append(bar)
        if len(self.bars) > 500:
            self.bars.pop(0)
        return bar

    def get_arrays(self):
        highs = np.array([b.high for b in self.bars])
        lows = np.array([b.low for b in self.bars])
        closes = np.array([b.close for b in self.bars])
        return highs, lows, closes


class AlphaVantageFeed:
    """Live feed using Alpha Vantage FX Intraday API."""

    BASE_URL = "https://www.alphavantage.co/query"

    def __init__(self, api_key: str, pair: str, interval: str = "1min"):
        self.api_key = api_key
        clean = pair.replace("/", "")
        self.from_sym, self.to_sym = clean[:3], clean[3:]
        self.interval = interval
        self.bars: list[PriceBar] = []

    def fetch(self) -> bool:
        url = (
            f"{self.BASE_URL}?function=FX_INTRADAY"
            f"&from_symbol={self.from_sym}&to_symbol={self.to_sym}"
            f"&interval={self.interval}&outputsize=compact&apikey={self.api_key}"
        )
        try:
            with urllib.request.urlopen(url, timeout=10) as resp:
                data = json.loads(resp.read())
            key = f"Time Series FX ({self.interval})"
            if key not in data:
                logger.warning("Alpha Vantage response: %s", data)
                return False
            self.bars = []
            for ts, ohlc in sorted(data[key].items()):
                self.bars.append(PriceBar(
                    timestamp=time.mktime(time.strptime(ts, "%Y-%m-%d %H:%M:%S")),
                    open_=float(ohlc["1. open"]),
                    high=float(ohlc["2. high"]),
                    low=float(ohlc["3. low"]),
                    close=float(ohlc["4. close"]),
                ))
            return True
        except Exception as exc:
            logger.error("Feed fetch error: %s", exc)
            return False

    def get_arrays(self):
        highs = np.array([b.high for b in self.bars])
        lows = np.array([b.low for b in self.bars])
        closes = np.array([b.close for b in self.bars])
        return highs, lows, closes


DEMO_PRICES = {
    "EUR/USD": 1.0850,
    "GBP/USD": 1.2650,
    "USD/JPY": 154.50,
    "AUD/USD": 0.6450,
    "USD/CHF": 0.8950,
    "NZD/USD": 0.5980,
    "USD/CAD": 1.3650,
}


def create_feed(pair: str, api_cfg: dict):
    if api_cfg["provider"] == "alpha_vantage" and api_cfg["api_key"] != "YOUR_API_KEY":
        return AlphaVantageFeed(api_cfg["api_key"], pair)
    base = DEMO_PRICES.get(pair, 1.0)
    return DemoFeed(pair, base)
