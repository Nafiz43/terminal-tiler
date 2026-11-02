#!/usr/bin/env python3
"""Fetch AI conference deadlines (aideadlines.org), AI news (TLDR, OpenAI, Anthropic) and tech hard-work quotes
into ~/.config/terminal-tiler.

Run: python3 refresh.py        (the coach calls this once a day)
     python3 refresh.py --test (parser self-check, no network)
"""
import datetime as dt
import email.utils
import html as htmllib
import json
import pathlib
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
from zoneinfo import ZoneInfo

CFG = pathlib.Path.home() / ".config/terminal-tiler"
DEADLINES_URL = "http://aideadlines.org/?sub=ML,CV,NLP,RO,SP,DM,AP,KR,HCI,IRSM,MISC"
QUOTE_URLS = ["https://raw.githubusercontent.com/JamesFT/Database-Quotes-JSON/master/quotes.json",
              "https://zenquotes.io/api/quotes"]
NEWS_FEEDS = [("TLDR AI", "https://tldr.tech/api/rss/ai"),
              ("TLDR Tech", "https://tldr.tech/api/rss/tech"),
              ("OpenAI", "https://openai.com/news/rss.xml"),
              # Anthropic has no official feed; community scrape of anthropic.com/news
              ("Anthropic", "https://raw.githubusercontent.com/Olshansk/rss-feeds/main/feeds/feed_anthropic_news.xml")]
# Builders, engineers, scientists: downloaded quotes are kept only from these authors.
TECH_AUTHORS = re.compile(r"Edison|Jobs|Gates|Musk|Einstein|Tesla|Ford|Feynman|Turing|Hopper|Torvalds|Knuth|Bezos|"
                          r"Graham|Hamming|Carmack|Wozniak|Drucker|Kay|Huang|Newton|Curie|Benjamin Franklin|Wright brothers|Orville Wright|Wilbur Wright", re.I)
TECH_QUOTES = [
    ("Talk is cheap. Show me the code.", "Linus Torvalds"),
    ("Real artists ship.", "Steve Jobs"),
    ("Stay hungry. Stay foolish.", "Steve Jobs"),
    ("The best way to predict the future is to invent it.", "Alan Kay"),
    ("Done is better than perfect.", "Facebook office poster"),
    ("If you are not embarrassed by the first version of your product, you've launched too late.", "Reid Hoffman"),
    ("Make something people want.", "Paul Graham"),
    ("If you do not work on important problems, it's unlikely you'll do important work.", "Richard Hamming"),
    ("Knowledge and productivity are like compound interest.", "Richard Hamming"),
    ("I wish upon you ample doses of pain and suffering.", "Jensen Huang"),
    ("We are stubborn on vision. We are flexible on details.", "Jeff Bezos"),
    ("Focus is a matter of deciding what things you're not going to do.", "John Carmack"),
    ("What I cannot create, I do not understand.", "Richard Feynman"),
    ("The most dangerous phrase in the language is, 'We've always done it this way.'", "Grace Hopper"),
    ("Genius is one percent inspiration and ninety-nine percent perspiration.", "Thomas Edison"),
]
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


def fetch_news(days=14, per_feed=12):
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)
    out = []
    for src, url in NEWS_FEEDS:
        try:
            items = ET.fromstring(get(url)).findall(".//item")
        except Exception as e:
            print(f"news: {src}: {e}", file=sys.stderr)
            continue
        for it in items[:per_feed]:
            try:
                when = email.utils.parsedate_to_datetime(it.findtext("pubDate"))
            except Exception:
                continue
            if when < cutoff:
                continue
            summary = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", htmllib.unescape(it.findtext("description") or ""))).strip()
            if len(summary) > 220:
                summary = summary[:217].rsplit(" ", 1)[0] + "..."
            out.append({"src": src, "title": (it.findtext("title") or "").strip(), "summary": summary,
                        "date": when.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
    return sorted(out, key=lambda n: n["date"], reverse=True)  # newest first


def fetch_quotes():
    seen = {q.lower() for q, _ in TECH_QUOTES}
    out = [{"q": q, "a": a} for q, a in TECH_QUOTES]
    for url in QUOTE_URLS:
        try:
            data = json.loads(get(url))
        except Exception as e:
            print(f"quotes: {url}: {e}", file=sys.stderr)
            continue
        for row in data:
            q = (row.get("quoteText") or row.get("q") or "").strip()
            a = (row.get("quoteAuthor") or row.get("a") or "Unknown").strip() or "Unknown"
            if q and len(q) < 220 and HARD_WORK.search(q) and TECH_AUTHORS.search(a) and q.lower() not in seen:
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
    (CFG / "quotes.json").write_text(json.dumps(quotes, indent=1, ensure_ascii=False))
    print(f"quotes: {len(quotes)} tech hard-work quotes")
    news = fetch_news()
    if news:  # keep the old cache if every feed failed
        (CFG / "news.json").write_text(json.dumps(news, indent=1, ensure_ascii=False))
    print(f"news: {len(news)} items")


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
