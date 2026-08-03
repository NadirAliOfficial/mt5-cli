<div align="center">

# mt5-cli

**Compile, backtest and optimize MetaTrader 5 Expert Advisors from the macOS terminal.**

No Windows VM. No Docker. No separate Wine install.
It drives the Wine runtime already bundled inside the official MetaTrader 5.app.

[![platform](https://img.shields.io/badge/platform-macOS-000000?style=flat-square&logo=apple&logoColor=white)](https://www.metatrader5.com/en/download)
[![language](https://img.shields.io/badge/MQL5-blue?style=flat-square)](https://www.mql5.com/en/docs)
[![shell](https://img.shields.io/badge/zsh-89e051?style=flat-square&logo=gnubash&logoColor=black)](#)
[![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

</div>

---

```console
$ mt5t MyEA.mq5 --symbol XAUUSD --from 2026.07.06 --to 2026.07.31 --model 4

compiling MyEA ...
Result: 0 errors, 0 warnings, 823 ms elapsed
testing MyEA  XAUUSD M1  2026.07.06 .. 2026.07.31  model=4

  MetaTrader 5 strategy tester report
  ----------------------------------------------------
  Total Net Profit                1 284.55
  Profit Factor                   1.41
  Expected Payoff                 0.62
  Equity Drawdown Maximal         318.20 (3.11%)
  Total Trades                    2 073
  Profit Trades (% of total)      1 154 (55.67%)
  Recovery Factor                 4.04
  History Quality                 100% real ticks
```

Three commands:

| | |
|---|---|
| **`mt5c`** | compile an `.mq5`, print real errors only, non-zero exit on failure |
| **`mt5t`** | compile → run the strategy tester → print MetaTrader's own report |
| **`mt5d`** | pull tick and bar history for a date range |

---

## Why

Everything MetaTrader does well lives behind a Windows GUI. On a Mac that usually means
a virtual machine, a Docker image, or clicking through MetaEditor and the Strategy Tester
tab for every single change.

But the official **MetaTrader 5.app already ships a complete Wine runtime**, with
`MetaEditor64.exe` and `terminal64.exe` sitting inside it. These scripts talk to those
binaries directly. Nothing extra is installed, and the app keeps working normally.

**Every number printed is parsed out of the report MetaTrader writes itself.** Nothing is
recalculated, estimated or simulated here. If a figure appears, MT5 produced it.

## Install

```bash
git clone https://github.com/NadirAliOfficial/mt5-cli.git
cd mt5-cli
chmod +x mt5c mt5t mt5d

# optional — call from anywhere
ln -s "$PWD"/mt5{c,t,d} /usr/local/bin/
```

**Requires** MetaTrader 5 at `/Applications/MetaTrader 5.app`, Python 3, and one working
trading account (a free demo is fine — see [Accounts](#accounts)).

---

## `mt5c` — compile

```console
$ mt5c ~/eas/MyEA.mq5
Result: 0 errors, 0 warnings, 820 ms elapsed, cpu='X64 Regular'
built -> /Users/you/eas/MyEA.ex5
```

Copies the source into the terminal's `MQL5/Experts`, compiles, prints only real errors
and warnings — include chatter and `generating code 42%` lines are stripped — drops the
`.ex5` next to your source and cleans up. `--keep` leaves the copy in place.

Exit status is non-zero on failure, so it fits straight into a hook or a loop:

```bash
for f in ~/eas/**/*.mq5; do mt5c "$f" || echo "FAILED: $f"; done
```

Missing `#resource` indicators, broken includes and syntax errors all surface with file
and line, exactly as MetaEditor reports them.

```console
$ mt5c client_ea.mq5
MQL5\Experts\client_ea.mq5(10,12) : error 310: resource file '\Indicators\ut_bot.ex5' not found
MQL5\Experts\client_ea.mq5(11,12) : error 310: resource file '\Indicators\QTrend.ex5' not found
Result: 12 errors, 0 warnings
```

## `mt5t` — backtest

```bash
mt5t MyEA.mq5 --symbol XAUUSD --from 2026.01.01 --to 2026.07.31 \
      --period M1 --model 4 --deposit 10000
```

| flag | meaning |
|---|---|
| `--model` | `4` real ticks *(default)*, `0` every tick, `1` OHLC M1, `2` open prices, `3` math |
| `--period` | chart timeframe, default `M1` |
| `--set file.set` | feed a normal MT5 `.set` file in as `[TesterInputs]` |
| `--optimize 1\|2` | sweep a whole parameter grid in one launch — see below |
| `--criterion N` | what to rank optimization by |
| `--spread` | `0` uses the spread stored in the tick data |
| `--deposit` `--leverage` | account model for the run |
| `--json` | machine readable output, for diffing builds |
| `--keep` | keep the compiled `.ex5` and the raw report |

### Real ticks, checked automatically

A backtest on **generated** ticks tells you almost nothing about a strategy that works in
small increments. MetaTrader will quietly fall back to generating ticks from M1 bars when
it has no real ones for your date range, and it does not stop you.

So the check is built in:

```
  warning: history quality is 0% real ticks. MetaTrader generated the ticks instead
  of using real ones, so these figures do not represent real execution.
  Download tick history for this symbol and period, then rerun.
```

This is not a cosmetic detail. The same EA, same settings, same code:

| | generated ticks | real ticks |
|---|---|---|
| Profit factor | **1.97** | **0.34** |
| Win rate | 70.5% | 36.6% |
| Net | +252 | −5 258 |
| Max equity DD | 0.13% | 52.58% |

One of those two results is fiction. Without the flag you would never know which.

### Optimizing — one launch, the whole grid

Give any input a `||start||step||stop||Y` range and pass `--optimize`. MetaTrader runs the
entire grid itself, in parallel across its local agents, in a **single** launch.

```bash
mt5t MyEA.mq5 --symbol XAUUSD --from 2026.07.06 --to 2026.07.31 \
      --set sweep.set --optimize 1 --criterion 1
```

`sweep.set` — five lines, 324 combinations:

```ini
MaxSpreadPips=0.5||0.4||0.4||1.6||Y
MinAtrPips=1.0||1.0||1.5||4.0||Y
DistancePips=2.0||2.0||1.5||5.0||Y
MinStopPips=2.0||2.0||2.0||6.0||Y
RewardRatio=1.3||1.3||0.7||2.7||Y
FastEmaPeriod=8
```

Results come back ranked, showing only the columns that actually varied:

```
  MT5 optimization — 324 passes, best profit factor first

        profit            PF        trades         eqDD%   MaxSpreadPips     RewardRatio
  --------------------------------------------------------------------------------------
           412          1.34           806          4.12             0.4             2.7
           385          1.28           941          5.03             0.8             2.0
```

`--optimize 1` slow complete algorithm, `2` genetic.
`--criterion` — `0` balance, `1` profit factor, `2` expected payoff, `3` drawdown,
`4` recovery factor, `5` Sharpe.

> **Don't hand-roll a sweep as a shell loop over single runs.** It launches the terminal
> once per variant, opens a window every time, and covers a fraction of the grid.

### Comparing two builds

```bash
mt5t old.mq5 --symbol XAUUSD --from 2026.01.01 --to 2026.07.31 --json > old.json
mt5t new.mq5 --symbol XAUUSD --from 2026.01.01 --to 2026.07.31 --json > new.json
diff <(jq -S . old.json) <(jq -S . new.json)
```

## `mt5d` — download history

```bash
mt5d --symbol XAUUSD --from 2026.01.01 --to 2026.08.01 --timeframe M1
```

Compiles and runs an MQL5 script inside the terminal that pulls the range with
`CopyTicksRange` and `CopyRates`, polling until the download settles, then reports what
actually arrived.

Mostly optional — the tester fetches whatever history it needs on its own during the
first run for a symbol and range, and caches it. Useful for pre-warming before a batch,
or for checking what data really exists before committing to a long run.

---

## Accounts

Both history download and real tick testing need a live server connection. **A terminal
with no valid account quits within a second of starting** and no report is produced.

Log in once through the MT5 window, or pass credentials:

```bash
mt5t MyEA.mq5 --symbol XAUUSD --from … --to … \
     --login 12345678 --password '…' --server Pepperstone-Demo
```

`MT5_LOGIN`, `MT5_PASSWORD` and `MT5_SERVER` work as environment variables so nothing
lands in your shell history. The generated config is written `chmod 600`.

> A free MetaQuotes demo works, but its tick history is shallow — older ranges come back
> as generated ticks. A real broker demo gives you deeper real tick data and that broker's
> actual symbols and spreads.

## How it works

```
mt5c ──▶ MetaEditor64.exe /portable /compile:…   ──▶ parses the UTF-16 build log
mt5t ──▶ terminal64.exe   /portable /config:…    ──▶ parses the HTML / SpreadsheetML report
mt5d ──▶ terminal64.exe   [StartUp] Script=…     ──▶ CopyTicksRange + CopyRates
```

Everything runs against the app's own Wine prefix in portable mode, so your normal
MetaTrader install is untouched.

## Known limits

- **The tester needs its window.** `terminal64.exe` will not start with the Wine mac
  graphics driver disabled. Compiling is fully headless; backtesting is not.
- **One instance at a time.** MT5 treats a second launch as a duplicate and exits
  immediately, so `mt5t` waits for MetaEditor to exit before starting the terminal. Close
  the MT5 window before running.
- **`mt5d` needs a connected terminal** and is unverified against every broker.
- Tick history depth depends entirely on your broker.

## License

MIT
