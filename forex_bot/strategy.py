from dataclasses import dataclass
from enum import Enum
from typing import Optional

from .indicators import IndicatorResult


class Signal(Enum):
    BUY = "BUY"
    SELL = "SELL"
    HOLD = "HOLD"


@dataclass
class TradeSignal:
    signal: Signal
    entry_price: float
    stop_loss: float
    take_profit: float
    lot_size: float
    reason: str


def _trend_signal(ind: IndicatorResult) -> Signal:
    """EMA crossover + MACD confirmation."""
    ema_bull = ind.ema_fast > ind.ema_slow
    macd_bull = ind.macd_hist > 0

    ema_bear = ind.ema_fast < ind.ema_slow
    macd_bear = ind.macd_hist < 0

    if ema_bull and macd_bull:
        return Signal.BUY
    if ema_bear and macd_bear:
        return Signal.SELL
    return Signal.HOLD


def _rsi_filter(ind: IndicatorResult, signal: Signal, cfg: dict) -> bool:
    """Block signals when RSI is in extreme zone against direction."""
    if signal == Signal.BUY and ind.rsi >= cfg["rsi_overbought"]:
        return False
    if signal == Signal.SELL and ind.rsi <= cfg["rsi_oversold"]:
        return False
    return True


def _bb_filter(ind: IndicatorResult, signal: Signal) -> bool:
    """Avoid entries deep inside the bands (ranging market)."""
    price = ind.bb_middle
    band_width = ind.bb_upper - ind.bb_lower
    if band_width == 0:
        return True
    position = (price - ind.bb_lower) / band_width

    if signal == Signal.BUY and position > 0.8:
        return False
    if signal == Signal.SELL and position < 0.2:
        return False
    return True


def _calculate_lot(balance: float, risk_pct: float, sl_pips: float, pip_value: float = 10.0) -> float:
    risk_amount = balance * risk_pct
    lot = risk_amount / (sl_pips * pip_value)
    return round(max(0.01, min(lot, 100.0)), 2)


def generate_signal(
    ind: IndicatorResult,
    current_price: float,
    account_balance: float,
    cfg: dict,
    trading_cfg: dict,
) -> TradeSignal:
    sl_distance = ind.atr * cfg["sl_atr_multiplier"]
    tp_distance = ind.atr * cfg["tp_atr_multiplier"]
    sl_pips = sl_distance / 0.0001  # assumes 4-decimal pair

    trend = _trend_signal(ind)

    if trend == Signal.HOLD:
        return TradeSignal(Signal.HOLD, current_price, 0.0, 0.0, 0.0, "No clear trend")

    if not _rsi_filter(ind, trend, cfg):
        return TradeSignal(Signal.HOLD, current_price, 0.0, 0.0, 0.0, f"RSI filter blocked {trend.value}")

    if not _bb_filter(ind, trend):
        return TradeSignal(Signal.HOLD, current_price, 0.0, 0.0, 0.0, f"Bollinger filter blocked {trend.value}")

    lot = _calculate_lot(account_balance, trading_cfg["risk_per_trade"], sl_pips)

    if trend == Signal.BUY:
        sl = current_price - sl_distance
        tp = current_price + tp_distance
        reason = (
            f"EMA{cfg['ema_fast']}>{cfg['ema_slow']}, "
            f"MACD hist>0, RSI={ind.rsi:.1f}"
        )
    else:
        sl = current_price + sl_distance
        tp = current_price - tp_distance
        reason = (
            f"EMA{cfg['ema_fast']}<{cfg['ema_slow']}, "
            f"MACD hist<0, RSI={ind.rsi:.1f}"
        )

    return TradeSignal(
        signal=trend,
        entry_price=current_price,
        stop_loss=round(sl, 5),
        take_profit=round(tp, 5),
        lot_size=lot,
        reason=reason,
    )
