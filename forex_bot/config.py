# Forex Trading Bot - Configuration

TRADING_CONFIG = {
    "account_balance": 10000.0,      # USD
    "risk_per_trade": 0.02,          # 2% per trade
    "max_open_trades": 5,
    "leverage": 100,
    "spread_pips": 1.5,
}

PAIRS = [
    "EUR/USD",
    "GBP/USD",
    "USD/JPY",
    "AUD/USD",
    "USD/CHF",
    "NZD/USD",
    "USD/CAD",
]

TIMEFRAMES = {
    "M1":  60,
    "M5":  300,
    "M15": 900,
    "H1":  3600,
    "H4":  14400,
    "D1":  86400,
}

STRATEGY_CONFIG = {
    "ema_fast": 9,
    "ema_slow": 21,
    "rsi_period": 14,
    "rsi_overbought": 70,
    "rsi_oversold": 30,
    "macd_fast": 12,
    "macd_slow": 26,
    "macd_signal": 9,
    "bb_period": 20,
    "bb_std": 2.0,
    "atr_period": 14,
    "sl_atr_multiplier": 1.5,
    "tp_atr_multiplier": 3.0,
}

API_CONFIG = {
    "provider": "alpha_vantage",   # alpha_vantage | oanda | demo
    "api_key": "YOUR_API_KEY",
    "base_url": "https://www.alphavantage.co/query",
    "timeout": 10,
}

LOG_CONFIG = {
    "level": "INFO",
    "file": "logs/forex_bot.log",
    "max_bytes": 5_000_000,
    "backup_count": 3,
}
