#!/usr/bin/env python3
"""Fetch AI conference deadlines (aideadlines.org) and hard-work quotes into ~/.config/terminal-tiler.

Run: python3 refresh.py        (the coach calls this once a day)
     python3 refresh.py --test (parser self-check, no network)
"""
import datetime as dt
import json
import pathlib
import re
import sys
import urllib.request
from zoneinfo import ZoneInfo

CFG = pathlib.Path.home() / ".config/terminal-tiler"
DEADLINES_URL = "http://aideadlines.org/?sub=ML,CV,NLP,RO,SP,DM,AP,KR,HCI,IRSM,MISC"
QUOTE_URLS = ["https://raw.githubusercontent.com/JamesFT/Database-Quotes-JSON/master/quotes.json",
              "https://zenquotes.io/api/quotes"]
HARD_WORK = re.compile(r"\b(hard work|work hard|working hard|discipline|persever|persist|effort|grind|diligen|"
                       r"practice|sacrific|consisten|focus|labou?r|toil|sweat|perspiration|determin|habit|"
                       r"don't stop|keep going|never give up|excellen)", re.I)


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 terminal-tiler"})
    return urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "replace")


def to_utc(stamp, tz):
    naive = dt.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S")
    tz = {"PT": "America/Los_Angeles", "ET": "America/New_York"}.get(tz.strip(), tz)
    m = re.fullmatch(r"(?:UTC|GMT)([+-]\d{1,2})?", tz.strip())
    if tz.strip().upper() == "AOE":
        off = -12
    elif m:
        off = int(m.group(1) or 0)
    else:
        try:
            return naive.replace(tzinfo=ZoneInfo(tz)).astimezone(dt.timezone.utc)
        except Exception:
            off = 0
    return naive.replace(tzinfo=dt.timezone(dt.timedelta(hours=off))).astimezone(dt.timezone.utc)


def parse_deadlines(html):
    subs = {i: [c[:-5] for c in cls.split() if c.endswith("-conf")]
            for i, cls in re.findall(r'<div id="([\w.-]+)" class="ConfItem\s*([^"]*)"', html)}
    names = dict(re.findall(r'<span class="conf-title">\s*<a [^>]*id=([\w.-]+)">([^<]+)</a>', html))
    out = []
    for tz, stamp, cid in re.findall(
            r'var timezone = "([^"]*)"\s*;\s*var confDate = moment\.tz\("([^"]+)",\s*timezone\);.*?\$\(\'#([\w.-]+) \.timer\'\)',
            html, re.S):
        try:
            when = to_utc(stamp, tz or "UTC")
        except ValueError:
            continue
        out.append({"id": cid, "name": names.get(cid, cid), "subs": subs.get(cid, []),
                    "deadline": when.strftime("%Y-%m-%dT%H:%M:%SZ")})
    return sorted(out, key=lambda d: d["deadline"])


def fetch_quotes():
    seen, out = set(), []
    for url in QUOTE_URLS:
        try:
            data = json.loads(get(url))
        except Exception as e:
            print(f"quotes: {url}: {e}", file=sys.stderr)
            continue
        for row in data:
            q = (row.get("quoteText") or row.get("q") or "").strip()
            a = (row.get("quoteAuthor") or row.get("a") or "Unknown").strip() or "Unknown"
            if q and len(q) < 220 and HARD_WORK.search(q) and q.lower() not in seen:
                seen.add(q.lower())
                out.append({"q": q, "a": a})
    return out


def main():
    CFG.mkdir(parents=True, exist_ok=True)
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        dl = [d for d in parse_deadlines(get(DEADLINES_URL)) if d["deadline"] > now]
        (CFG / "deadlines.json").write_text(json.dumps(dl, indent=1))
        print(f"deadlines: {len(dl)} upcoming")
    except Exception as e:
        print(f"deadlines: {e}", file=sys.stderr)
    quotes = fetch_quotes()
    if quotes:  # keep the old cache if every source failed
        (CFG / "quotes.json").write_text(json.dumps(quotes, indent=1, ensure_ascii=False))
    print(f"quotes: {len(quotes)} hard-work quotes")


def test():
    html = '''<div id="cvpr27" class="ConfItem  CV-conf ML-conf ">
      <span class="conf-title">
        <a title="Deadline Details" href="/conference?id=cvpr27">CVPR 2027</a>
      var timezone = "UTC-12" ;
      var confDate = moment.tz("2026-11-14 23:59:59", timezone);
      // render countdown timer
      $('#cvpr27 .timer').countdown('''
    d = parse_deadlines(html)
    assert d == [{"id": "cvpr27", "name": "CVPR 2027", "subs": ["CV", "ML"],
                  "deadline": "2026-11-15T11:59:59Z"}], d
    assert to_utc("2026-01-01 00:00:00", "America/Los_Angeles").hour == 8
    assert to_utc("2026-01-01 00:00:00", "UTC+8").hour == 16
    print("ok")


if __name__ == "__main__":
    test() if sys.argv[1:] == ["--test"] else main()
