"""OmniSync web: browse the books, highlights and reading statistics OmniSync
keeps on the server.

Configuration (environment):
  OMNISYNC_READING_DIR  the server's <folder>/Reading (default /data/reading), read only
  OMNISYNC_DATA_DIR     where the app keeps its databases (default /cache)
  SYNC_INTERVAL         seconds between imports (default 60)
  WEB_USERNAME, WEB_PASSWORD   if both set, pages need HTTP basic auth
  LUAJIT, INGEST_SCRIPT        how to run the ingester
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import json
import os
import secrets
import sqlite3
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta
from pathlib import Path
from urllib.parse import parse_qs, quote

from starlette.applications import Starlette
from starlette.exceptions import HTTPException
from starlette.middleware import Middleware
from starlette.requests import Request
from starlette.responses import PlainTextResponse, RedirectResponse, Response
from starlette.routing import Mount, Route
from starlette.staticfiles import StaticFiles
from starlette.templating import Jinja2Templates

from . import charts, formatting
from .cwa import CWA, CWAError, plain_text
from .library import STATUS_LABELS, Library
from .settings import Settings
from .sync import Syncer

HERE = Path(__file__).resolve().parent
READING_DIR = Path(os.environ.get("OMNISYNC_READING_DIR", "/data/reading"))
DATA_DIR = Path(os.environ.get("OMNISYNC_DATA_DIR", "/cache"))
INTERVAL = int(os.environ.get("SYNC_INTERVAL", "60"))
LUAJIT = os.environ.get("LUAJIT", "luajit")
INGEST_SCRIPT = os.environ.get("INGEST_SCRIPT", str(HERE.parent / "ingest" / "ingest.lua"))
USERNAME = os.environ.get("WEB_USERNAME", "")
PASSWORD = os.environ.get("WEB_PASSWORD", "")

library = Library(DATA_DIR)
settings = Settings(DATA_DIR / "settings.json")
cwa = CWA(settings, DATA_DIR)
syncer = Syncer(library, [LUAJIT, INGEST_SCRIPT, str(READING_DIR), str(DATA_DIR)], INTERVAL)

templates = Jinja2Templates(directory=str(HERE / "templates"))
env = templates.env
env.filters.update(duration=formatting.duration, when=formatting.when, day=formatting.day,
                   clock=formatting.clock, percent=formatting.percent, stars=formatting.stars,
                   day_iso=formatting.day_iso)


def cover_url(book) -> str | None:
    return f"/cover/{book.id}" if cwa.cover_href(book.uuids, book.calibre_ids) else None


env.globals.update(STATUS_LABELS=STATUS_LABELS, syncer=syncer, cover_url=cover_url)


def render(request: Request, name: str, **ctx) -> Response:
    return templates.TemplateResponse(request, name, ctx)


def ts(d: date) -> int:
    return int(datetime(d.year, d.month, d.day).timestamp())


def streaks(daily: dict[date, int], today: date) -> tuple[int, int]:
    """(current streak, longest streak) in days with any reading."""
    days = sorted(d for d, s in daily.items() if s > 0)
    longest = run = 0
    prev = None
    for d in days:
        run = run + 1 if prev and (d - prev).days == 1 else 1
        longest = max(longest, run)
        prev = d
    current = 0
    d = today if daily.get(today) else today - timedelta(days=1)
    while daily.get(d):
        current += 1
        d -= timedelta(days=1)
    return current, longest


def books_by_day(by_md5, start: date, end: date) -> dict[date, list[tuple]]:
    """{day: [(book, seconds, pages)], longest first} for days in [start, end]."""
    out = {}
    for d, per_md5 in library.daily_books(ts(start), ts(end + timedelta(days=1))).items():
        merged: dict[str, list] = {}
        for md5, (secs, pages) in per_md5.items():
            b = by_md5.get(md5)
            if b:
                row = merged.setdefault(b.id, [b, 0, 0])
                row[1] += secs
                row[2] += pages
        out[d] = sorted((tuple(r) for r in merged.values()), key=lambda r: -r[1])
    return out


def month_calendar(by_md5, month: date, today: date) -> dict:
    """A Monday-first month grid: weeks of (day, [(book, seconds, pages)]); None pads the edges."""
    last = (month.replace(day=28) + timedelta(days=4)).replace(day=1) - timedelta(days=1)
    read = books_by_day(by_md5, month, min(last, today))
    cells: list = [None] * month.weekday()
    cells += [(month + timedelta(days=i), read.get(month + timedelta(days=i), []))
              for i in range(last.day)]
    cells += [None] * (-len(cells) % 7)
    prev = (month - timedelta(days=1)).replace(day=1)
    nxt = last + timedelta(days=1)
    return {"month": month, "weeks": [cells[i:i + 7] for i in range(0, len(cells), 7)],
            "prev": prev, "next": nxt if nxt <= today else None}


# Pages ---------------------------------------------------------------------------------

async def home(request: Request):
    books, by_md5, _, annotations, daily, counts = library.snapshot()
    today = date.today()
    try:
        month = date.fromisoformat(request.query_params.get("month", "") + "-01")
    except ValueError:
        month = today.replace(day=1)
    if month > today:
        month = today.replace(day=1)

    # Pages per day over the last two weeks.
    first = today - timedelta(days=13)
    recent_days = books_by_day(by_md5, first, today)
    page_items = []
    for i in range(14):
        d = first + timedelta(days=i)
        pages = sum(p for _, _, p in recent_days.get(d, []))
        page_items.append((f"{d:%a %-d}", pages, f"{d:%a %-d %b}"))
    pages_chart = charts.bars(page_items, aria="Pages read per day, last two weeks", unit=("page", "pages"),
                              width=960, height=180)
    week = today - timedelta(days=today.weekday())

    def since(d0: date) -> int:
        return sum(s for d, s in daily.items() if d0 <= d <= today)

    current, longest = streaks(daily, today)
    tiles = [
        ("Today", formatting.duration(daily.get(today, 0))),
        ("This week", formatting.duration(since(week))),
        ("This month", formatting.duration(since(today.replace(day=1)))),
        (f"{today.year}", formatting.duration(since(today.replace(month=1, day=1)))),
        ("Streak", f"{current} day{'s' if current != 1 else ''}"),
        ("Longest streak", f"{longest} days"),
    ]
    recent = sorted((b for b in books.values() if b.last_opened), key=lambda b: -b.last_opened)
    reading = [b for b in recent if b.status not in ("complete", "abandoned")][:6]
    return render(request, "home.html", tiles=tiles, reading=reading, recent=recent[:12],
                  highlights=[a for a in annotations if not a.is_bookmark][:8], counts=counts,
                  calendar=charts.calendar(daily, today, link="/day/"), legend=charts.calendar_legend(),
                  pages_chart=pages_chart, pages_total=sum(v for _, v, _ in page_items),
                  month_cal=month_calendar(by_md5, month, today), today=today)


SORTS = {
    "recent": ("Last opened", lambda b: -(b.last_opened or 0)),
    "title": ("Title", lambda b: b.title.casefold()),
    "author": ("Author", lambda b: (b.authors.casefold(), b.title.casefold())),
    "time": ("Time read", lambda b: -b.read_time),
    "highlights": ("Highlights", lambda b: -len(b.highlights)),
    "rating": ("Rating", lambda b: (-(b.rating or 0), b.title.casefold())),
}


async def books_page(request: Request):
    books, _, collections, _, _, _ = library.snapshot()
    q = request.query_params.get("q", "").strip()
    status = request.query_params.get("status", "")
    coll = request.query_params.get("coll", "")
    sort = request.query_params.get("sort", "recent")
    items = list(books.values())
    if q:
        terms = q.casefold().split()
        items = [b for b in items if all(t in b.search_text() for t in terms)]
    if status == "none":
        items = [b for b in items if not b.status]
    elif status:
        items = [b for b in items if b.status == status]
    if coll:
        items = [b for b in items if coll in b.collections]
    items.sort(key=SORTS.get(sort, SORTS["recent"])[1])
    return render(request, "books.html", books=items, q=q, status=status, coll=coll, sort=sort,
                  sorts=SORTS, collections=sorted(collections.values(), key=lambda c: c.name.casefold()),
                  total=len(books))


def _book_chart(daily: dict[date, int], first: date, last: date):
    span = (last - first).days + 1
    if span <= 90:
        items = []
        for i in range(span):
            d = first + timedelta(days=i)
            items.append((f"{d:%-d %b}", daily.get(d, 0), f"{d:%a %-d %b %Y}"))
        return charts.bars(items, label_every=max(1, span // 8), aria="Reading time per day",
                           width=960, height=200), "per day"
    weeks: dict[date, int] = {}
    for d, s in daily.items():
        monday = d - timedelta(days=d.weekday())
        weeks[monday] = weeks.get(monday, 0) + s
    start = first - timedelta(days=first.weekday())
    n = (last - start).days // 7 + 1
    items = [(f"{start + timedelta(weeks=i):%-d %b}", weeks.get(start + timedelta(weeks=i), 0),
              f"Week of {start + timedelta(weeks=i):%-d %b %Y}") for i in range(n)]
    return charts.bars(items, label_every=max(1, n // 8), aria="Reading time per week",
                       width=960, height=200), "per week"


async def book_page(request: Request):
    _, by_md5, collections, _, _, _ = library.snapshot()
    book = by_md5.get(request.path_params["id"])
    if book is None:
        raise HTTPException(404, "No such book")
    if book.id != request.path_params["id"]:
        return RedirectResponse(f"/book/{book.id}", 301)
    sessions = library.sessions(book.md5s)
    chart = scope = None
    if sessions:
        daily = library.daily_for(book.md5s)
        if daily:
            chart, scope = _book_chart(daily, min(daily), max(daily))
    chapters: list[tuple[str, str, list]] = []  # (edition md5, chapter, highlights)
    for a in book.highlights:
        if not chapters or chapters[-1][0] != a.md5 or chapters[-1][1] != a.chapter:
            chapters.append((a.md5, a.chapter, []))
        chapters[-1][2].append(a)
    # A description set in KOReader comes first, then the library's (Calibre-Web).
    description = plain_text(book.description) or cwa.description(book.uuids, book.calibre_ids)
    return render(request, "book.html", book=book, sessions=sessions, chart=chart, chart_scope=scope,
                  chapters=chapters, collections=collections, description=description,
                  multi=len({a.md5 for a in book.highlights}) > 1)


async def book_markdown(request: Request):
    _, by_md5, _, _, _, _ = library.snapshot()
    book = by_md5.get(request.path_params["id"])
    if book is None:
        raise HTTPException(404, "No such book")
    lines = [f"# {book.title}", ""]
    if book.authors:
        lines += [f"*{book.authors}*", ""]
    if book.review:
        lines += ["## Review", "", book.review, ""]
    chapter = None
    for a in book.highlights:
        if a.chapter != chapter:
            chapter = a.chapter
            lines += [f"## {chapter or 'Highlights'}", ""]
        lines += ["> " + a.text.replace("\n", "\n> "), ""]
        if a.note:
            lines += [a.note, ""]
        meta = " · ".join(x for x in (a.page_label, a.fields.get("datetime", "")) if x)
        if meta:
            lines += [f"<sub>{meta}</sub>", ""]
    name = "".join(c if c.isalnum() or c in " -_" else "_" for c in book.title).strip() or "highlights"
    return PlainTextResponse("\n".join(lines), media_type="text/markdown; charset=utf-8",
                             headers={"Content-Disposition": f'attachment; filename="{name}.md"'})


PAGE_SIZE = 50
COLORS = ("yellow", "orange", "red", "purple", "blue", "cyan", "green", "olive", "gray")


async def highlights_page(request: Request):
    _, _, _, annotations, _, _ = library.snapshot()
    q = request.query_params.get("q", "").strip()
    color = request.query_params.get("color", "")
    notes = request.query_params.get("notes", "")
    items = [a for a in annotations if not a.is_bookmark]
    if q:
        terms = q.casefold().split()
        items = [a for a in items
                 if all(t in f"{a.text}\n{a.note}\n{a.chapter}\n{a.book.title}\n{a.book.authors}".casefold()
                        for t in terms)]
    if color:
        items = [a for a in items if a.color == color]
    if notes:
        items = [a for a in items if a.note]
    try:
        page = max(1, int(request.query_params.get("page", "1")))
    except ValueError:
        page = 1
    pages = max(1, (len(items) + PAGE_SIZE - 1) // PAGE_SIZE)
    page = min(page, pages)
    shown = items[(page - 1) * PAGE_SIZE: page * PAGE_SIZE]
    used = sorted({a.color for a in annotations if not a.is_bookmark},
                  key=lambda c: COLORS.index(c) if c in COLORS else 99)
    return render(request, "highlights.html", items=shown, total=len(items), q=q, color=color,
                  notes=notes, page=page, pages=pages, colors=used)


async def day_page(request: Request):
    try:
        d = date.fromisoformat(request.path_params["day"])
    except ValueError:
        raise HTTPException(404, "Not a date")
    books, by_md5, _, annotations, daily, _ = library.snapshot()
    stats = library.period_stats(ts(d), ts(d + timedelta(days=1)))
    read = {}
    for md5, (secs, pages) in stats["by_md5"].items():
        b = by_md5.get(md5)
        if b:
            t, p = read.get(b.id, (0, 0))
            read[b.id] = (t + secs, p + pages)
    rows = sorted(((books[i], t, p) for i, (t, p) in read.items()), key=lambda r: -r[1])
    made = [a for a in annotations if a.created and a.created.date() == d and not a.is_bookmark]
    hours = [(f"{h:02d}", s, f"{h:02d}:00–{h:02d}:59") for h, s in enumerate(stats["hours"])]
    return render(request, "day.html", day=d, rows=rows, total=daily.get(d, 0), highlights=made,
                  hours=charts.bars(hours, height=120, label_every=3, aria="Reading time per hour"),
                  prev=d - timedelta(days=1), next=d + timedelta(days=1))


async def stats_page(request: Request):
    books, by_md5, _, _, daily, counts = library.snapshot()
    today = date.today()
    years = sorted({d.year for d in daily} | {today.year}, reverse=True)
    sel = request.query_params.get("year", str(today.year))
    if sel == "all":
        start, end = date(min(years), 1, 1), today
        bars = charts.bars([(str(y), sum(s for d, s in daily.items() if d.year == y), str(y))
                            for y in sorted(years)], aria="Reading time per year",
                            width=960, height=200)
        bars_title = "Per year"
        cal = None
        label = "All time"
    else:
        try:
            year = int(sel)
        except ValueError:
            year = today.year
        start, end = date(year, 1, 1), min(date(year, 12, 31), today) if year == today.year else date(year, 12, 31)
        months = []
        for m in range(1, 13):
            secs = sum(s for d, s in daily.items() if d.year == year and d.month == m)
            months.append((date(year, m, 1).strftime("%b"), secs, date(year, m, 1).strftime("%B %Y")))
        bars = charts.bars(months, aria=f"Reading time per month, {year}", width=960, height=200)
        bars_title = "Per month"
        cal_end = date(year, 12, 31) if year < today.year else today
        weeks = ((cal_end - (date(year, 1, 1) - timedelta(days=date(year, 1, 1).weekday()))).days // 7) + 1
        cal = charts.calendar({d: s for d, s in daily.items() if d.year == year}, cal_end, weeks=weeks, link="/day/",
                              first=date(year, 1, 1))
        label = str(year)
        sel = str(year)
    period = library.period_stats(ts(start), ts(end + timedelta(days=1)))
    per_book: dict[str, list] = {}
    for md5, (secs, pages) in period["by_md5"].items():
        b = by_md5.get(md5)
        if b:
            row = per_book.setdefault(b.id, [b, 0, 0])
            row[1] += secs
            row[2] += pages
    top = sorted(per_book.values(), key=lambda r: -r[1])
    in_range = {d: s for d, s in daily.items() if start <= d <= end}
    total = sum(in_range.values())
    days_read = sum(1 for s in in_range.values() if s)
    _, longest = streaks(in_range, end)
    finished = [b for b in books.values() if b.status == "complete" and b.props.get("status")
                and start <= datetime.fromtimestamp(b.props["status"].updated).date() <= end]
    tiles = [
        ("Time read", formatting.duration(total)),
        ("Days with reading", str(days_read)),
        ("Per reading day", formatting.duration(total / days_read if days_read else 0)),
        ("Books opened", str(len(top))),
        ("Finished", str(len(finished))),
        ("Longest streak", f"{longest} days"),
    ]
    hours = charts.bars([(f"{h:02d}", s, f"{h:02d}:00–{h:02d}:59") for h, s in enumerate(period["hours"])],
                        height=150, label_every=3, aria="Reading time by hour of day", width=420)
    names = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
    weekdays = charts.bars([(n, s, n) for n, s in zip(names, period["weekdays"])], height=150,
                           aria="Reading time by day of the week", width=420)
    return render(request, "stats.html", years=years, sel=sel, label=label, tiles=tiles, bars=bars,
                  bars_title=bars_title, calendar=cal, legend=charts.calendar_legend(), hours=hours,
                  weekdays=weekdays, top=top, finished=finished, counts=counts)


async def collections_page(request: Request):
    _, _, collections, _, _, _ = library.snapshot()
    items = sorted(collections.values(), key=lambda c: (c.id != "favorites", c.name.casefold()))
    return render(request, "collections.html", collections=items)


async def status_page(request: Request):
    devices = []
    try:
        devices = json.loads((DATA_DIR / "devices.json").read_text())
    except (OSError, ValueError):
        pass
    bad, seen = [], {}
    state = DATA_DIR / "state.sqlite3"
    if state.exists():
        conn = sqlite3.connect(f"file:{state}?mode=ro", uri=True, timeout=10)
        try:
            bad = conn.execute("SELECT device_id, name, reason FROM bad_segments ORDER BY device_id, name").fetchall()
            for dev, n in conn.execute("SELECT device_id, count(*) FROM seen_segments GROUP BY device_id"):
                seen[dev] = n
        except sqlite3.Error:
            pass
        finally:
            conn.close()
    *_, counts = library.snapshot()
    return render(request, "status.html", devices=devices, bad=bad, seen=seen, counts=counts,
                  state=syncer.state, reading_dir=READING_DIR, loaded_at=library.loaded_at, interval=INTERVAL)


async def sync_now(request: Request):
    syncer.trigger()
    return RedirectResponse("/status", 303)


async def cover(request: Request):
    _, by_md5, _, _, _, _ = library.snapshot()
    book = by_md5.get(request.path_params["id"])
    href = book and cwa.cover_href(book.uuids, book.calibre_ids)
    if not href:
        raise HTTPException(404, "No cover")
    got = await asyncio.to_thread(cwa.cover, href)
    if not got:
        raise HTTPException(404, "No cover")
    data, ctype = got
    return Response(data, media_type=ctype, headers={"Cache-Control": "private, max-age=86400"})


catalog_wake = asyncio.Event()


async def catalog_loop():
    """Reads the CWA catalog when it's due (daily) or asked for."""
    while True:
        if cwa.catalog_due():
            await asyncio.to_thread(cwa.refresh_catalog)
        try:
            await asyncio.wait_for(catalog_wake.wait(), timeout=600)
        except asyncio.TimeoutError:
            pass
        catalog_wake.clear()


async def settings_page(request: Request):
    books, *_ = library.snapshot()
    notice = request.query_params.get("notice", "")
    return render(request, "settings.html", cwa=cwa, settings=settings, notice=notice,
                  error=request.query_params.get("error", ""),
                  has_password=bool(settings.get("cwa_password")),
                  matched=cwa.matched(books.values()) if cwa.read_at else 0, total=len(books))


async def read_form(request: Request) -> dict[str, str]:
    """A URL-encoded form's fields (the only kind these pages send)."""
    body = await request.body()
    if len(body) > 64 * 1024:
        raise HTTPException(413, "Form too large")
    return {k: v[-1] for k, v in parse_qs(body.decode("utf-8", "replace"), keep_blank_values=True).items()}


async def settings_save(request: Request):
    form = await read_form(request)
    action = form.get("action", "save")
    if action == "refresh":
        cwa.read_at = None
        catalog_wake.set()
        return RedirectResponse("/settings?notice=Reading+the+catalog%E2%80%A6", 303)
    if action == "remove":
        settings.update(cwa_url="", cwa_username="", cwa_password="")
        await asyncio.to_thread(cwa.forget)
        return RedirectResponse("/settings?notice=Covers+turned+off.", 303)
    url = str(form.get("cwa_url", "")).strip()
    user = str(form.get("cwa_username", "")).strip()
    password = str(form.get("cwa_password", ""))
    if url and not url.lower().startswith(("http://", "https://")):
        return RedirectResponse("/settings?error=" + quote("The address must start with http:// or https://."), 303)
    changed_server = url != settings.get("cwa_url")
    changes = {"cwa_url": url, "cwa_username": user}
    if password or not user or form.get("clear_password"):
        changes["cwa_password"] = password  # empty keeps the saved one, unless asked
    settings.update(**changes)
    if not url:
        await asyncio.to_thread(cwa.forget)
        return RedirectResponse("/settings?notice=Covers+turned+off.", 303)
    if changed_server:
        await asyncio.to_thread(cwa.forget)
    try:
        message = await asyncio.to_thread(cwa.test)
    except CWAError as e:
        return RedirectResponse("/settings?error=" + quote(str(e)), 303)
    cwa.read_at = None if changed_server or not cwa.read_at else cwa.read_at
    catalog_wake.set()
    return RedirectResponse("/settings?notice=" + quote(message + " Reading the catalog for covers…"), 303)


async def health(request: Request):
    return PlainTextResponse("ok")


# Basic auth ------------------------------------------------------------------------------

class SameOrigin:
    """Refuses form posts from other sites (the browser would send a saved login along)."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and scope["method"] == "POST":
            # Browsers say where a request comes from; a reverse proxy doesn't change this
            # (it may change Host, so Origin can't be compared with it).
            site = dict(scope["headers"]).get(b"sec-fetch-site", b"").decode()
            if site and site not in ("same-origin", "none"):
                return await PlainTextResponse("Cross-site request refused", 403)(scope, receive, send)
        return await self.app(scope, receive, send)


class BasicAuth:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or not (USERNAME and PASSWORD) or scope["path"] == "/health":
            return await self.app(scope, receive, send)
        header = dict(scope["headers"]).get(b"authorization", b"").decode()
        if header.startswith("Basic "):
            try:
                user, _, pw = base64.b64decode(header[6:]).decode().partition(":")
                if secrets.compare_digest(user, USERNAME) and secrets.compare_digest(pw, PASSWORD):
                    return await self.app(scope, receive, send)
            except (binascii.Error, UnicodeDecodeError):
                pass
        response = PlainTextResponse("Sign in required", 401, headers={"WWW-Authenticate": 'Basic realm="OmniSync"'})
        await response(scope, receive, send)


@asynccontextmanager
async def lifespan(app):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    syncer.start()
    catalog = asyncio.create_task(catalog_loop())
    yield
    catalog.cancel()
    await syncer.stop()


app = Starlette(
    routes=[
        Route("/", home),
        Route("/books", books_page),
        Route("/book/{id}", book_page),
        Route("/book/{id}/highlights.md", book_markdown),
        Route("/highlights", highlights_page),
        Route("/day/{day}", day_page),
        Route("/stats", stats_page),
        Route("/collections", collections_page),
        Route("/status", status_page),
        Route("/sync", sync_now, methods=["POST"]),
        Route("/settings", settings_page),
        Route("/settings", settings_save, methods=["POST"]),
        Route("/cover/{id}", cover),
        Route("/health", health),
        Mount("/static", StaticFiles(directory=str(HERE / "static")), name="static"),
    ],
    middleware=[Middleware(BasicAuth), Middleware(SameOrigin)],
    lifespan=lifespan,
)
