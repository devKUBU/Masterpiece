import os
import time
from datetime import datetime
from typing import List

from .risk_manager import RiskManager, OpenTrade


def _clear():
    os.system("cls" if os.name == "nt" else "clear")


def _color(text: str, code: str) -> str:
    return f"\033[{code}m{text}\033[0m"


def green(t):  return _color(t, "32")
def red(t):    return _color(t, "31")
def yellow(t): return _color(t, "33")
def cyan(t):   return _color(t, "36")
def bold(t):   return _color(t, "1")


def _pnl_color(val: float) -> str:
    s = f"{val:+.2f}"
    return green(s) if val >= 0 else red(s)


def render(
    rm: RiskManager,
    ticker: dict,          # {pair: current_price}
    last_signals: dict,    # {pair: TradeSignal}
    loop_ms: float,
) -> None:
    _clear()
    now = datetime.now().strftime("%Y-%m-%d  %H:%M:%S")
    stats = rm.stats()

    print(bold(cyan("═" * 72)))
    print(bold(cyan(f"  FOREX TRADING BOT  │  {now}")))
    print(bold(cyan("═" * 72)))

    # Account summary
    bal = rm.balance
    eq = rm.equity
    dd = stats.get("max_drawdown_pct", 0)
    ret = stats.get("return_pct", 0)

    print(f"\n  Balance : {bold(f'${bal:,.2f}')}")
    print(f"  Equity  : {bold(f'${eq:,.2f}')}   Return: {_pnl_color(ret)}%   Max DD: {red(f'{dd:.1f}%')}")
    win_rate_str = green(f"{stats.get('win_rate_pct', 0):.1f}%")
    print(f"  Trades  : {stats.get('trades', 0)}  "
          f"Win rate: {win_rate_str}  "
          f"PF: {stats.get('profit_factor', 0):.2f}  "
          f"PnL: {_pnl_color(stats.get('total_pnl_usd', 0))}")

    # Open trades
    print(f"\n  {bold('OPEN POSITIONS')}  ({len(rm.open_trades)}/{rm.cfg['max_open_trades']})")
    if rm.open_trades:
        print(f"  {'Pair':<10} {'Dir':<5} {'Entry':>9} {'Current':>9} {'SL':>9} {'TP':>9} {'PnL':>10}")
        print("  " + "─" * 68)
        for t in rm.open_trades:
            cur = ticker.get(t.pair, t.entry_price)
            if t.direction == "BUY":
                pnl = (cur - t.entry_price) * t.lot_size * 100_000
            else:
                pnl = (t.entry_price - cur) * t.lot_size * 100_000
            dir_str = green("BUY") if t.direction == "BUY" else red("SELL")
            print(f"  {t.pair:<10} {dir_str:<14} {t.entry_price:>9.5f} {cur:>9.5f} "
                  f"{t.stop_loss:>9.5f} {t.take_profit:>9.5f} {_pnl_color(pnl):>20}")
    else:
        print(f"  {yellow('No open positions')}")

    # Last signals
    print(f"\n  {bold('LAST SIGNALS')}")
    print(f"  {'Pair':<10} {'Signal':<7} {'Price':>9} {'RSI':>7}  Reason")
    print("  " + "─" * 68)
    for pair, sig in last_signals.items():
        if sig is None:
            continue
        s = sig.signal.value
        sc = green(s) if s == "BUY" else (red(s) if s == "SELL" else yellow(s))
        price_str = f"{sig.entry_price:.5f}" if sig.entry_price else "—"
        print(f"  {pair:<10} {sc:<16} {price_str:>9}           {sig.reason[:35]}")

    # Footer
    print(f"\n  {bold('MARKET PRICES')}")
    cols = list(ticker.items())
    line = "  "
    for pair, price in cols:
        line += f"{pair}: {price:.5f}   "
    print(line)

    print(f"\n  Loop: {loop_ms:.0f}ms" + "  " + "─" * 50)
