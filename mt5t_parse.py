#!/usr/bin/env python3
"""Read an MT5 strategy tester HTML report and print its figures.

Every value printed is lifted verbatim from the report MetaTrader wrote.
Nothing is recalculated here.
"""
import html
import json
import os
import re
import sys

WANTED = [
    "Total Net Profit",
    "Gross Profit",
    "Gross Loss",
    "Profit Factor",
    "Expected Payoff",
    "Recovery Factor",
    "Sharpe Ratio",
    "Balance Drawdown Maximal",
    "Balance Drawdown Relative",
    "Equity Drawdown Maximal",
    "Equity Drawdown Relative",
    "Total Trades",
    "Total Deals",
    "Profit Trades (% of total)",
    "Loss Trades (% of total)",
    "Largest profit trade",
    "Largest loss trade",
    "Average profit trade",
    "Average loss trade",
    "Maximum consecutive wins ($)",
    "Maximum consecutive losses ($)",
    "History Quality",
    "Bars",
    "Ticks",
]

HEADLINE = [
    "Total Net Profit",
    "Profit Factor",
    "Expected Payoff",
    "Equity Drawdown Maximal",
    "Balance Drawdown Maximal",
    "Total Trades",
    "Profit Trades (% of total)",
    "Recovery Factor",
    "Sharpe Ratio",
    "History Quality",
]


def read(path):
    for enc in ("utf-16", "utf-8", "cp1252", "latin-1"):
        try:
            with open(path, encoding=enc) as fh:
                text = fh.read()
            if "<" in text:
                return text
        except (UnicodeDecodeError, UnicodeError):
            continue
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def cells(doc):
    """Flatten every table cell in document order."""
    out = []
    for raw in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", doc, re.S | re.I):
        txt = re.sub(r"<[^>]+>", " ", raw)
        txt = html.unescape(txt)
        txt = txt.replace("\xa0", " ")
        out.append(" ".join(txt.split()))
    return out


def extract(doc):
    flat = cells(doc)
    found = {}
    for i, cell in enumerate(flat):
        label = cell.rstrip(":").strip()
        if label not in WANTED or label in found:
            continue
        for j in range(i + 1, min(i + 4, len(flat))):
            val = flat[j].strip()
            if val and val.rstrip(":") not in WANTED:
                found[label] = val
                break
    return found


def main():
    path = sys.argv[1]
    doc = read(path)
    data = extract(doc)

    if not data:
        print("could not read any figures from the report:", path)
        return 1

    if os.environ.get("MT5T_JSON") == "1":
        print(json.dumps(data, indent=2))
        return 0

    width = max(len(k) for k in data)
    print()
    print("  MetaTrader 5 strategy tester report")
    print("  " + "-" * (width + 22))
    for key in HEADLINE:
        if key in data:
            print(f"  {key:<{width}}  {data[key]}")
    rest = [k for k in WANTED if k in data and k not in HEADLINE]
    if rest:
        print("  " + "-" * (width + 22))
        for key in rest:
            print(f"  {key:<{width}}  {data[key]}")
    print()

    warn = []

    trades = data.get("Total Trades", "0")
    if re.sub(r"[^0-9]", "", trades) in ("", "0"):
        warn.append("zero trades — check symbol, dates, or a filter blocking every entry.")

    quality = data.get("History Quality", "")
    pct = re.search(r"([\d.]+)\s*%", quality)
    if pct and float(pct.group(1)) < 90:
        warn.append(
            f"history quality is {quality}. MetaTrader generated the ticks instead of "
            "using real ones, so these figures do not represent real execution. "
            "Download tick history for this symbol and period, then rerun."
        )

    for line in warn:
        print(f"  warning: {line}")
    if warn:
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
