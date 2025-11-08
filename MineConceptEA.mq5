#property copyright ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

input double InpBandwidth       = 0.15;  // Bandwidth
input double InpMultiplier      = 0.1;   // Multiplier
input double InpInitialBalance  = 25000; // Initial Balance (unused placeholder to mirror Pine inputs)
input double InpRiskPercent     = 2.0;   // Risk percent per trade (unused placeholder to mirror Pine inputs)
input double InpRRRatio         = 5.0;   // Risk reward ratio (unused placeholder to mirror Pine inputs)
input double InpTrailingPercent = 5.0;   // Trailing stop percent

const int WINDOW_SIZE    = 500;
const int LOOKBACK_LEN   = 499;
const int REQUIRED_BARS  = WINDOW_SIZE + LOOKBACK_LEN;

CTrade trade;

double g_weights[WINDOW_SIZE];
double g_denominator = 0.0;
bool   g_weights_ready = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpBandwidth <= 0.0)
      return(INIT_PARAMETERS_INCORRECT);

   g_denominator = 0.0;
   for(int i = 0; i < WINDOW_SIZE; ++i)
   {
      double weight = MathExp(-(MathPow((double)i, 2.0) / (InpBandwidth * InpBandwidth * 2.0)));
      g_weights[i]  = weight;
      g_denominator += weight;
   }

   if(g_denominator <= 0.0)
      return(INIT_FAILED);

   g_weights_ready = true;
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   g_weights_ready = false;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_weights_ready)
      return;

   ManageTrailingStops();

   if(!IsNewBar())
      return;

   ProcessSignals();
}

//+------------------------------------------------------------------+
//| Detect new bar                                                   |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime last_bar_time = 0;
   datetime current_bar_time = iTime(_Symbol, _Period, 0);

   if(last_bar_time == current_bar_time)
      return(false);

   last_bar_time = current_bar_time;
   return(true);
}

//+------------------------------------------------------------------+
//| Compute weighted average for specified shift                     |
//+------------------------------------------------------------------+
double ComputeSmoothedValue(const double &closes[], const int shift)
{
   double sum   = 0.0;
   double denom = 0.0;
   int total = ArraySize(closes);
   for(int i = 0; i < WINDOW_SIZE; ++i)
   {
      int index = shift + i;
      if(index >= total)
         break;
      sum   += closes[index] * g_weights[i];
      denom += g_weights[i];
   }
   double divider = (denom > 0.0) ? denom : g_denominator;
   return(sum / divider);
}

//+------------------------------------------------------------------+
//| Calculate trading signals and execute orders                     |
//+------------------------------------------------------------------+
void ProcessSignals()
{
   if(iBars(_Symbol, _Period) <= REQUIRED_BARS)
      return;

   double close_prices[];
   ArraySetAsSeries(close_prices, true);
   if(CopyClose(_Symbol, _Period, 0, REQUIRED_BARS, close_prices) != REQUIRED_BARS)
      return;

   double smoothed_values[];
   ArrayResize(smoothed_values, LOOKBACK_LEN + 1);

   for(int shift = 0; shift <= LOOKBACK_LEN; ++shift)
      smoothed_values[shift] = ComputeSmoothedValue(close_prices, shift);

   double mae_current = 0.0;
   for(int i = 0; i < LOOKBACK_LEN; ++i)
      mae_current += MathAbs(close_prices[i] - smoothed_values[i]);
   mae_current = (mae_current / LOOKBACK_LEN) * InpMultiplier;

   double mae_previous = 0.0;
   for(int i = 1; i <= LOOKBACK_LEN; ++i)
      mae_previous += MathAbs(close_prices[i] - smoothed_values[i]);
   mae_previous = (mae_previous / LOOKBACK_LEN) * InpMultiplier;

   double current_close = close_prices[0];
   double previous_close = close_prices[1];

   double lower_current = smoothed_values[0] - mae_current;
   double upper_current = smoothed_values[0] + mae_current;
   double lower_previous = smoothed_values[1] - mae_previous;
   double upper_previous = smoothed_values[1] + mae_previous;

   bool buy_signal  = (previous_close <= lower_previous && current_close > lower_current);
   bool sell_signal = (previous_close >= upper_previous && current_close < upper_current);

   double volume = CalculateVolume(current_close);
   if(volume <= 0.0)
      return;

   if(buy_signal)
      OpenPosition(POSITION_TYPE_BUY, volume);

   if(sell_signal)
      OpenPosition(POSITION_TYPE_SELL, volume);
}

//+------------------------------------------------------------------+
//| Calculate trade volume based on account balance                  |
//+------------------------------------------------------------------+
double CalculateVolume(const double price)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double desired_value = balance * 0.50;
   double contract_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(contract_size <= 0.0 || price <= 0.0)
      return(0.0);

   double volume = desired_value / (price * contract_size);

   double volume_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(volume_step > 0.0)
      volume = MathFloor(volume / volume_step + 0.5) * volume_step;

   double min_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(min_volume > 0.0 && volume < min_volume)
      volume = min_volume;
   if(max_volume > 0.0 && volume > max_volume)
      volume = max_volume;

   return(volume);
}

//+------------------------------------------------------------------+
//| Open position with pyramiding up to 10 positions per direction   |
//+------------------------------------------------------------------+
void OpenPosition(const int type, const double volume)
{
   if(volume <= 0.0)
      return;

   int existing = CountPositions(type);
   if(existing >= 10)
      return;

   if(type == POSITION_TYPE_BUY)
      trade.Buy(volume, _Symbol);
   else if(type == POSITION_TYPE_SELL)
      trade.Sell(volume, _Symbol);
}

//+------------------------------------------------------------------+
//| Count open positions per direction                               |
//+------------------------------------------------------------------+
int CountPositions(const int type)
{
   int total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!PositionSelectByIndex(i))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((int)PositionGetInteger(POSITION_TYPE) == type)
         total++;
   }
   return(total);
}

//+------------------------------------------------------------------+
//| Manage trailing stops                                             |
//+------------------------------------------------------------------+
void ManageTrailingStops()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;

   double mid_price = (bid + ask) / 2.0;
   double trail_fraction = InpTrailingPercent / 100.0;
   double trail_distance = mid_price * trail_fraction;
   if(trail_distance <= 0.0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!PositionSelectByIndex(i))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      int type = (int)PositionGetInteger(POSITION_TYPE);
      double current_sl = PositionGetDouble(POSITION_SL);
      double current_tp = PositionGetDouble(POSITION_TP);

      if(type == POSITION_TYPE_BUY)
      {
         double new_sl = bid - trail_distance;
         if(new_sl > current_sl)
            trade.PositionModify(ticket, new_sl, current_tp);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double new_sl = ask + trail_distance;
         if(current_sl == 0.0 || new_sl < current_sl)
            trade.PositionModify(ticket, new_sl, current_tp);
      }
   }
}
//+------------------------------------------------------------------+
