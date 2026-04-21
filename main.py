#!/usr/bin/env python3
"""
Forex Trading Bot — entry point.

Usage:
    python main.py              # demo mode (simulated prices)
    python main.py --interval 10
"""
import argparse
from forex_bot.bot import ForexBot


def main():
    parser = argparse.ArgumentParser(description="Forex Trading Bot")
    parser.add_argument("--interval", type=float, default=5.0,
                        help="Polling interval in seconds (default: 5)")
    args = parser.parse_args()
    ForexBot().run(interval_sec=args.interval)


if __name__ == "__main__":
    main()
