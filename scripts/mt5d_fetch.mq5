//+------------------------------------------------------------------+
//|                                                  mt5d_fetch.mq5  |
//|   Headless history downloader driven by the mt5d shell command.  |
//|   Reads MQL5\Files\mt5d.txt, pulls ticks and bars from the       |
//|   broker, writes MQL5\Files\mt5d_result.txt, closes the terminal.|
//+------------------------------------------------------------------+
#property copyright "NAK"
#property version   "1.00"
#property script_show_inputs false

#define REQ_FILE "mt5d.txt"
#define RES_FILE "mt5d_result.txt"

string   g_symbol   = "";
datetime g_from     = 0;
datetime g_to       = 0;
bool     g_wantBars = true;
ENUM_TIMEFRAMES g_tf = PERIOD_M1;
int      g_timeout  = 600;   // seconds

string   g_lines[];
int      g_lineCount = 0;

//+------------------------------------------------------------------+
void Log(const string s)
{
   Print(s);
   ArrayResize(g_lines, g_lineCount + 1);
   g_lines[g_lineCount++] = s;
}

//+------------------------------------------------------------------+
bool ReadRequest()
{
   int fh = FileOpen(REQ_FILE, FILE_READ | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE)
   {
      Log("ERROR: cannot read " + REQ_FILE + " err=" + (string)GetLastError());
      return false;
   }

   while(!FileIsEnding(fh))
   {
      string line = FileReadString(fh);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(line == "" || StringGetCharacter(line, 0) == '#') continue;

      int eq = StringFind(line, "=");
      if(eq < 0) continue;

      string key = StringSubstr(line, 0, eq);
      string val = StringSubstr(line, eq + 1);
      StringTrimRight(key); StringTrimLeft(val);

      if(key == "symbol")   g_symbol = val;
      else if(key == "from") g_from  = StringToTime(val);
      else if(key == "to")   g_to    = StringToTime(val);
      else if(key == "bars") g_wantBars = (val == "1" || val == "true");
      else if(key == "timeout") g_timeout = (int)StringToInteger(val);
      else if(key == "timeframe")
      {
         if(val == "M1")      g_tf = PERIOD_M1;
         else if(val == "M5")  g_tf = PERIOD_M5;
         else if(val == "M15") g_tf = PERIOD_M15;
         else if(val == "M30") g_tf = PERIOD_M30;
         else if(val == "H1")  g_tf = PERIOD_H1;
         else if(val == "H4")  g_tf = PERIOD_H4;
         else if(val == "D1")  g_tf = PERIOD_D1;
      }
   }
   FileClose(fh);

   if(g_symbol == "" || g_from == 0 || g_to == 0)
   {
      Log("ERROR: request missing symbol, from or to");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
void WriteResult(const bool ok)
{
   int fh = FileOpen(RES_FILE, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE) return;
   FileWrite(fh, ok ? "STATUS=OK" : "STATUS=FAIL");
   for(int i = 0; i < g_lineCount; i++)
      FileWrite(fh, g_lines[i]);
   FileClose(fh);
}

//+------------------------------------------------------------------+
bool EnsureSymbol()
{
   if(!SymbolSelect(g_symbol, true))
   {
      Log("ERROR: symbol " + g_symbol + " not available on this server");
      return false;
   }
   Log("symbol " + g_symbol + " selected");
   return true;
}

//+------------------------------------------------------------------+
//| CopyTicksRange returns -1 while the terminal is still pulling     |
//| history from the server, so it is polled until it settles.        |
//+------------------------------------------------------------------+
bool FetchTicks()
{
   MqlTick ticks[];
   ulong fromMs = (ulong)g_from * 1000;
   ulong toMs   = (ulong)g_to   * 1000;

   uint started = GetTickCount();
   int  last    = -1;

   while(GetTickCount() - started < (uint)g_timeout * 1000)
   {
      int got = CopyTicksRange(g_symbol, ticks, COPY_TICKS_ALL, fromMs, toMs);
      if(got > 0)
      {
         Log("ticks=" + (string)got
             + " first=" + TimeToString(ticks[0].time, TIME_DATE | TIME_SECONDS)
             + " last="  + TimeToString(ticks[got - 1].time, TIME_DATE | TIME_SECONDS));
         return true;
      }

      int err = GetLastError();
      if(got == 0 && err == 0)
      {
         Log("WARNING: server returned no ticks for this range");
         return false;
      }
      if(got != last)
      {
         Log("downloading ticks ... err=" + (string)err);
         last = got;
      }
      ResetLastError();
      Sleep(500);
   }

   Log("ERROR: tick download timed out after " + (string)g_timeout + "s");
   return false;
}

//+------------------------------------------------------------------+
bool FetchBars()
{
   MqlRates rates[];
   uint started = GetTickCount();

   while(GetTickCount() - started < (uint)g_timeout * 1000)
   {
      int got = CopyRates(g_symbol, g_tf, g_from, g_to, rates);
      if(got > 0)
      {
         Log("bars=" + (string)got + " tf=" + EnumToString(g_tf)
             + " first=" + TimeToString(rates[0].time, TIME_DATE | TIME_MINUTES)
             + " last="  + TimeToString(rates[got - 1].time, TIME_DATE | TIME_MINUTES));
         return true;
      }
      ResetLastError();
      Sleep(500);
   }

   Log("ERROR: bar download timed out");
   return false;
}

//+------------------------------------------------------------------+
void OnStart()
{
   bool ok = false;

   if(ReadRequest())
   {
      Log("request " + g_symbol
          + " " + TimeToString(g_from, TIME_DATE)
          + " .. " + TimeToString(g_to, TIME_DATE));

      // give the terminal a moment to reach the server before asking for history
      for(int i = 0; i < 60 && !TerminalInfoInteger(TERMINAL_CONNECTED); i++)
         Sleep(500);

      if(!TerminalInfoInteger(TERMINAL_CONNECTED))
         Log("ERROR: terminal is not connected to a server");
      else if(EnsureSymbol())
      {
         bool tickOk = FetchTicks();
         bool barOk  = g_wantBars ? FetchBars() : true;
         ok = (tickOk && barOk);
      }
   }

   WriteResult(ok);
   TerminalClose(ok ? 0 : 1);
}
//+------------------------------------------------------------------+
