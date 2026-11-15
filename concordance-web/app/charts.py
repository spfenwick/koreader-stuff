"""Small server-rendered SVG charts: a reading calendar and bar charts.

Colors come from CSS variables (see static/style.css), so light and dark
mode each use their own steps. Every mark carries a data-tip for the hover
tooltip (static/app.js) and a <title> for screen readers.
"""

from __future__ import annotations

from datetime import date, timedelta
from html import escape

from markupsafe import Markup

from .formatting import duration

# Calendar levels, in minutes read that day.
LEVELS = (0, 15, 30, 60, 120)
LEVEL_LABELS = ("None", "Under 15 min", "15–30 min", "30–60 min", "1–2 h", "2 h or more")


def _level(seconds: int) -> int:
    if not seconds:
        return 0
    minutes = seconds / 60
    n = 0
    for i, lim in enumerate(LEVELS):
        if minutes >= lim:
            n = i + 1
    return n


def calendar(daily: dict[date, int], end: date, weeks: int = 53, link: str | None = None,
             first: date | None = None) -> Markup:
    """A GitHub-style calendar of reading time: a column per week, Monday at the top."""
    cell, gap = 11, 2
    step = cell + gap
    left, top = 28, 16
    last_monday = end - timedelta(days=end.weekday())
    start = last_monday - timedelta(weeks=weeks - 1)
    width = left + weeks * step
    height = top + 7 * step
    out = [f'<svg class="chart calendar" viewBox="0 0 {width} {height + 4}" role="img" '
           f'aria-label="Reading time per day, {start:%-d %b %Y} to {end:%-d %b %Y}">']
    for i, name in ((0, "Mon"), (2, "Wed"), (4, "Fri")):
        out.append(f'<text class="axis" x="0" y="{top + i * step + cell - 2}">{name}</text>')
    month = None
    for w in range(weeks):
        monday = start + timedelta(weeks=w)
        ref = first if first and monday < first else monday
        if ref.month != month:
            month = ref.month
            if w < weeks - 2:
                out.append(f'<text class="axis" x="{left + w * step}" y="10">{ref:%b}</text>')
        for d in range(7):
            day = monday + timedelta(days=d)
            if day > end:
                break
            if first and day < first:
                continue
            secs = daily.get(day, 0)
            lvl = _level(secs)
            tip = f"{day:%a %-d %b %Y}: {duration(secs) if secs else 'no reading'}"
            x, y = left + w * step, top + d * step
            rect = (f'<rect class="cell l{lvl}" x="{x}" y="{y}" width="{cell}" height="{cell}" rx="2" '
                    f'data-tip="{escape(tip)}"><title>{escape(tip)}</title></rect>')
            if link and secs:
                rect = f'<a href="{escape(link)}{day.isoformat()}">{rect}</a>'
            out.append(rect)
    out.append("</svg>")
    return Markup("".join(out))


def calendar_legend() -> Markup:
    items = "".join(f'<span class="swatch cell l{i}"></span>' for i in range(len(LEVEL_LABELS)))
    return Markup(f'<div class="legend">Less {items} More'
                  f'<span class="legend-detail">{" · ".join(LEVEL_LABELS[1:])}</span></div>')


def _nice_max(v: float) -> float:
    if v <= 0:
        return 1
    for m in (1, 2, 5, 10, 15, 30, 60, 120, 180, 300, 600, 900, 1800, 3600, 7200, 10800, 18000, 36000, 72000):
        if v <= m * 60:
            return m * 60
    return v


def _nice_count(v: float) -> int:
    """The smallest of 1, 2, 5, 10, 20, 50… that is at least v."""
    m = 1
    while True:
        for k in (1, 2, 5):
            if v <= k * m:
                return k * m
        m *= 10


def _plural(n: int, unit: tuple[str, str]) -> str:
    return f"{n:,} {unit[0] if n == 1 else unit[1]}"


def bars(items: list[tuple[str, int, str]], height: int = 160, label_every: int = 1,
         aria: str = "Reading time", width: int = 640, unit: tuple[str, str] | None = None,
         links: list[str | None] | None = None) -> Markup:
    """Vertical bars. items: (axis label, value, tooltip label). Values are seconds,
    or counts of `unit` (singular, plural), e.g. ("page", "pages"). links, if given,
    holds one href (or None) per item; bars with a value link to it."""
    n = len(items)
    if not n:
        return Markup("")
    # One fixed width for every bar chart, so text comes out the same size in each.
    left, bottom, top = 44, 20, 8
    slot = (width - left - 4) / n
    bar_w = max(3, min(slot - 2, 44))  # at least a 2px gap between bars
    plot_h = height - bottom - top
    peak = max(v for _, v, _ in items)
    if unit:
        vmax = _nice_count(peak) if peak > 0 else 1
        tick = lambda v: f"{v:,}"  # noqa: E731
        value = lambda v: _plural(v, unit) if v else "no reading"  # noqa: E731
    else:
        vmax = _nice_max(peak)
        tick = lambda v: duration(v, short=True)  # noqa: E731
        value = lambda v: duration(v) if v else "no reading"  # noqa: E731
    cls = "chart bars wide" if width > 640 else "chart bars"
    out = [f'<svg class="{cls}" viewBox="0 0 {width} {height}" role="img" aria-label="{escape(aria)}">']
    # A half-way gridline only where it lands on a whole number.
    for frac in ((0.5, 1.0) if not unit or vmax % 2 == 0 else (1.0,)):
        y = top + plot_h * (1 - frac)
        out.append(f'<line class="grid" x1="{left}" x2="{width}" y1="{y:.1f}" y2="{y:.1f}"/>')
        out.append(f'<text class="axis" x="{left - 6}" y="{y + 4:.1f}" text-anchor="end">{tick(int(vmax * frac))}</text>')
    base = top + plot_h
    out.append(f'<line class="baseline" x1="{left}" x2="{width}" y1="{base}" y2="{base}"/>')
    for i, (label, v, tip_label) in enumerate(items):
        x = left + i * slot + (slot - bar_w) / 2
        tip = escape(f"{tip_label}: {value(v)}")
        h = plot_h * v / vmax if v else 0
        href = links[i] if links and v else None
        if href:
            out.append(f'<a href="{escape(href)}">')
        # Hit target: the whole column, so short bars are easy to hover.
        out.append(f'<g data-tip="{tip}"><title>{tip}</title>'
                   f'<rect class="hit" x="{left + i * slot}" y="{top}" width="{slot}" height="{plot_h}"/>')
        if h > 0:
            h = max(h, 2)
            r = min(4, bar_w / 2, h)
            y = base - h
            # Rounded at the data end only, square on the baseline.
            out.append(f'<path class="bar" d="M{x:.1f},{base} V{y + r:.1f} Q{x:.1f},{y:.1f} {x + r:.1f},{y:.1f} '
                       f'H{x + bar_w - r:.1f} Q{x + bar_w:.1f},{y:.1f} {x + bar_w:.1f},{y + r:.1f} V{base} Z"/>')
        out.append("</g>")
        if href:
            out.append("</a>")
        if label and i % label_every == 0:
            out.append(f'<text class="axis" x="{left + i * slot + slot / 2:.1f}" y="{height - 4}" '
                       f'text-anchor="middle">{escape(label)}</text>')
    out.append("</svg>")
    return Markup("".join(out))
