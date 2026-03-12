//+------------------------------------------------------------------+
//|                                              TrendMomentumEA.mq5 |
//|                          Trend + Momentum + Volatility EA        |
//|  Strategy: Fast/Slow MA trend filter, RSI momentum confirmation, |
//|            ATR-based adaptive stops and volatility filter.       |
//|  No martingale. Risk managed via fixed account-risk percent.     |
//+------------------------------------------------------------------+
#property copyright "TrendMomentumEA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input group "=== Moving Average Settings ==="
input int    InpFastMAPeriod  = 20;                    // Fast MA period
input int    InpSlowMAPeriod  = 50;                    // Slow MA period
input ENUM_MA_METHOD InpMAMethod = MODE_EMA;           // MA method
input ENUM_APPLIED_PRICE InpMAPrice = PRICE_CLOSE;     // MA applied price

input group "=== RSI Settings ==="
input int    InpRSIPeriod     = 14;                    // RSI period
input double InpRSIBullLevel  = 55.0;                  // RSI minimum for buy (momentum strength)
input double InpRSIBearLevel  = 45.0;                  // RSI maximum for sell (momentum weakness)
input double InpRSIOverbought = 80.0;                  // RSI overbought – avoid new buys above this
input double InpRSIOversold   = 20.0;                  // RSI oversold  – avoid new sells below this

input group "=== ATR Settings ==="
input int    InpATRPeriod     = 14;                    // ATR period
input double InpSLMultiplier  = 1.5;                   // Stop loss  = ATR × this multiplier
input double InpTPMultiplier  = 2.5;                   // Take profit = ATR × this multiplier
input double InpATRMinMult    = 0.5;                   // Min ATR vs its own SMA – low-volatility filter
input double InpATRMaxMult    = 3.0;                   // Max ATR vs its own SMA – high-volatility filter
input int    InpATRSMAPeriod  = 20;                    // Period of ATR SMA used for volatility filter

input group "=== Risk Management ==="
input double InpRiskPercent   = 1.0;                   // Risk per trade (% of account balance)
input double InpMaxSpreadPts  = 30.0;                  // Maximum allowed spread in points

input group "=== Trade Settings ==="
input ulong  InpMagicNumber   = 202501;                // EA magic number
input string InpComment       = "TrendMomentumEA";     // Order comment
input ENUM_ORDER_TYPE_FILLING InpFilling = ORDER_FILLING_FOK; // Order filling mode

//--- Indicator handles
int g_handleFastMA  = INVALID_HANDLE;
int g_handleSlowMA  = INVALID_HANDLE;
int g_handleRSI     = INVALID_HANDLE;
int g_handleATR     = INVALID_HANDLE;

//--- Trade object
CTrade g_trade;

//+------------------------------------------------------------------+
//| Expert initialisation                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- Validate inputs
   if(InpFastMAPeriod >= InpSlowMAPeriod)
     {
      Print("ERROR: Fast MA period must be less than Slow MA period.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRSIBullLevel <= 50.0 || InpRSIBearLevel >= 50.0)
     {
      Print("ERROR: RSIBullLevel must be > 50 and RSIBearLevel must be < 50.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 10.0)
     {
      Print("ERROR: RiskPercent must be between 0 and 10.");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- Create indicator handles
   g_handleFastMA = iMA(_Symbol, PERIOD_CURRENT, InpFastMAPeriod, 0, InpMAMethod, InpMAPrice);
   g_handleSlowMA = iMA(_Symbol, PERIOD_CURRENT, InpSlowMAPeriod, 0, InpMAMethod, InpMAPrice);
   g_handleRSI    = iRSI(_Symbol, PERIOD_CURRENT, InpRSIPeriod, InpMAPrice);
   g_handleATR    = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);

   if(g_handleFastMA == INVALID_HANDLE || g_handleSlowMA == INVALID_HANDLE ||
      g_handleRSI    == INVALID_HANDLE || g_handleATR    == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create indicator handles.");
      return INIT_FAILED;
     }

   //--- Configure trade object
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(10);
   g_trade.SetTypeFilling(InpFilling);

   Print("TrendMomentumEA initialised successfully on ", _Symbol, " ", EnumToString(PERIOD_CURRENT));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_handleFastMA != INVALID_HANDLE) IndicatorRelease(g_handleFastMA);
   if(g_handleSlowMA != INVALID_HANDLE) IndicatorRelease(g_handleSlowMA);
   if(g_handleRSI    != INVALID_HANDLE) IndicatorRelease(g_handleRSI);
   if(g_handleATR    != INVALID_HANDLE) IndicatorRelease(g_handleATR);
  }

//+------------------------------------------------------------------+
//| Expert tick handler                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- Only act on the open of a new bar (avoids re-entry on same candle)
   static datetime s_lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == s_lastBarTime)
      return;
   s_lastBarTime = currentBarTime;

   //--- Read indicator values (index 1 = last closed bar)
   double fastMA[2], slowMA[2], rsi[2], atr[2];

   if(CopyBuffer(g_handleFastMA, 0, 1, 2, fastMA) < 2) return;
   if(CopyBuffer(g_handleSlowMA, 0, 1, 2, slowMA) < 2) return;
   if(CopyBuffer(g_handleRSI,    0, 1, 2, rsi)    < 2) return;
   if(CopyBuffer(g_handleATR,    0, 1, 2, atr)    < 2) return;

   //--- ATR SMA for volatility normalisation – compute average of ATR values manually
   double atrHistory[];
   if(CopyBuffer(g_handleATR, 0, 1, InpATRSMAPeriod, atrHistory) < InpATRSMAPeriod) return;
   double currentATRSMA = 0.0;
   for(int k = 0; k < InpATRSMAPeriod; k++)
      currentATRSMA += atrHistory[k];
   currentATRSMA /= InpATRSMAPeriod;

   double currentFastMA = fastMA[1];  // most recent closed bar
   double currentSlowMA = slowMA[1];
   double currentRSI    = rsi[1];
   double currentATR    = atr[1];

   //--- Spread check
   double spreadPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPoints > InpMaxSpreadPts)
     {
      Print("Spread too wide (", spreadPoints, " pts), skipping bar.");
      return;
     }

   //--- Volatility filter: skip if ATR is too low or too high relative to its SMA
   if(currentATRSMA <= 0.0)
      return;
   double atrRatio = currentATR / currentATRSMA;
   if(atrRatio < InpATRMinMult || atrRatio > InpATRMaxMult)
     {
      // Volatility outside acceptable range – do not trade
      return;
     }

   //--- Determine trend direction from MA crossover
   bool bullTrend = (currentFastMA > currentSlowMA);
   bool bearTrend = (currentFastMA < currentSlowMA);

   //--- Momentum confirmation from RSI
   bool rsiBull = (currentRSI >= InpRSIBullLevel && currentRSI < InpRSIOverbought);
   bool rsiBear = (currentRSI <= InpRSIBearLevel && currentRSI > InpRSIOversold);

   //--- Check existing positions managed by this EA
   bool hasBuy  = HasOpenPosition(POSITION_TYPE_BUY);
   bool hasSell = HasOpenPosition(POSITION_TYPE_SELL);

   //--- BUY signal
   if(bullTrend && rsiBull && !hasBuy)
     {
      double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl    = ask - currentATR * InpSLMultiplier;
      double tp    = ask + currentATR * InpTPMultiplier;
      double lots  = CalcLotSize(ask - sl);

      if(lots > 0.0)
        {
         sl   = NormalizePrice(sl);
         tp   = NormalizePrice(tp);
         lots = NormalizeLots(lots);
         g_trade.Buy(lots, _Symbol, ask, sl, tp, InpComment);
        }
     }

   //--- SELL signal
   if(bearTrend && rsiBear && !hasSell)
     {
      double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl    = bid + currentATR * InpSLMultiplier;
      double tp    = bid - currentATR * InpTPMultiplier;
      double lots  = CalcLotSize(sl - bid);

      if(lots > 0.0)
        {
         sl   = NormalizePrice(sl);
         tp   = NormalizePrice(tp);
         lots = NormalizeLots(lots);
         g_trade.Sell(lots, _Symbol, bid, sl, tp, InpComment);
        }
     }
  }

//+------------------------------------------------------------------+
//| Check whether an open position of the given type exists for this |
//| EA's magic number on the current symbol.                         |
//+------------------------------------------------------------------+
bool HasOpenPosition(ENUM_POSITION_TYPE posType)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)    continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Calculate position size based on fixed account-risk percentage.  |
//| riskInPrice: distance from entry to stop loss in price units.    |
//+------------------------------------------------------------------+
double CalcLotSize(double riskInPrice)
  {
   if(riskInPrice <= 0.0)
      return 0.0;

   double balance      = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount   = balance * InpRiskPercent / 100.0;
   double tickSize     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double lotStep      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(tickSize <= 0.0 || tickValue <= 0.0 || lotStep <= 0.0)
      return 0.0;

   double riskInTicks  = riskInPrice / tickSize;
   double riskPerLot   = riskInTicks * tickValue;

   if(riskPerLot <= 0.0)
      return 0.0;

   double lots = riskAmount / riskPerLot;

   //--- Round down to the nearest lot step and clamp to broker limits
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));

   return lots;
  }

//+------------------------------------------------------------------+
//| Normalize a price to the symbol's tick size.                     |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
  {
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0)
      return NormalizeDouble(price, _Digits);
   return NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits);
  }

//+------------------------------------------------------------------+
//| Clamp and normalise lot size to broker constraints.              |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
  {
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   int    digits  = (int)MathMax(0, MathRound(-MathLog10(lotStep)));

   lots = NormalizeDouble(lots, digits);
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return lots;
  }
//+------------------------------------------------------------------+
