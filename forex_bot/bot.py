import time
import uuid
import logging
import logging.handlers

from .config import TRADING_CONFIG, STRATEGY_CONFIG, API_CONFIG, PAIRS, LOG_CONFIG
from .data_feed import create_feed
from .indicators import compute_indicators
from .strategy import generate_signal, Signal
from .risk_manager import RiskManager, OpenTrade
from .dashboard import render


def _setup_logging(cfg: dict) -> None:
    import os
    os.makedirs("logs", exist_ok=True)
    handler = logging.handlers.RotatingFileHandler(
        cfg["file"], maxBytes=cfg["max_bytes"], backupCount=cfg["backup_count"]
    )
    logging.basicConfig(
        level=getattr(logging, cfg["level"]),
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        handlers=[handler, logging.StreamHandler()],
    )


logger = logging.getLogger(__name__)


class ForexBot:
    def __init__(self):
        _setup_logging(LOG_CONFIG)
        self.rm = RiskManager(TRADING_CONFIG)
        self.feeds = {pair: create_feed(pair, API_CONFIG) for pair in PAIRS}
        self.last_signals = {pair: None for pair in PAIRS}
        self.running = False

    def _check_exits(self, ticker: dict) -> None:
        closed = []
        for trade in list(self.rm.open_trades):
            price = ticker.get(trade.pair, trade.entry_price)
            hit_sl = (trade.direction == "BUY" and price <= trade.stop_loss) or \
                     (trade.direction == "SELL" and price >= trade.stop_loss)
            hit_tp = (trade.direction == "BUY" and price >= trade.take_profit) or \
                     (trade.direction == "SELL" and price <= trade.take_profit)

            if hit_sl or hit_tp:
                pnl = self.rm.close_trade(trade, price)
                reason = "TP" if hit_tp else "SL"
                logger.info("[%s] %s %s @ %.5f  PnL=$%.2f", reason, trade.pair, trade.direction, price, pnl)
                closed.append(trade.pair)

    def _process_pair(self, pair: str) -> None:
        feed = self.feeds[pair]

        if hasattr(feed, "next_bar"):
            feed.next_bar()
        else:
            feed.fetch()

        highs, lows, closes = feed.get_arrays()
        if len(closes) < 30:
            return

        ind = compute_indicators(highs, lows, closes, STRATEGY_CONFIG)
        if ind is None:
            return

        current_price = closes[-1]
        signal = generate_signal(ind, current_price, self.rm.balance, STRATEGY_CONFIG, TRADING_CONFIG)
        self.last_signals[pair] = signal

        if signal.signal == Signal.HOLD:
            return

        report = self.rm.can_open_trade(pair)
        if not report.can_open:
            logger.debug("[%s] Skipped: %s", pair, report.reason)
            return

        trade = OpenTrade(
            pair=pair,
            direction=signal.signal.value,
            entry_price=signal.entry_price,
            stop_loss=signal.stop_loss,
            take_profit=signal.take_profit,
            lot_size=signal.lot_size,
            trade_id=str(uuid.uuid4())[:8],
        )
        self.rm.open_trades.append(trade)
        logger.info("[OPEN] %s %s @ %.5f  SL=%.5f TP=%.5f  Lots=%.2f",
                    pair, signal.signal.value, signal.entry_price,
                    signal.stop_loss, signal.take_profit, signal.lot_size)

    def run(self, interval_sec: float = 5.0) -> None:
        self.running = True
        logger.info("Forex Bot started — %d pairs, interval=%.0fs", len(PAIRS), interval_sec)
        try:
            while self.running:
                t0 = time.time()

                ticker = {}
                for pair, feed in self.feeds.items():
                    bars = feed.bars
                    ticker[pair] = bars[-1].close if bars else 0.0

                self._check_exits(ticker)

                for pair in PAIRS:
                    try:
                        self._process_pair(pair)
                    except Exception as exc:
                        logger.error("[%s] Error: %s", pair, exc)

                unrealised = 0.0
                for t in self.rm.open_trades:
                    cur = ticker.get(t.pair, t.entry_price)
                    if t.direction == "BUY":
                        unrealised += (cur - t.entry_price) * t.lot_size * 100_000
                    else:
                        unrealised += (t.entry_price - cur) * t.lot_size * 100_000
                self.rm.update_equity(unrealised)

                elapsed = (time.time() - t0) * 1000
                render(self.rm, ticker, self.last_signals, elapsed)

                sleep = max(0.0, interval_sec - (time.time() - t0))
                time.sleep(sleep)

        except KeyboardInterrupt:
            logger.info("Bot stopped by user.")
        finally:
            self.running = False
            stats = self.rm.stats()
            logger.info("Final stats: %s", stats)


if __name__ == "__main__":
    ForexBot().run()
