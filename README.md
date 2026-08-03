# mt5-cli

Compile, backtest and download history for MetaTrader 5 from the macOS terminal.

No MetaEditor clicking, no Strategy Tester tab, no Windows VM. The scripts drive the
Wine runtime that ships inside the official **MetaTrader 5.app**, so nothing extra is
installed.

Every figure `mt5t` prints is parsed out of the HTML report MetaTrader writes itself.
Nothing is recalculated, estimated or simulated by these scripts.

```
mt5c  Snipe_FX_Pro.mq5                                    compile
mt5t  Snipe_FX_Pro.mq5 --symbol XAUUSD --from … --to …    compile + backtest + report
mt5d  --symbol XAUUSD --from … --to …                     download tick and bar history
```

---

## Install

```bash
git clone https://github.com/NadirAliOfficial/mt5-cli.git
cd mt5-cli
chmod +x mt5c mt5t mt5d
ln -s "$PWD"/mt5{c,t,d} /usr/local/bin/       # optional, to call from anywhere
```

Requires MetaTrader 5 installed at `/Applications/MetaTrader 5.app` and Python 3.

---

## mt5c — compile

```bash
mt5c path/to/MyEA.mq5
```

```
Result: 0 errors, 0 warnings, 820 ms elapsed, cpu='X64 Regular'
built -> path/to/MyEA.ex5
```

Copies the source into the terminal's `MQL5/Experts`, compiles it, prints only real
errors and warnings (include chatter and progress lines are stripped), drops the `.ex5`
next to your source and cleans up after itself. `--keep` leaves the copy in place.

Exit status is non-zero when the build fails, so it drops straight into a git hook or a
loop over a folder of EAs:

```bash
for f in ~/mt5/**/*.mq5; do mt5c "$f" || echo "FAILED: $f"; done
```

Missing `#resource` indicators, bad includes and syntax errors all surface with file and
line, exactly as MetaEditor reports them.

## mt5t — backtest

```bash
mt5t MyEA.mq5 --symbol XAUUSD --from 2025.01.06 --to 2025.06.30 \
      --period M1 --model 4 --deposit 10000
```

```
  MetaTrader 5 strategy tester report
  ----------------------------------------------------
  Total Net Profit                252.09
  Profit Factor                   1.97
  Expected Payoff                 0.19
  Equity Drawdown Maximal         12.96 (0.13%)
  Total Trades                    1345
  Profit Trades (% of total)      948 (70.48%)
  Recovery Factor                 19.45
  History Quality                 100% real ticks
```

| flag | meaning |
|---|---|
| `--model` | `4` real ticks (default), `0` every tick, `1` OHLC M1, `2` open prices, `3` math |
| `--period` | chart timeframe, default `M1` |
| `--set file.set` | feed a normal MT5 `.set` file in as `[TesterInputs]` |
| `--spread` | `0` uses the spread stored in the tick data |
| `--deposit` / `--leverage` | account model for the run |
| `--json` | machine readable output, for diffing one build against another |
| `--keep` | keep the compiled `.ex5` and the raw HTML report |
| `--show` | let the MT5 window appear (default runs with no window) |

**History quality is checked automatically.** If MetaTrader generated the ticks rather
than using real ones, the run is flagged:

```
warning: history quality is 0% real ticks. MetaTrader generated the ticks instead of
using real ones, so these figures do not represent real execution.
```

That distinction decides whether a scalper's backtest means anything, so it is never
left for you to notice on your own.

### Comparing two builds

```bash
mt5t old.mq5 --symbol XAUUSD --from 2025.01.01 --to 2025.06.30 --json > old.json
mt5t new.mq5 --symbol XAUUSD --from 2025.01.01 --to 2025.06.30 --json > new.json
diff <(jq -S . old.json) <(jq -S . new.json)
```

## mt5d — download history

```bash
mt5d --symbol XAUUSD --from 2025.01.01 --to 2025.07.01 --timeframe M1
```

Compiles and runs an MQL5 script (`scripts/mt5d_fetch.mq5`) inside the terminal that
pulls the range from the broker with `CopyTicksRange` and `CopyRates`, polling until the
download settles, then closes the terminal and reports what actually arrived.

Run this before a real tick backtest of any period the terminal has not cached yet.

---

## Accounts

Downloading history and running a real tick test both need a live server connection.
A terminal with no valid account quits within a second of starting and no report is
produced.

Either log in once through the MT5 window, or pass credentials:

```bash
mt5t MyEA.mq5 --symbol XAUUSD --from … --to … \
     --login 12345678 --password '…' --server Pepperstone-Demo
```

`MT5_LOGIN`, `MT5_PASSWORD` and `MT5_SERVER` work as environment variables so nothing
lands in your shell history. The generated config is written `chmod 600`.

## No window

By default the terminal and MetaEditor run with the Wine mac graphics driver disabled
(`winemac.drv=d`), so no window is created and nothing steals focus. Pass `--show` to
`mt5t` when you want to watch a run.

## Notes

- The MT5 install is treated as portable (`/portable`), so everything stays inside the
  app's own Wine prefix.
- Reports land in `…/MetaTrader 5/reports/`, kept when you pass `--keep`.
- MQL4 sources compile through `mt5c` too if MetaTrader 4 is installed; adjust the
  prefix paths at the top of the script.
