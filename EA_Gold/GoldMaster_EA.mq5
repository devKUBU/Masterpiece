//+------------------------------------------------------------------+
//|  GoldMaster EA  –  XAUUSD Strategy                              |
//|  Strategy  : EMA Trend + RSI + ATR-based SL/TP                  |
//|  Timeframe : H1 (recommended)                                    |
//|  Symbol    : XAUUSD                                              |
//+------------------------------------------------------------------+
#property copyright "GoldMaster EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//── Input Parameters ─────────────────────────────────────────────────────────

input group "=== Trading Setup ==="
input double   InpLotSize        = 0.10;    // Fixed lot size (0 = auto)
input double   InpRiskPercent    = 1.5;     // Risk % per trade (auto mode)
input int      InpMagicNumber    = 202401;  // Magic number
input int      InpMaxTrades      = 3;       // Max concurrent trades

input group "=== EMA Settings ==="
input int      InpEmaFast        = 9;       // Fast EMA period
input int      InpEmaSlow        = 21;      // Slow EMA period
input int      InpEmaTrend       = 50;      // Trend filter EMA period

input group "=== RSI Settings ==="
input int      InpRsiPeriod      = 14;      // RSI period
input double   InpRsiOB          = 65.0;    // RSI overbought
input double   InpRsiOS          = 35.0;    // RSI oversold

input group "=== ATR & SL/TP ==="
input int      InpAtrPeriod      = 14;      // ATR period
input double   InpSlMultiplier   = 1.8;     // SL = ATR × multiplier
input double   InpTpMultiplier   = 3.0;     // TP = ATR × multiplier
input bool     InpUseBreakEven   = true;    // Move SL to break-even at 1R
input double   InpTrailStart     = 1.5;     // Trail start (× ATR from entry)
input double   InpTrailStep      = 0.5;     // Trail step (× ATR)

input group "=== Session Filter (Server Time) ==="
input bool     InpUseSession     = true;    // Enable session filter
input int      InpSessionStart   = 8;       // London open hour (8)
input int      InpSessionEnd     = 20;      // NY close hour (20)

input group "=== Gold Spread Filter ==="
input int      InpMaxSpreadPts   = 30;      // Max allowed spread (points)

//── Global Variables ──────────────────────────────────────────────────────────

CTrade         trade;
CPositionInfo  pos;

int handleEmaFast, handleEmaSlow, handleEmaTrend;
int handleRsi, handleAtr;

//── Init / Deinit ─────────────────────────────────────────────────────────────

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(30);

   handleEmaFast  = iMA(_Symbol, PERIOD_CURRENT, InpEmaFast,  0, MODE_EMA, PRICE_CLOSE);
   handleEmaSlow  = iMA(_Symbol, PERIOD_CURRENT, InpEmaSlow,  0, MODE_EMA, PRICE_CLOSE);
   handleEmaTrend = iMA(_Symbol, PERIOD_CURRENT, InpEmaTrend, 0, MODE_EMA, PRICE_CLOSE);
   handleRsi      = iRSI(_Symbol, PERIOD_CURRENT, InpRsiPeriod, PRICE_CLOSE);
   handleAtr      = iATR(_Symbol, PERIOD_CURRENT, InpAtrPeriod);

   if(handleEmaFast == INVALID_HANDLE || handleEmaSlow == INVALID_HANDLE ||
      handleEmaTrend == INVALID_HANDLE || handleRsi == INVALID_HANDLE || handleAtr == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles!");
      return INIT_FAILED;
   }

   Print("GoldMaster EA initialized on ", _Symbol, " / ", EnumToString(Period()));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(handleEmaFast);
   IndicatorRelease(handleEmaSlow);
   IndicatorRelease(handleEmaTrend);
   IndicatorRelease(handleRsi);
   IndicatorRelease(handleAtr);
}

//── Main Tick ─────────────────────────────────────────────────────────────────

void OnTick()
{
   // Only act on new bar
   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   bool newBar = (currentBar != lastBar);
   if(newBar) lastBar = currentBar;

   // Always manage open trades on every tick
   ManageOpenTrades();

   if(!newBar) return;

   // Spread filter
   if(SpreadPoints() > InpMaxSpreadPts) return;

   // Session filter
   if(InpUseSession && !IsSessionActive()) return;

   // Count own trades
   if(CountMyTrades() >= InpMaxTrades) return;

   // Read indicator values
   double emaFast[2], emaSlow[2], emaTrend[2], rsiVal[2], atrVal[2];
   if(!CopyValues(emaFast, emaSlow, emaTrend, rsiVal, atrVal)) return;

   double atr  = atrVal[1];
   double fast  = emaFast[1],  fastPrev  = emaFast[0];
   double slow  = emaSlow[1],  slowPrev  = emaSlow[0];
   double trend = emaTrend[1];
   double rsi   = rsiVal[1];
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ── Signal logic ─────────────────────────────────────────────
   bool bullTrend  = price > trend;
   bool bearTrend  = price < trend;
   bool emaCross   = (fastPrev < slowPrev) && (fast > slow);  // golden cross
   bool emaDeath   = (fastPrev > slowPrev) && (fast < slow);  // death cross
   bool rsiBull    = rsi > 50 && rsi < InpRsiOB;
   bool rsiBear    = rsi < 50 && rsi > InpRsiOS;

   if(bullTrend && emaCross && rsiBull && !HasPosition(POSITION_TYPE_BUY))
      OpenTrade(ORDER_TYPE_BUY, atr);

   else if(bearTrend && emaDeath && rsiBear && !HasPosition(POSITION_TYPE_SELL))
      OpenTrade(ORDER_TYPE_SELL, atr);
}

//── Trade Execution ───────────────────────────────────────────────────────────

void OpenTrade(ENUM_ORDER_TYPE type, double atr)
{
   double sl_dist = atr * InpSlMultiplier;
   double tp_dist = atr * InpTpMultiplier;
   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double entry, sl, tp;
   if(type == ORDER_TYPE_BUY)
   {
      entry = ask;
      sl    = NormalizeDouble(entry - sl_dist, digits);
      tp    = NormalizeDouble(entry + tp_dist, digits);
   }
   else
   {
      entry = bid;
      sl    = NormalizeDouble(entry + sl_dist, digits);
      tp    = NormalizeDouble(entry - tp_dist, digits);
   }

   double lots = (InpLotSize > 0) ? InpLotSize : CalcLots(sl_dist);
   lots = NormalizeLots(lots);

   string comment = StringFormat("GoldMaster|%s|ATR=%.2f", EnumToString(type), atr);
   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lots, _Symbol, entry, sl, tp, comment)
             : trade.Sell(lots, _Symbol, entry, sl, tp, comment);

   if(ok)
      PrintFormat("[OPEN] %s  Entry=%.2f  SL=%.2f  TP=%.2f  Lots=%.2f",
                  EnumToString(type), entry, sl, tp, lots);
   else
      PrintFormat("[ERROR] OrderSend failed: %d", GetLastError());
}

//── Trade Management ──────────────────────────────────────────────────────────

void ManageOpenTrades()
{
   double atrBuf[2];
   if(CopyBuffer(handleAtr, 0, 0, 2, atrBuf) < 2) return;
   double atr = atrBuf[1];

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Magic() != InpMagicNumber || pos.Symbol() != _Symbol) continue;

      double entry    = pos.PriceOpen();
      double curSl    = pos.StopLoss();
      double curTp    = pos.TakeProfit();
      double slDist   = atr * InpSlMultiplier;
      double price    = SymbolInfoDouble(_Symbol, pos.PositionType() == POSITION_TYPE_BUY ? SYMBOL_BID : SYMBOL_ASK);
      int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

      if(pos.PositionType() == POSITION_TYPE_BUY)
      {
         double breakEvenLevel = entry + slDist;           // 1R in profit
         double trailTrigger   = entry + atr * InpTrailStart;
         double newSl          = price - atr * InpTrailStep;
         newSl                 = NormalizeDouble(newSl, digits);

         if(InpUseBreakEven && price >= breakEvenLevel && curSl < entry)
            ModifySl(pos.Ticket(), entry, curTp);          // move to break-even
         else if(price >= trailTrigger && newSl > curSl)
            ModifySl(pos.Ticket(), newSl, curTp);          // trail
      }
      else  // SELL
      {
         double breakEvenLevel = entry - slDist;
         double trailTrigger   = entry - atr * InpTrailStart;
         double newSl          = price + atr * InpTrailStep;
         newSl                 = NormalizeDouble(newSl, digits);

         if(InpUseBreakEven && price <= breakEvenLevel && curSl > entry)
            ModifySl(pos.Ticket(), entry, curTp);
         else if(price <= trailTrigger && (newSl < curSl || curSl == 0))
            ModifySl(pos.Ticket(), newSl, curTp);
      }
   }
}

void ModifySl(ulong ticket, double newSl, double tp)
{
   trade.PositionModify(ticket, newSl, tp);
}

//── Helpers ───────────────────────────────────────────────────────────────────

bool CopyValues(double &emaFast[], double &emaSlow[], double &emaTrend[],
                double &rsiVal[], double &atrVal[])
{
   if(CopyBuffer(handleEmaFast,  0, 0, 2, emaFast)  < 2) return false;
   if(CopyBuffer(handleEmaSlow,  0, 0, 2, emaSlow)  < 2) return false;
   if(CopyBuffer(handleEmaTrend, 0, 0, 2, emaTrend) < 2) return false;
   if(CopyBuffer(handleRsi,      0, 0, 2, rsiVal)   < 2) return false;
   if(CopyBuffer(handleAtr,      0, 0, 2, atrVal)   < 2) return false;
   ArraySetAsSeries(emaFast,  true);
   ArraySetAsSeries(emaSlow,  true);
   ArraySetAsSeries(emaTrend, true);
   ArraySetAsSeries(rsiVal,   true);
   ArraySetAsSeries(atrVal,   true);
   return true;
}

int CountMyTrades()
{
   int cnt = 0;
   for(int i = 0; i < PositionsTotal(); i++)
      if(pos.SelectByIndex(i) && pos.Magic() == InpMagicNumber && pos.Symbol() == _Symbol)
         cnt++;
   return cnt;
}

bool HasPosition(ENUM_POSITION_TYPE type)
{
   for(int i = 0; i < PositionsTotal(); i++)
      if(pos.SelectByIndex(i) && pos.Magic() == InpMagicNumber && pos.Symbol() == _Symbol
         && pos.PositionType() == type)
         return true;
   return false;
}

bool IsSessionActive()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.hour >= InpSessionStart && dt.hour < InpSessionEnd);
}

int SpreadPoints()
{
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
}

double CalcLots(double slDist)
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskUsd   = balance * InpRiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize == 0 || tickValue == 0) return 0.01;
   double slTicks   = slDist / tickSize;
   double lots      = riskUsd / (slTicks * tickValue);
   return lots;
}

double NormalizeLots(double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathRound(lots / stepLot) * stepLot;
   return MathMax(minLot, MathMin(maxLot, lots));
}
