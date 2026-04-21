import numpy as np
from dataclasses import dataclass
from typing import Optional


@dataclass
class IndicatorResult:
    ema_fast: float
    ema_slow: float
    rsi: float
    macd: float
    macd_signal: float
    macd_hist: float
    bb_upper: float
    bb_middle: float
    bb_lower: float
    atr: float


def ema(prices: np.ndarray, period: int) -> np.ndarray:
    k = 2.0 / (period + 1)
    result = np.zeros(len(prices))
    result[0] = prices[0]
    for i in range(1, len(prices)):
        result[i] = prices[i] * k + result[i - 1] * (1 - k)
    return result


def rsi(closes: np.ndarray, period: int = 14) -> np.ndarray:
    deltas = np.diff(closes)
    gains = np.where(deltas > 0, deltas, 0.0)
    losses = np.where(deltas < 0, -deltas, 0.0)

    avg_gain = np.zeros(len(closes))
    avg_loss = np.zeros(len(closes))

    avg_gain[period] = gains[:period].mean()
    avg_loss[period] = losses[:period].mean()

    for i in range(period + 1, len(closes)):
        avg_gain[i] = (avg_gain[i - 1] * (period - 1) + gains[i - 1]) / period
        avg_loss[i] = (avg_loss[i - 1] * (period - 1) + losses[i - 1]) / period

    rs = np.where(avg_loss == 0, np.inf, avg_gain / avg_loss)
    result = 100 - (100 / (1 + rs))
    result[:period] = np.nan
    return result


def macd(closes: np.ndarray, fast: int = 12, slow: int = 26, signal: int = 9):
    ema_fast = ema(closes, fast)
    ema_slow = ema(closes, slow)
    macd_line = ema_fast - ema_slow
    signal_line = ema(macd_line, signal)
    histogram = macd_line - signal_line
    return macd_line, signal_line, histogram


def bollinger_bands(closes: np.ndarray, period: int = 20, std_dev: float = 2.0):
    middle = np.array([
        closes[max(0, i - period + 1):i + 1].mean()
        for i in range(len(closes))
    ])
    std = np.array([
        closes[max(0, i - period + 1):i + 1].std()
        for i in range(len(closes))
    ])
    upper = middle + std_dev * std
    lower = middle - std_dev * std
    return upper, middle, lower


def atr(highs: np.ndarray, lows: np.ndarray, closes: np.ndarray, period: int = 14) -> np.ndarray:
    tr = np.maximum(
        highs - lows,
        np.maximum(
            np.abs(highs - np.roll(closes, 1)),
            np.abs(lows - np.roll(closes, 1)),
        )
    )
    tr[0] = highs[0] - lows[0]
    result = np.zeros(len(closes))
    result[period - 1] = tr[:period].mean()
    for i in range(period, len(closes)):
        result[i] = (result[i - 1] * (period - 1) + tr[i]) / period
    return result


def compute_indicators(
    highs: np.ndarray,
    lows: np.ndarray,
    closes: np.ndarray,
    cfg: dict,
) -> Optional[IndicatorResult]:
    min_len = max(cfg["ema_slow"], cfg["macd_slow"] + cfg["macd_signal"], cfg["bb_period"], cfg["atr_period"]) + 5
    if len(closes) < min_len:
        return None

    ema_f = ema(closes, cfg["ema_fast"])
    ema_s = ema(closes, cfg["ema_slow"])
    rsi_v = rsi(closes, cfg["rsi_period"])
    macd_l, macd_sig, macd_h = macd(closes, cfg["macd_fast"], cfg["macd_slow"], cfg["macd_signal"])
    bb_u, bb_m, bb_l = bollinger_bands(closes, cfg["bb_period"], cfg["bb_std"])
    atr_v = atr(highs, lows, closes, cfg["atr_period"])

    return IndicatorResult(
        ema_fast=ema_f[-1],
        ema_slow=ema_s[-1],
        rsi=rsi_v[-1],
        macd=macd_l[-1],
        macd_signal=macd_sig[-1],
        macd_hist=macd_h[-1],
        bb_upper=bb_u[-1],
        bb_middle=bb_m[-1],
        bb_lower=bb_l[-1],
        atr=atr_v[-1],
    )
