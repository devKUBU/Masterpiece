from dataclasses import dataclass, field
from typing import List
import time


@dataclass
class OpenTrade:
    pair: str
    direction: str          # BUY | SELL
    entry_price: float
    stop_loss: float
    take_profit: float
    lot_size: float
    open_time: float = field(default_factory=time.time)
    trade_id: str = ""


@dataclass
class RiskReport:
    total_exposure_usd: float
    used_margin_usd: float
    free_margin_usd: float
    drawdown_pct: float
    open_trades: int
    can_open_new: bool
    reason: str


class RiskManager:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.initial_balance = cfg["account_balance"]
        self.balance = cfg["account_balance"]
        self.equity = cfg["account_balance"]
        self.open_trades: List[OpenTrade] = []
        self.trade_history: List[dict] = []
        self.peak_equity = cfg["account_balance"]
        self.max_drawdown_pct = 0.0

    # ── balance management ────────────────────────────────────────────────────

    def update_equity(self, unrealised_pnl: float) -> None:
        self.equity = self.balance + unrealised_pnl
        if self.equity > self.peak_equity:
            self.peak_equity = self.equity
        dd = (self.peak_equity - self.equity) / self.peak_equity * 100
        self.max_drawdown_pct = max(self.max_drawdown_pct, dd)

    def close_trade(self, trade: OpenTrade, close_price: float) -> float:
        if trade.direction == "BUY":
            pnl = (close_price - trade.entry_price) * trade.lot_size * 100_000
        else:
            pnl = (trade.entry_price - close_price) * trade.lot_size * 100_000

        self.balance += pnl
        self.open_trades = [t for t in self.open_trades if t.trade_id != trade.trade_id]
        self.trade_history.append({
            "pair": trade.pair,
            "direction": trade.direction,
            "entry": trade.entry_price,
            "exit": close_price,
            "lot": trade.lot_size,
            "pnl": round(pnl, 2),
        })
        return pnl

    # ── checks ────────────────────────────────────────────────────────────────

    def can_open_trade(self, pair: str) -> RiskReport:
        used_margin = sum(t.lot_size * 100_000 / self.cfg["leverage"] for t in self.open_trades)
        exposure = sum(t.lot_size * 100_000 for t in self.open_trades)
        free_margin = self.equity - used_margin
        dd = (self.peak_equity - self.equity) / self.peak_equity * 100 if self.peak_equity else 0

        if len(self.open_trades) >= self.cfg["max_open_trades"]:
            return RiskReport(exposure, used_margin, free_margin, dd, len(self.open_trades), False, "Max open trades reached")

        same_pair = [t for t in self.open_trades if t.pair == pair]
        if same_pair:
            return RiskReport(exposure, used_margin, free_margin, dd, len(self.open_trades), False, f"Already have position on {pair}")

        if dd > 20:
            return RiskReport(exposure, used_margin, free_margin, dd, len(self.open_trades), False, f"Drawdown {dd:.1f}% > 20% limit")

        if free_margin < self.balance * 0.2:
            return RiskReport(exposure, used_margin, free_margin, dd, len(self.open_trades), False, "Insufficient free margin")

        return RiskReport(exposure, used_margin, free_margin, dd, len(self.open_trades), True, "OK")

    # ── statistics ────────────────────────────────────────────────────────────

    def stats(self) -> dict:
        if not self.trade_history:
            return {"trades": 0}
        wins = [t for t in self.trade_history if t["pnl"] > 0]
        losses = [t for t in self.trade_history if t["pnl"] <= 0]
        total_pnl = sum(t["pnl"] for t in self.trade_history)
        win_rate = len(wins) / len(self.trade_history) * 100
        avg_win = sum(t["pnl"] for t in wins) / len(wins) if wins else 0
        avg_loss = sum(t["pnl"] for t in losses) / len(losses) if losses else 0
        profit_factor = (sum(t["pnl"] for t in wins) / abs(sum(t["pnl"] for t in losses))) if losses else float("inf")

        return {
            "trades": len(self.trade_history),
            "wins": len(wins),
            "losses": len(losses),
            "win_rate_pct": round(win_rate, 1),
            "total_pnl_usd": round(total_pnl, 2),
            "avg_win_usd": round(avg_win, 2),
            "avg_loss_usd": round(avg_loss, 2),
            "profit_factor": round(profit_factor, 2),
            "max_drawdown_pct": round(self.max_drawdown_pct, 2),
            "current_balance": round(self.balance, 2),
            "return_pct": round((self.balance - self.initial_balance) / self.initial_balance * 100, 2),
        }
