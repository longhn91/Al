#property copyright "AI Risk Manager"
#property version   "1.00"
#property strict
#property description "AI-assisted XAUUSD M1 scalping EA"

#include <Trade/Trade.mqh>

input string InpOpenAIKey              = "";          // OpenAI API Key (Bearer)
input string InpModel                  = "gpt-4.1-mini"; // OpenAI model name
input int    InpAIRefreshMinutes       = 60;           // Minutes between AI refresh
input double InpBaseRiskPercent        = 1.0;          // Base risk per trade (% of equity)
input double InpMaxSpreadPoints        = 250;          // Max spread allowed (points)
input double InpTrendFastPeriod        = 9;            // Fast EMA period
input double InpTrendSlowPeriod        = 26;           // Slow EMA period
input bool   InpUseSessionFilter       = true;         // Restrict trading to a session window
input int    InpSessionStartHour       = 6;            // Session start (broker time)
input int    InpSessionEndHour         = 23;           // Session end (broker time, exclusive)
input bool   InpUseVolatilityFilter    = true;         // Require minimum ATR volatility
input int    InpAtrPeriod              = 14;           // ATR period for volatility filter
input double InpAtrMinPips             = 2.0;          // Minimum ATR (pips) to allow new trades
input bool   InpUseDailyDrawdownGuard  = true;         // Disable entries after daily drawdown hit
input double InpMaxDailyDrawdownPercent= 3.0;          // Max daily equity drawdown (%)
input bool   InpUseBreakEvenLock       = true;         // Move stop to BE after trigger
input double InpBreakEvenTriggerPips   = 8.0;          // Profit (pips) before locking
input double InpBreakEvenLockPips      = 1.0;          // Locked profit in pips at BE
input int    InpMagicNumber            = 4102024;      // Magic number
input bool   InpAllowShort             = true;         // Allow short trades
input bool   InpAllowLong              = true;         // Allow long trades

struct TradeRecommendation
  {
   bool     tradingEnabled;
   double   stopLossPips;
   double   takeProfitPips;
   double   riskMultiplier;
   string   reasoning;
   datetime timestamp;
  };

struct DailyPerformance
  {
   datetime day;
   int      totalTrades;
   int      winningTrades;
   int      losingTrades;
   int      consecutiveLosses;
   double   grossProfit;
   double   grossLoss;
   double   netProfit;
   double   lastEquity;
   double   maxEquity;
   double   minEquity;
  };

CTrade           g_trade;
TradeRecommendation g_aiRec;
DailyPerformance g_stats;
datetime         g_lastAiRequest = 0;
string           g_lastError     = "";
bool             g_riskLockActive = false;
datetime         g_riskLockTriggered = 0;
datetime         g_lastRiskNotice = 0;
datetime         g_lastVolatilityNotice = 0;
datetime         g_lastSessionNotice = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(_Symbol != "XAUUSD")
     {
      Print("Warning: this EA is designed for XAUUSD. Running on ",_Symbol);
     }

   if(InpOpenAIKey == "")
     {
      Print("Warning: provide your OpenAI API key via InpOpenAIKey input.");
     }

   PrintStartupChecklist();

   ResetDailyStats();
   LoadRecommendationFromFile();
   EventSetTimer(60);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

//+------------------------------------------------------------------+
//| Timer event                                                      |
//+------------------------------------------------------------------+
void OnTimer()
  {
   UpdateDailyReset();
   SavePerformanceToFile();

   if(InpOpenAIKey == "")
      return;

   if(TimeCurrent() - g_lastAiRequest < InpAIRefreshMinutes * 60)
      return;

   if(RequestAiRecommendations())
     {
      g_lastAiRequest = TimeCurrent();
      SaveRecommendationToFile();
     }
  }

//+------------------------------------------------------------------+
//| Tick event                                                       |
//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateEquityEnvelope();

   ManagePositions();

   if(!g_aiRec.tradingEnabled)
      return;

   if(InpUseDailyDrawdownGuard && g_riskLockActive)
     {
      ThrottleRiskNotice();
      return;
     }

   if(InpUseSessionFilter && !IsWithinSession())
     {
      if(TimeCurrent() - g_lastSessionNotice > 600)
        {
         Print("Pause: session filter blocking new entries.");
         g_lastSessionNotice = TimeCurrent();
        }
      return;
     }

   double bid = CurrentBid();
   double ask = CurrentAsk();
   if(bid <= 0.0 || ask <= 0.0)
      return;

   double spread = (ask - bid)/_Point;
   if(spread > InpMaxSpreadPoints)
     {
      PrintFormat("Spread too high: %.1f points",spread);
      return;
     }

   if(InpUseVolatilityFilter)
     {
      double atrPips = CurrentAtrInPips();
      if(atrPips < InpAtrMinPips)
        {
         if(TimeCurrent() - g_lastVolatilityNotice > 600)
           {
            PrintFormat("Pause: ATR %.2f pips below threshold %.2f, waiting for volatility.",atrPips,InpAtrMinPips);
            g_lastVolatilityNotice = TimeCurrent();
           }
         return;
        }
     }

   if(PositionsTotalByMagic(InpMagicNumber) == 0)
      CheckForEntrySignal();
  }

//+------------------------------------------------------------------+
//| Trade transaction                                                |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   if(!HistorySelect(trans.time,TimeCurrent()))
      return;

   ulong deal = trans.deal;
   if(!HistoryDealSelect(deal))
      return;

   string symbol = HistoryDealGetString(deal,DEAL_SYMBOL);
   if(symbol != _Symbol)
      return;

   if(HistoryDealGetInteger(deal,DEAL_MAGIC) != InpMagicNumber)
      return;

   double profit = HistoryDealGetDouble(deal,DEAL_PROFIT) +
                   HistoryDealGetDouble(deal,DEAL_SWAP) +
                   HistoryDealGetDouble(deal,DEAL_COMMISSION);

   UpdatePerformance(profit);
  }

//+------------------------------------------------------------------+
//| Reset daily stats                                                |
//+------------------------------------------------------------------+
void ResetDailyStats()
  {
   datetime today = DateOfDay(TimeCurrent());
   g_stats.day = today;
   g_stats.totalTrades = 0;
   g_stats.winningTrades = 0;
   g_stats.losingTrades = 0;
   g_stats.consecutiveLosses = 0;
   g_stats.grossProfit = 0.0;
   g_stats.grossLoss = 0.0;
   g_stats.netProfit = 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_stats.lastEquity = equity;
   g_stats.maxEquity = equity;
   g_stats.minEquity = equity;
   g_riskLockActive = false;
   g_riskLockTriggered = 0;
   g_lastRiskNotice = 0;
  }

//+------------------------------------------------------------------+
//| Update for new day                                               |
//+------------------------------------------------------------------+
void UpdateDailyReset()
  {
   datetime today = DateOfDay(TimeCurrent());
   if(today != g_stats.day)
     {
      ResetDailyStats();
     }
  }

//+------------------------------------------------------------------+
//| Convert time to day                                              |
//+------------------------------------------------------------------+
datetime DateOfDay(datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t,dt);
   dt.hour = dt.min = dt.sec = 0;
   return(StructToTime(dt));
  }

//+------------------------------------------------------------------+
//| Update performance metrics                                       |
//+------------------------------------------------------------------+
void UpdatePerformance(double profit)
  {
   g_stats.totalTrades++;
   g_stats.netProfit += profit;

   if(profit >= 0.0)
     {
      g_stats.winningTrades++;
      g_stats.consecutiveLosses = 0;
      g_stats.grossProfit += profit;
     }
   else
     {
      g_stats.losingTrades++;
      g_stats.consecutiveLosses++;
      g_stats.grossLoss += profit;
     }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_stats.lastEquity = equity;
   g_stats.maxEquity = MathMax(g_stats.maxEquity,equity);
   g_stats.minEquity = MathMin(g_stats.minEquity,equity);

   if(InpUseDailyDrawdownGuard)
      EvaluateRiskLock();
  }

//+------------------------------------------------------------------+
//| Calculate metrics                                                |
//+------------------------------------------------------------------+
double WinRate()
  {
   if(g_stats.totalTrades == 0)
      return(0.0);
   return((double)g_stats.winningTrades / (double)g_stats.totalTrades * 100.0);
  }

double ProfitFactor()
  {
   if(g_stats.grossLoss >= 0.0)
      return(999.0);
   double loss = MathAbs(g_stats.grossLoss);
   if(loss < 0.01)
      return(999.0);
   return(g_stats.grossProfit / loss);
  }

//+------------------------------------------------------------------+
//| Entry logic                                                      |
//+------------------------------------------------------------------+
void CheckForEntrySignal()
  {
   double fast = iMA(_Symbol,PERIOD_M1,(int)InpTrendFastPeriod,0,MODE_EMA,PRICE_CLOSE,0);
   double slow = iMA(_Symbol,PERIOD_M1,(int)InpTrendSlowPeriod,0,MODE_EMA,PRICE_CLOSE,0);
   double fastPrev = iMA(_Symbol,PERIOD_M1,(int)InpTrendFastPeriod,0,MODE_EMA,PRICE_CLOSE,1);
   double slowPrev = iMA(_Symbol,PERIOD_M1,(int)InpTrendSlowPeriod,0,MODE_EMA,PRICE_CLOSE,1);

   bool bullishCross = fast > slow && fastPrev <= slowPrev;
   bool bearishCross = fast < slow && fastPrev >= slowPrev;

   if(bullishCross && InpAllowLong)
     {
      OpenPosition(ORDER_TYPE_BUY);
     }
   else if(bearishCross && InpAllowShort)
     {
      OpenPosition(ORDER_TYPE_SELL);
     }
  }

//+------------------------------------------------------------------+
//| Manage positions                                                 |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   for(int i=PositionsTotal()-1; i>=0; --i)
     {
      if(!PositionSelectByIndex(i))
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      if(symbol != _Symbol)
         continue;

      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double stopDistance = RecommendationStopLossPoints();
      double takeDistance = RecommendationTakeProfitPoints();

      if(stopDistance <= 0.0 || takeDistance <= 0.0)
         continue;

      double newSL = 0.0;
      double newTP = 0.0;

      if(type == POSITION_TYPE_BUY)
        {
         newSL = price - stopDistance * _Point;
         newTP = price + takeDistance * _Point;
        }
      else
        {
         newSL = price + stopDistance * _Point;
         newTP = price - takeDistance * _Point;
        }

      if(InpUseBreakEvenLock && InpBreakEvenTriggerPips > 0.0)
        {
         double profitPips = PositionProfitPips(type,price);
         if(profitPips >= InpBreakEvenTriggerPips)
           {
            double pipSize = PipSize();
            double lockPrice = price;
            if(type == POSITION_TYPE_BUY)
               lockPrice += InpBreakEvenLockPips * pipSize;
            else
               lockPrice -= InpBreakEvenLockPips * pipSize;

            if(type == POSITION_TYPE_BUY)
               newSL = MathMax(newSL,lockPrice);
            else
               newSL = MathMin(newSL,lockPrice);
           }
        }

      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      bool needUpdate = false;

      if(currentSL == 0.0 || MathAbs(currentSL - newSL) > _Point)
        {
         needUpdate = true;
        }

      if(currentTP == 0.0 || MathAbs(currentTP - newTP) > _Point)
        {
         needUpdate = true;
        }

      if(needUpdate)
        {
         if(!g_trade.PositionModify(symbol,newSL,newTP))
            Print("Error: PositionModify failed: ",GetLastError());
        }
     }
  }

//+------------------------------------------------------------------+
//| Open position                                                    |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE type)
  {
   double lot = CalculatePositionSize();
   if(lot <= 0.0)
     {
      Print("Lot calculation resulted in zero.");
      return;
     }

   double stopDistance = RecommendationStopLossPoints();
   double takeDistance = RecommendationTakeProfitPoints();

   double price = (type == ORDER_TYPE_BUY) ? CurrentAsk() : CurrentBid();
   double sl = 0.0;
   double tp = 0.0;

   if(type == ORDER_TYPE_BUY)
     {
      sl = price - stopDistance * _Point;
      tp = price + takeDistance * _Point;
     }
   else
     {
      sl = price + stopDistance * _Point;
      tp = price - takeDistance * _Point;
     }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(20);

   bool result=false;
   if(type == ORDER_TYPE_BUY)
      result = g_trade.Buy(lot,_Symbol,price,sl,tp);
   else
      result = g_trade.Sell(lot,_Symbol,price,sl,tp);

   if(!result)
      Print("Error: trade open failed: ",GetLastError());
  }

//+------------------------------------------------------------------+
//| Position size calculation                                        |
//+------------------------------------------------------------------+
double CalculatePositionSize()
  {
   double stopDistance = RecommendationStopLossPoints();
   if(stopDistance <= 0.0)
      return(0.0);

   double riskPercent = InpBaseRiskPercent * g_aiRec.riskMultiplier;
   riskPercent = MathMax(0.1,riskPercent);
   riskPercent = MathMin(5.0,riskPercent);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (riskPercent/100.0);

   double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);

   double valuePerPoint = 0.0;
   if(tickSize != 0.0)
      valuePerPoint = tickValue / tickSize;

   double stopPoints = stopDistance;
   if(valuePerPoint <= 0.0 || stopPoints <= 0.0)
      return(0.0);

   double lot = riskAmount / (stopPoints * valuePerPoint);

   double minLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   lot = MathMax(minLot,lot);
   lot = MathMin(maxLot,lot);
   lot = NormalizeLot(lot,stepLot);

   return(lot);
  }

//+------------------------------------------------------------------+
//| Normalize lot                                                    |
//+------------------------------------------------------------------+
double NormalizeLot(double lot,double step)
  {
   if(step <= 0.0)
      return(lot);
   double steps = MathFloor(lot/step);
   return(steps*step);
  }

double PositionProfitPips(ENUM_POSITION_TYPE type,double openPrice)
  {
   double pipSize = PipSize();
   if(pipSize <= 0.0)
      return(0.0);

   double bid = CurrentBid();
   double ask = CurrentAsk();

   if(type == POSITION_TYPE_BUY)
      return((bid - openPrice)/pipSize);

   return((openPrice - ask)/pipSize);
  }

//+------------------------------------------------------------------+
//| Stop loss distance in points                                     |
//+------------------------------------------------------------------+
double RecommendationStopLossPoints()
  {
   double pipSize = PipSize();
   return(g_aiRec.stopLossPips * (pipSize/_Point));
  }

//+------------------------------------------------------------------+
//| Take profit distance in points                                   |
//+------------------------------------------------------------------+
double RecommendationTakeProfitPoints()
  {
   double pipSize = PipSize();
   return(g_aiRec.takeProfitPips * (pipSize/_Point));
  }

//+------------------------------------------------------------------+
//| Pip size helper                                                  |
//+------------------------------------------------------------------+
double PipSize()
  {
   if(_Digits == 3 || _Digits == 5)
      return(_Point*10.0);
   return(_Point);
  }

double CurrentBid()
  {
   double value = 0.0;
   if(SymbolInfoDouble(_Symbol,SYMBOL_BID,value))
      return(value);
   MqlTick tick;
   if(SymbolInfoTick(_Symbol,tick))
      return(tick.bid);
   return(0.0);
  }

double CurrentAsk()
  {
   double value = 0.0;
   if(SymbolInfoDouble(_Symbol,SYMBOL_ASK,value))
      return(value);
   MqlTick tick;
   if(SymbolInfoTick(_Symbol,tick))
      return(tick.ask);
   return(0.0);
  }

double CurrentAtrInPips()
  {
   int period = MathMax(1,InpAtrPeriod);
   double atr = iATR(_Symbol,PERIOD_M1,period,0);
   double pipSize = PipSize();
   if(pipSize <= 0.0)
      return(0.0);
   return(atr/pipSize);
  }

bool IsWithinSession()
  {
   if(!InpUseSessionFilter)
      return(true);

   int start = MathMax(0,MathMin(23,InpSessionStartHour));
   int end = MathMax(0,MathMin(24,InpSessionEndHour));

   if(start == end)
      return(true);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   int hour = dt.hour;

   if(start < end)
      return(hour >= start && hour < end);

   return(hour >= start || hour < end);
  }

void UpdateEquityEnvelope()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_stats.lastEquity = equity;
   g_stats.maxEquity = MathMax(g_stats.maxEquity,equity);
   g_stats.minEquity = MathMin(g_stats.minEquity,equity);

   if(InpUseDailyDrawdownGuard)
      EvaluateRiskLock();
  }

double CurrentDrawdownPercent()
  {
   double peak = g_stats.maxEquity;
   if(peak <= 0.0)
      return(0.0);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = (peak - equity)/peak * 100.0;
   if(dd < 0.0)
      dd = 0.0;
   return(dd);
  }

void EvaluateRiskLock()
  {
   if(!InpUseDailyDrawdownGuard || InpMaxDailyDrawdownPercent <= 0.0)
      return;

   double dd = CurrentDrawdownPercent();
   if(!g_riskLockActive && dd >= InpMaxDailyDrawdownPercent)
     {
      g_riskLockActive = true;
      g_riskLockTriggered = TimeCurrent();
      g_lastRiskNotice = TimeCurrent();
      PrintFormat("Risk lock: daily drawdown guard triggered at %.2f%% (limit %.2f%%).",dd,InpMaxDailyDrawdownPercent);
     }
  }

void ThrottleRiskNotice()
  {
   if(TimeCurrent() - g_lastRiskNotice > 600)
     {
      PrintFormat("Risk lock active at %.2f%% drawdown (limit %.2f%%).",CurrentDrawdownPercent(),InpMaxDailyDrawdownPercent);
      g_lastRiskNotice = TimeCurrent();
     }
  }

//+------------------------------------------------------------------+
//| AI Recommendation request                                        |
//+------------------------------------------------------------------+
bool RequestAiRecommendations()
  {
   string url = "https://api.openai.com/v1/chat/completions";
   string prompt = BuildPrompt();

   if(prompt == "")
      return(false);

   string systemMsg = "You are a veteran XAUUSD M1 scalper with ten years of experience. Maximize profit while protecting capital.";
   string body = StringFormat("{\"model\":\"%s\",\"response_format\":{\"type\":\"json_object\"},\"messages\":[{\"role\":\"system\",\"content\":\"%s\"},{\"role\":\"user\",\"content\":\"%s\"}]}",
      InpModel,
      JsonEscape(systemMsg),
      JsonEscape(prompt)
   );

   string headers = "Content-Type: application/json\r\n";
   headers += "Authorization: Bearer " + InpOpenAIKey + "\r\n";

   char result[];
   string result_headers;
   int timeout = 15000;

   ResetLastError();
   int status = WebRequest("POST",url,headers,timeout,body,result,result_headers);
   if(status == -1)
     {
      int err = GetLastError();
      Print("Error: WebRequest failed: ",err," ",ErrorDescription(err));
      g_lastError = "WebRequest error";
      return(false);
     }

   if(status != 200)
     {
      Print("Error: HTTP status ",status);
      g_lastError = "HTTP status";
      return(false);
     }

   string response = CharArrayToString(result);
   return(ParseAiResponse(response));
  }

//+------------------------------------------------------------------+
//| Build prompt                                                     |
//+------------------------------------------------------------------+
string BuildPrompt()
  {
   double drawdown = CurrentDrawdownPercent();
   string sessionState = (InpUseSessionFilter && !IsWithinSession()) ? "CLOSED" : "OPEN";
   double atrPips = CurrentAtrInPips();

   string text;
   text = "CURRENT PERFORMANCE\\n"+
          "WinRate: " + DoubleToString(WinRate(),2) + "%\\n"+
          "TotalTrades: " + IntegerToString(g_stats.totalTrades) + "\\n"+
          "Winning: " + IntegerToString(g_stats.winningTrades) + " Losing: " + IntegerToString(g_stats.losingTrades) + "\\n"+
          "ConsecutiveLosses: " + IntegerToString(g_stats.consecutiveLosses) + "\\n"+
          "DailyProfit: " + DoubleToString(g_stats.netProfit,2) + "\\n"+
          "ProfitFactor: " + DoubleToString(ProfitFactor(),2) + "\\n"+
          "DailyDrawdownPct: " + DoubleToString(drawdown,2) + "\\n"+
          "CURRENT SETTINGS\\n"+
          "StopLossPips: " + DoubleToString(g_aiRec.stopLossPips,1) + "\\n"+
          "TakeProfitPips: " + DoubleToString(g_aiRec.takeProfitPips,1) + "\\n"+
          "RiskMultiplier: " + DoubleToString(g_aiRec.riskMultiplier,2) + "\\n"+
          "RiskLockActive: " + (g_riskLockActive ? "true" : "false") + "\\n"+
          "ATR(" + IntegerToString(MathMax(1,InpAtrPeriod)) + "): " + DoubleToString(atrPips,2) + "\\n"+
          "SessionStatus: " + sessionState;
   return(text);
  }

//+------------------------------------------------------------------+
//| Parse AI response                                                |
//+------------------------------------------------------------------+
bool ParseAiResponse(const string response)
  {
   string payload = ExtractAssistantJson(response);
   if(payload == "")
     {
      Print("Error: AI response missing payload");
      g_lastError = "No payload";
      return(false);
     }

   TradeRecommendation tmp = g_aiRec;
   if(!ParseRecommendationFromJson(payload,tmp))
     {
      Print("Error: unable to parse payload JSON");
      g_lastError = "Payload parse";
      return(false);
     }

   tmp.timestamp = TimeCurrent();
   ValidateRecommendation(tmp);
   g_aiRec = tmp;

   Print("Info: AI recommendations updated: SL=",DoubleToString(g_aiRec.stopLossPips,1)," TP=",DoubleToString(g_aiRec.takeProfitPips,1)," Risk=",DoubleToString(g_aiRec.riskMultiplier,2));
   g_lastError = "";
   return(true);
  }

//+------------------------------------------------------------------+
//| Validate recommendation                                          |
//+------------------------------------------------------------------+
void ValidateRecommendation(TradeRecommendation &rec)
  {
   rec.stopLossPips = MathMax(3.0,MathMin(10.0,rec.stopLossPips));
   rec.takeProfitPips = MathMax(5.0,MathMin(20.0,rec.takeProfitPips));

   if(rec.takeProfitPips < rec.stopLossPips * 1.2)
      rec.takeProfitPips = rec.stopLossPips * 1.5;

   rec.riskMultiplier = MathMax(0.5,MathMin(1.5,rec.riskMultiplier));
  }

//+------------------------------------------------------------------+
//| Save performance file                                            |
//+------------------------------------------------------------------+
void SavePerformanceToFile()
  {
   int handle = FileOpen("Performance_Data.json",FILE_WRITE|FILE_COMMON|FILE_TXT);
   if(handle == INVALID_HANDLE)
      return;

   string json = "{\n"+
                 "  \"daily_performance\": {\n"+
                 "    \"win_rate\": " + DoubleToString(WinRate(),2) + ",\n"+
                 "    \"total_trades\": " + IntegerToString(g_stats.totalTrades) + ",\n"+
                 "    \"winning_trades\": " + IntegerToString(g_stats.winningTrades) + ",\n"+
                 "    \"losing_trades\": " + IntegerToString(g_stats.losingTrades) + ",\n"+
                 "    \"consecutive_losses\": " + IntegerToString(g_stats.consecutiveLosses) + ",\n"+
                 "    \"daily_profit\": " + DoubleToString(g_stats.netProfit,2) + ",\n"+
                 "    \"profit_factor\": " + DoubleToString(ProfitFactor(),2) + ",\n"+
                 "    \"daily_drawdown_percent\": " + DoubleToString(CurrentDrawdownPercent(),2) + ",\n"+
                 "    \"risk_lock_active\": " + (g_riskLockActive ? "true" : "false") + ",\n"+
                 "    \"atr_pips\": " + DoubleToString(CurrentAtrInPips(),2) + ",\n"+
                 "    \"session_status\": \"" + (IsWithinSession() ? "OPEN" : "CLOSED") + "\"\n"+
                 "  },\n"+
                 "  \"current_settings\": {\n"+
                 "    \"stop_loss_pips\": " + DoubleToString(g_aiRec.stopLossPips,1) + ",\n"+
                 "    \"take_profit_pips\": " + DoubleToString(g_aiRec.takeProfitPips,1) + ",\n"+
                 "    \"risk_multiplier\": " + DoubleToString(g_aiRec.riskMultiplier,2) + ",\n"+
                 "    \"break_even_trigger_pips\": " + DoubleToString(InpBreakEvenTriggerPips,1) + ",\n"+
                 "    \"atr_period\": " + IntegerToString(MathMax(1,InpAtrPeriod)) + "\n"+
                 "  }\n"+
                 "}";

   FileWriteString(handle,json);
   FileClose(handle);
  }

//+------------------------------------------------------------------+
//| Save recommendation                                              |
//+------------------------------------------------------------------+
void SaveRecommendationToFile()
  {
   int handle = FileOpen("AI_Recommendations.json",FILE_WRITE|FILE_COMMON|FILE_TXT);
   if(handle == INVALID_HANDLE)
      return;

   string json = "{\n"+
                 "  \"trading_enabled\": " + (g_aiRec.tradingEnabled ? "true" : "false") + ",\n"+
                 "  \"stop_loss_pips\": " + DoubleToString(g_aiRec.stopLossPips,1) + ",\n"+
                 "  \"take_profit_pips\": " + DoubleToString(g_aiRec.takeProfitPips,1) + ",\n"+
                 "  \"risk_multiplier\": " + DoubleToString(g_aiRec.riskMultiplier,2) + ",\n"+
                 "  \"reasoning\": \"" + JsonEscape(g_aiRec.reasoning) + "\",\n"+
                 "  \"timestamp\": \"" + TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS) + "\"\n"+
                 "}";

   FileWriteString(handle,json);
   FileClose(handle);
  }

//+------------------------------------------------------------------+
//| Load recommendation                                              |
//+------------------------------------------------------------------+
void LoadRecommendationFromFile()
  {
   g_aiRec.tradingEnabled = true;
   g_aiRec.stopLossPips = 6.0;
   g_aiRec.takeProfitPips = 10.0;
   g_aiRec.riskMultiplier = 1.0;
   g_aiRec.reasoning = "Default settings";
   g_aiRec.timestamp = TimeCurrent();

   int handle = FileOpen("AI_Recommendations.json",FILE_READ|FILE_COMMON|FILE_TXT);
   if(handle == INVALID_HANDLE)
      return;

   string data = FileReadString(handle);
   FileClose(handle);

   StringTrimLeft(data);
   StringTrimRight(data);
   if(data == "")
      return;

   if(!ParseRecommendationFromJson(data,g_aiRec))
     {
      Print("Warning: could not parse AI_Recommendations.json; using defaults.");
      return;
     }

   ValidateRecommendation(g_aiRec);
   Print("Info: loaded previous AI guidance from AI_Recommendations.json");
  }

//+------------------------------------------------------------------+
//| Positions count by magic                                         |
//+------------------------------------------------------------------+
int PositionsTotalByMagic(int magic)
  {
   int count = 0;
   for(int i=0;i<PositionsTotal();++i)
     {
      if(!PositionSelectByIndex(i))
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == magic && PositionGetString(POSITION_SYMBOL) == _Symbol)
         count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| JSON escape helper                                               |
//+------------------------------------------------------------------+
string JsonEscape(const string text)
  {
   string result = text;
   StringReplace(result,"\\","\\\\");
   StringReplace(result,"\"","\\\"");
   StringReplace(result,"\n","\\n");
   StringReplace(result,"\r","\\r");
   return(result);
  }

//+------------------------------------------------------------------+
//| Extract assistant payload                                        |
//+------------------------------------------------------------------+
string ExtractAssistantJson(const string response)
  {
   int rolePos = StringFind(response,"\"role\":\"assistant\"");
   if(rolePos == -1)
      return("");

   int contentPos = StringFind(response,"\"content\":\"",rolePos);
   if(contentPos == -1)
      return("");

   contentPos += StringLen("\"content\":\"");
   return(ExtractJsonStringToken(response,contentPos));
  }

//+------------------------------------------------------------------+
//| Extract JSON string token                                        |
//+------------------------------------------------------------------+
string ExtractJsonStringToken(const string text,int start)
  {
   string buffer="";
   bool escape=false;
   int len = StringLen(text);
   for(int i=start;i<len;i++)
     {
      ushort ch = (ushort)StringGetCharacter(text,i);
      if(ch == 34 && !escape)
        {
         return(JsonUnescape(buffer));
        }
      if(ch == 92 && !escape)
        {
         escape = true;
         buffer += "\\";
         continue;
        }
      if(escape)
        {
         escape = false;
      }
      buffer += CharToString(ch);
     }
   return("");
  }

//+------------------------------------------------------------------+
//| JSON unescape helper                                             |
//+------------------------------------------------------------------+
string JsonUnescape(const string input)
  {
   string output="";
   int len = StringLen(input);
   for(int i=0;i<len;i++)
     {
      ushort ch = (ushort)StringGetCharacter(input,i);
      if(ch == 92 && i+1 < len)
        {
         ushort next = (ushort)StringGetCharacter(input,i+1);
         i++;
         switch(next)
           {
            case 34: output += "\""; break;
            case 92: output += "\\"; break;
            case 47: output += "/"; break;
            case 98: output += CharToString(8); break;
            case 102: output += CharToString(12); break;
            case 110: output += CharToString(10); break;
            case 114: output += CharToString(13); break;
            case 116: output += CharToString(9); break;
            case 117:
              if(i+4 < len)
                {
                 string hex = StringSubstr(input,i+1,4);
                 int code = HexToInt(hex);
                 output += CharToString((ushort)code);
                 i += 4;
                }
              break;
            default:
              output += CharToString(next);
           }
         continue;
        }
      output += CharToString(ch);
     }
   return(output);
  }

int HexToInt(const string hex)
  {
   int value = 0;
   int len = StringLen(hex);
   for(int i=0;i<len;i++)
     {
      ushort ch = (ushort)StringGetCharacter(hex,i);
      value *= 16;
      if(ch >= 48 && ch <= 57)
         value += ch - 48;
      else if(ch >= 65 && ch <= 70)
         value += ch - 55;
      else if(ch >= 97 && ch <= 102)
         value += ch - 87;
      else
         return(0);
     }
   return(value);
  }

//+------------------------------------------------------------------+
//| Skip whitespace                                                  |
//+------------------------------------------------------------------+
int SkipWhitespace(const string text,int pos)
  {
   int len = StringLen(text);
   while(pos < len)
     {
      ushort ch = (ushort)StringGetCharacter(text,pos);
      if(ch==32 || ch==10 || ch==13 || ch==9)
         pos++;
      else
         break;
     }
   return(pos);
  }

//+------------------------------------------------------------------+
//| Extract JSON number                                              |
//+------------------------------------------------------------------+
bool ExtractJsonNumber(const string json,const string key,double &value)
  {
   string pattern = "\"" + key + "\"";
   int pos = StringFind(json,pattern);
   if(pos == -1)
      return(false);
   pos = StringFind(json,":",pos);
   if(pos == -1)
      return(false);
   pos = SkipWhitespace(json,pos+1);

   int len = StringLen(json);
   string token="";
   for(int i=pos;i<len;i++)
     {
      ushort ch = (ushort)StringGetCharacter(json,i);
      if((ch >= 48 && ch <= 57) || ch==45 || ch==43 || ch==46 || ch==101 || ch==69)
         token += CharToString(ch);
      else
         break;
     }

   if(token == "")
      return(false);

   value = StringToDouble(token);
   return(true);
  }

//+------------------------------------------------------------------+
//| Extract JSON bool                                                |
//+------------------------------------------------------------------+
bool ExtractJsonBool(const string json,const string key,bool &value)
  {
   string pattern = "\"" + key + "\"";
   int pos = StringFind(json,pattern);
   if(pos == -1)
      return(false);
   pos = StringFind(json,":",pos);
   if(pos == -1)
      return(false);
   pos = SkipWhitespace(json,pos+1);

   string lower = StringSubstr(json,pos,5);
   lower = StringToLower(lower);
   if(StringSubstr(lower,0,4) == "true")
     {
      value = true;
      return(true);
     }
   if(StringSubstr(lower,0,5) == "false")
     {
      value = false;
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Extract JSON string                                              |
//+------------------------------------------------------------------+
bool ExtractJsonStringValue(const string json,const string key,string &value)
  {
   string pattern = "\"" + key + "\"";
   int pos = StringFind(json,pattern);
   if(pos == -1)
      return(false);
   pos = StringFind(json,":",pos);
   if(pos == -1)
      return(false);
   pos = SkipWhitespace(json,pos+1);

   int len = StringLen(json);
   if(pos >= len || (ushort)StringGetCharacter(json,pos) != 34)
      return(false);

   pos++;
   string buffer="";
   bool escape=false;
   for(int i=pos;i<len;i++)
     {
      ushort ch = (ushort)StringGetCharacter(json,i);
      if(ch==34 && !escape)
        {
         value = JsonUnescape(buffer);
         return(true);
        }
      if(ch==92 && !escape)
        {
         escape = true;
         buffer += "\\";
         continue;
        }
      if(escape)
        {
         escape = false;
      }
      buffer += CharToString(ch);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Parse recommendation JSON                                        |
//+------------------------------------------------------------------+
bool ParseRecommendationFromJson(const string json,TradeRecommendation &out)
  {
   bool ok = true;
   bool boolVal;
   double numVal;
   string strVal;

   if(ExtractJsonBool(json,"trading_enabled",boolVal))
      out.tradingEnabled = boolVal;
   else
      ok = false;

   if(ExtractJsonNumber(json,"stop_loss_pips",numVal))
      out.stopLossPips = numVal;
   else
      ok = false;

   if(ExtractJsonNumber(json,"take_profit_pips",numVal))
      out.takeProfitPips = numVal;
   else
      ok = false;

   if(ExtractJsonNumber(json,"risk_multiplier",numVal))
      out.riskMultiplier = numVal;
   else
      ok = false;

   if(ExtractJsonStringValue(json,"reasoning",strVal))
      out.reasoning = strVal;
   else
      out.reasoning = "";

   return(ok);
  }

//+------------------------------------------------------------------+
//| Error description helper                                         |
//+------------------------------------------------------------------+
string ErrorDescription(int code)
  {
   switch(code)
     {
      case 4014: return "WebRequest not allowed. Add api.openai.com to allowed URLs.";
      default: return(IntegerToString(code));
     }
  }

//+------------------------------------------------------------------+
//| Startup checklist                                                |
//+------------------------------------------------------------------+
void PrintStartupChecklist()
  {
   Print("Setup checklist: 1) Compile EA, 2) Tools > Options > Expert Advisors > add https://api.openai.com to WebRequest, 3) Set InpOpenAIKey, 4) Attach to XAUUSD M1 chart.");
   Print("Info: AI refreshes every ",IntegerToString(InpAIRefreshMinutes)," minutes. Last signal persists from AI_Recommendations.json if available.");
   Print("Info: risk guard - session filter=",(InpUseSessionFilter?"ON":"OFF"),", ATR filter=",(InpUseVolatilityFilter?"ON":"OFF"),", daily DD cap=",DoubleToString(InpMaxDailyDrawdownPercent,1),"%.");
  }

//+------------------------------------------------------------------+
