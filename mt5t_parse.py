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


def optimization_rows(doc):
    """MT5 writes optimization results as SpreadsheetML: one <Row> per pass."""
    rows = []
    for raw in re.findall(r"<Row[^>]*>(.*?)</Row>", doc, re.S | re.I):
        cells_ = []
        for cell in re.findall(r"<Cell[^>]*>(.*?)</Cell>", raw, re.S | re.I):
            txt = re.sub(r"<[^>]+>", " ", cell)
            cells_.append(" ".join(html.unescape(txt).replace("\xa0", " ").split()))
        if cells_:
            rows.append(cells_)
    return rows


def show_optimization(doc):
    rows = optimization_rows(doc)
    if len(rows) < 2:
        return False

    header = rows[0]
    body = [r for r in rows[1:] if len(r) >= len(header) // 2]
    if not body:
        return False

    def col(*names):
        for i, h in enumerate(header):
            if any(n.lower() == h.lower() for n in names):
                return i
        return None

    i_pf = col("Profit Factor")
    i_pr = col("Profit", "Result")
    i_tr = col("Trades", "Total Trades")
    i_dd = col("Equity DD %", "Equity Drawdown Maximal", "Drawdown")

    def f(row, i):
        if i is None or i >= len(row):
            return 0.0
        m = re.search(r"-?[\d ]*\d[\d ]*\.?\d*", row[i].replace(" ", " "))
        return float(m.group().replace(" ", "")) if m else 0.0

    body.sort(key=lambda r: f(r, i_pf), reverse=True)

    varying = [
        i for i, h in enumerate(header)
        if i not in (i_pf, i_pr, i_tr, i_dd)
        and len({r[i] for r in body if i < len(r)}) > 1
    ]

    print()
    print(f"  MT5 optimization — {len(body)} passes, best profit factor first")
    print()
    head = ["profit", "PF", "trades", "eqDD%"] + [header[i] for i in varying]
    print("  " + "  ".join(f"{h:>12}" for h in head))
    print("  " + "-" * (14 * len(head)))
    for row in body[:25]:
        vals = [f"{f(row, i_pr):>12.0f}", f"{f(row, i_pf):>12.2f}",
                f"{f(row, i_tr):>12.0f}", f"{f(row, i_dd):>12.2f}"]
        vals += [f"{row[i] if i < len(row) else '':>12}" for i in varying]
        print("  " + "  ".join(vals))
    print()

    best = f(body[0], i_pf)
    if best < 1.0:
        print("  No pass reached a profit factor of 1.0. Every parameter combination")
        print("  tested loses money on this data, so the entry itself has no edge.")
        print()
    return True


def main():
    path = sys.argv[1]
    doc = read(path)

    if path.lower().endswith(".xml") or "<Worksheet" in doc:
        if show_optimization(doc):
            return 0

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
