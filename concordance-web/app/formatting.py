"""Formatting helpers, also used as Jinja filters."""

from __future__ import annotations

from datetime import date, datetime


def duration(seconds: int | float | None, short: bool = False) -> str:
    s = int(seconds or 0)
    if s < 60:
        return f"{s} s" if s else "0 min"
    minutes = round(s / 60)
    h, m = divmod(minutes, 60)
    if short:
        return f"{h} h" if h and not m else (f"{h}h{m:02d}" if h else f"{m} min")
    if not h:
        return f"{m} min"
    return f"{h} h {m} min" if m else f"{h} h"


def when(ts: int | float | datetime | None) -> str:
    """A date, relative when recent."""
    if ts is None:
        return ""
    dt = ts if isinstance(ts, datetime) else datetime.fromtimestamp(ts)
    days = (date.today() - dt.date()).days
    if days == 0:
        return f"today {dt:%H:%M}"
    if days == 1:
        return "yesterday"
    if 0 < days < 7:
        return f"{days} days ago"
    if dt.year == date.today().year:
        return f"{dt:%-d %b}"
    return f"{dt:%-d %b %Y}"


def day(ts: int | float | datetime | None) -> str:
    if ts is None:
        return ""
    dt = ts if isinstance(ts, datetime) else datetime.fromtimestamp(ts)
    return f"{dt:%-d %b %Y}"


def clock(ts: int | float | None) -> str:
    return "" if ts is None else f"{datetime.fromtimestamp(ts):%H:%M}"


def percent(v: float | None) -> str:
    return "" if v is None else f"{round(v * 100)}%"


def stars(n: int | None) -> str:
    return "" if not n else "★" * n + "☆" * (5 - n)


def day_iso(ts: int | float | None) -> str:
    return "" if ts is None else datetime.fromtimestamp(ts).date().isoformat()
