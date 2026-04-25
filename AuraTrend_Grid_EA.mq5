//+------------------------------------------------------------------+
//|  AURA TREND GRID EA  -  MT5                                      |
//|  Strategy: Session-Based Grid + EMA Trend Filter                 |
//+------------------------------------------------------------------+
#property copyright "Aura Trend EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//--- Input: Magic & Symbol
input group "=== GENERAL ==="
input int    MagicNumber   = 20240101;
input string EAComment     = "AuraTrend";

//--- Input: Lot
input group "=== LOT SETTINGS ==="
input double BaseLot       = 0.01;   // Lot แรก
input double LotMultiplier = 1.5;    // ทวีคูณ lot เมื่อ grid เพิ่ม
input int    MaxGridLevel  = 8;      // จำนวน grid สูงสุด

//--- Input: Grid
input group "=== GRID SETTINGS ==="
input int    GridStep      = 300;    // ระยะ grid (points)
input int    TakeProfit    = 400;    // TP รวม (points)
input int    StopLoss      = 0;      // SL (0 = ปิดด้วย grid แทน)

//--- Input: Trend Filter
input group "=== TREND FILTER (EMA) ==="
input bool   UseTrend      = true;
input int    EMA_Fast      = 21;
input int    EMA_Slow      = 89;
input ENUM_TIMEFRAMES TrendTF = PERIOD_H1;

//--- Input: Spread Filter
input group "=== SPREAD FILTER ==="
input int    MaxSpread     = 300;    // spread สูงสุด (points) — EURUSD~20, XAUUSD~300

//--- Input: Session 1
input group "=== SESSION 1 ==="
input bool   S1_Enable     = true;
input string S1_Start      = "00:00";
input string S1_End        = "11:00";

//--- Input: Session 2
input group "=== SESSION 2 ==="
input bool   S2_Enable     = true;
input string S2_Start      = "11:00";
input string S2_End        = "17:00";

//--- Input: Session 3
input group "=== SESSION 3 ==="
input bool   S3_Enable     = true;
input string S3_Start      = "17:00";
input string S3_End        = "21:00";

//--- Input: Risk Management
input group "=== RISK MANAGEMENT ==="
input double MaxDrawdownPct = 20.0;  // หยุดเมื่อ DD% เกิน
input bool   CloseOnDD      = true;  // ปิดทุก order เมื่อ DD เกิน

//--- Input: Dashboard
input group "=== DASHBOARD ==="
input bool   ShowDashboard  = true;
input color  DashBG         = C'10,18,40';
input color  BuyColor       = clrDodgerBlue;
input color  SellColor      = clrCrimson;
input color  TextColor      = clrWhite;

//--- Handles
int handleFast, handleSlow;

//--- State
bool     isRunning    = true;
bool     stopTrading  = false;
double   initBalance;
datetime lastBarTime  = 0;  // New Bar filter

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);

   handleFast = iMA(_Symbol, TrendTF, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   handleSlow = iMA(_Symbol, TrendTF, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(handleFast == INVALID_HANDLE || handleSlow == INVALID_HANDLE)
   {
      Print("ERROR: ไม่สามารถสร้าง EMA handle ได้");
      return INIT_FAILED;
   }

   initBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(ShowDashboard) CreateDashboard();

   Print("AURA TREND GRID EA เริ่มทำงาน | Magic=", MagicNumber);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleFast);
   IndicatorRelease(handleSlow);
   DeleteDashboard();
}

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(ShowDashboard) UpdateDashboard();

   if(!isRunning || stopTrading) return;

   //--- Drawdown Check
   if(CloseOnDD && CheckMaxDrawdown())
   {
      CloseAllPositions();
      stopTrading = true;
      Print("หยุดทำงาน: DD เกิน ", MaxDrawdownPct, "%");
      return;
   }

   //--- TP ตรวจทุก tick (ไม่ต้องรอ new bar)
   CheckGroupTP();

   //--- New Bar Filter: logic เปิด/grid ทำแค่ครั้งเดียวต่อแท่ง
   datetime curBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(curBarTime == lastBarTime) return;
   lastBarTime = curBarTime;

   //--- EMA Warmup: ต้องมี bars พอสำหรับ EMA Slow
   if(Bars(_Symbol, TrendTF) < EMA_Slow + 10)
   {
      Print("รอข้อมูล EMA: bars=", Bars(_Symbol, TrendTF), " ต้องการ=", EMA_Slow + 10);
      return;
   }

   //--- Session Check
   if(!IsInSession())
   {
      Print("นอก Session เวลา: ", TimeToString(TimeCurrent(), TIME_MINUTES));
      return;
   }

   //--- Spread Check
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpread)
   {
      Print("Spread สูงเกิน: ", spread, " > ", MaxSpread);
      return;
   }

   //--- Trend Direction
   int trend = GetTrendDirection();
   if(UseTrend && trend == 0)
   {
      Print("Trend Neutral: EMA Fast=Slow ยังไม่ชัดเจน");
      return;
   }

   //--- Grid Logic
   int buyCount  = CountPositions(POSITION_TYPE_BUY);
   int sellCount = CountPositions(POSITION_TYPE_SELL);
   int totalGrid = buyCount + sellCount;

   if(totalGrid == 0)
   {
      if(!UseTrend || trend == 1)  OpenBuy();
      if(!UseTrend || trend == -1) OpenSell();
   }
   else
   {
      ManageGrid(buyCount, sellCount);
   }
}

//+------------------------------------------------------------------+
//| Get Trend Direction: 1=BUY, -1=SELL, 0=Neutral                  |
//+------------------------------------------------------------------+
int GetTrendDirection()
{
   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);

   if(CopyBuffer(handleFast, 0, 0, 2, fast) < 2) return 0;
   if(CopyBuffer(handleSlow, 0, 0, 2, slow) < 2) return 0;

   if(fast[0] > slow[0]) return 1;
   if(fast[0] < slow[0]) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| Open Buy                                                         |
//+------------------------------------------------------------------+
void OpenBuy()
{
   int level  = CountPositions(POSITION_TYPE_BUY);
   if(level >= MaxGridLevel) return;

   double lot = GetGridLot(level);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double tp  = (StopLoss > 0) ? ask + TakeProfit * _Point : 0;
   double sl  = (StopLoss > 0) ? ask - StopLoss * _Point  : 0;

   if(trade.Buy(lot, _Symbol, ask, sl, tp, EAComment))
      Print("Grid BUY Level=", level+1, " Lot=", lot);
}

//+------------------------------------------------------------------+
//| Open Sell                                                        |
//+------------------------------------------------------------------+
void OpenSell()
{
   int level  = CountPositions(POSITION_TYPE_SELL);
   if(level >= MaxGridLevel) return;

   double lot = GetGridLot(level);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tp  = (StopLoss > 0) ? bid - TakeProfit * _Point : 0;
   double sl  = (StopLoss > 0) ? bid + StopLoss * _Point  : 0;

   if(trade.Sell(lot, _Symbol, bid, sl, tp, EAComment))
      Print("Grid SELL Level=", level+1, " Lot=", lot);
}

//+------------------------------------------------------------------+
//| Manage Grid: เปิดเพิ่มเมื่อราคาผ่าน grid step                   |
//+------------------------------------------------------------------+
void ManageGrid(int buyCount, int sellCount)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   //--- BUY grid
   if(buyCount > 0 && buyCount < MaxGridLevel)
   {
      double lastBuyPrice = GetLastPositionPrice(POSITION_TYPE_BUY);
      double ask          = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(lastBuyPrice - ask >= GridStep * point)
         OpenBuy();
   }

   //--- SELL grid
   if(sellCount > 0 && sellCount < MaxGridLevel)
   {
      double lastSellPrice = GetLastPositionPrice(POSITION_TYPE_SELL);
      double bid           = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(bid - lastSellPrice >= GridStep * point)
         OpenSell();
   }
}

//+------------------------------------------------------------------+
//| Check Group TP: ปิดทุก position เมื่อกำไรรวมถึง TP              |
//+------------------------------------------------------------------+
void CheckGroupTP()
{
   double totalProfit = GetTotalProfit();
   double point       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double totalLot    = GetTotalLot();

   if(totalLot <= 0) return;

   double tpAmount = TakeProfit * point / tickSize * tickValue * totalLot;

   if(totalProfit >= tpAmount)
   {
      CloseAllPositions();
      Print("Group TP ถึง: กำไร=", totalProfit);
   }
}

//+------------------------------------------------------------------+
//| Get Grid Lot (Martingale multiplier)                             |
//+------------------------------------------------------------------+
double GetGridLot(int level)
{
   double lot = BaseLot;
   for(int i = 0; i < level; i++)
      lot *= LotMultiplier;

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   lot = MathFloor(lot / stepLot) * stepLot;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Session Check                                                    |
//+------------------------------------------------------------------+
bool IsInSession()
{
   datetime now   = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   int curMin     = dt.hour * 60 + dt.min;

   if(S1_Enable && IsInTimeRange(curMin, S1_Start, S1_End)) return true;
   if(S2_Enable && IsInTimeRange(curMin, S2_Start, S2_End)) return true;
   if(S3_Enable && IsInTimeRange(curMin, S3_Start, S3_End)) return true;

   return false;
}

bool IsInTimeRange(int curMin, string startStr, string endStr)
{
   int startMin = TimeStrToMin(startStr);
   int endMin   = TimeStrToMin(endStr);

   if(startMin <= endMin)
      return (curMin >= startMin && curMin < endMin);
   else
      return (curMin >= startMin || curMin < endMin);
}

int TimeStrToMin(string t)
{
   string parts[];
   StringSplit(t, ':', parts);
   if(ArraySize(parts) < 2) return 0;
   return (int)StringToInteger(parts[0]) * 60 + (int)StringToInteger(parts[1]);
}

//+------------------------------------------------------------------+
//| Drawdown Check                                                   |
//+------------------------------------------------------------------+
bool CheckMaxDrawdown()
{
   if(initBalance <= 0) return false;
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct      = (initBalance - equity) / initBalance * 100.0;
   return (ddPct >= MaxDrawdownPct);
}

//+------------------------------------------------------------------+
//| Position Helpers                                                 |
//+------------------------------------------------------------------+
int CountPositions(ENUM_POSITION_TYPE type)
{
   int count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber && posInfo.PositionType() == type)
            count++;
   }
   return count;
}

double GetLastPositionPrice(ENUM_POSITION_TYPE type)
{
   double price    = 0;
   datetime latest = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber && posInfo.PositionType() == type)
            if((datetime)posInfo.Time() >= latest)
            {
               latest = (datetime)posInfo.Time();
               price  = posInfo.PriceOpen();
            }
   }
   return price;
}

double GetTotalProfit()
{
   double total = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            total += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
   return total;
}

double GetTotalLot()
{
   double total = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            total += posInfo.Volume();
   return total;
}

void CloseAllPositions()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            trade.PositionClose(posInfo.Ticket());
}

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void CreateDashboard()
{
   string name = "AuraDash_BG";
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  10);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  30);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,      320);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,      240);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,    DashBG);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clrDimGray);
   ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BACK,       false);
}

void CreateLabel(string name, string text, int x, int y, color clr, int fontSize=9)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  y);
   ObjectSetString(0, name, OBJPROP_TEXT,        text);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   fontSize);
   ObjectSetString(0, name, OBJPROP_FONT,        "Consolas");
   ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BACK,       false);
}

void UpdateDashboard()
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double profit   = GetTotalProfit();
   double dd       = (initBalance > 0) ? (initBalance - equity) / initBalance * 100.0 : 0;
   int    spread   = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int    buyPos   = CountPositions(POSITION_TYPE_BUY);
   int    sellPos  = CountPositions(POSITION_TYPE_SELL);
   double totalLot = GetTotalLot();
   int    trend    = GetTrendDirection();
   string trendStr = (trend == 1) ? "BUY  ▲" : (trend == -1) ? "SELL ▼" : "NEUTRAL";
   color  trendClr = (trend == 1) ? BuyColor : (trend == -1) ? SellColor : clrGray;
   string status   = stopTrading ? "STOPPED" : (IsInSession() ? "RUNNING" : "WAIT SESSION");
   color  statClr  = stopTrading ? clrRed : (IsInSession() ? clrLime : clrGold);

   int x = 18, y = 38;
   CreateLabel("AuraDash_Title",   "  AURA TREND GRID EA",              x,      y,      clrGold,      11);
   CreateLabel("AuraDash_Line1",   "─────────────────────────────",              x, y+22,  clrDimGray,   8);
   CreateLabel("AuraDash_Status",  "STATUS : " + status,                x,      y+38,   statClr);
   CreateLabel("AuraDash_Trend",   "TREND  : " + trendStr,              x,      y+54,   trendClr);
   CreateLabel("AuraDash_Spread",  StringFormat("SPREAD : %d pts",spread),        x, y+70,  (spread>MaxSpread?clrRed:clrWhite));
   CreateLabel("AuraDash_Line2",   "─────────────────────────────",              x, y+84,  clrDimGray,   8);
   CreateLabel("AuraDash_Balance", StringFormat("BALANCE: $%.2f", balance),       x, y+98,  TextColor);
   CreateLabel("AuraDash_Equity",  StringFormat("EQUITY : $%.2f", equity),        x, y+114, TextColor);
   CreateLabel("AuraDash_Profit",  StringFormat("FLOAT  : $%.2f", profit),        x, y+130, (profit>=0?clrLime:clrRed));
   CreateLabel("AuraDash_DD",      StringFormat("DD      : %.2f", dd) + "%",       x, y+146, (dd>MaxDrawdownPct*0.8?clrRed:clrWhite));
   CreateLabel("AuraDash_Line3",   "─────────────────────────────",              x, y+160, clrDimGray,   8);
   CreateLabel("AuraDash_Buy",     StringFormat("BUY  POS : %d pos", buyPos),     x, y+174, BuyColor);
   CreateLabel("AuraDash_Sell",    StringFormat("SELL POS : %d pos", sellPos),    x, y+190, SellColor);
   CreateLabel("AuraDash_Lot",     StringFormat("TOTAL LOT: %.2f", totalLot),     x, y+206, TextColor);

   ChartRedraw(0);
}

void DeleteDashboard()
{
   string names[] = {
      "AuraDash_BG","AuraDash_Title","AuraDash_Line1","AuraDash_Status",
      "AuraDash_Trend","AuraDash_Spread","AuraDash_Line2","AuraDash_Balance",
      "AuraDash_Equity","AuraDash_Profit","AuraDash_DD","AuraDash_Line3",
      "AuraDash_Buy","AuraDash_Sell","AuraDash_Lot"
   };
   for(int i = 0; i < ArraySize(names); i++)
      ObjectDelete(0, names[i]);
   ChartRedraw(0);
}
//+------------------------------------------------------------------+
