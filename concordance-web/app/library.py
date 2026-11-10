"""The merged Concordance data, read from the ingester's databases.

Books, highlights and book data are small (hundreds of books, thousands of
highlights), so they're loaded into memory and rebuilt after each import that
changed something. Readings (hundreds of thousands of rows) stay in SQLite
and are queried per page.

A "book" here is a work: every file the plugin's book identity joined (the
same UUID) is one book, with each file an edition. A file no device has an
identity record for joins the book with exactly its title and authors, as
the plugin does for statistics (title_key); its book data stays its own. Book data that applies to
every version (status, rating, review, custom metadata, collections, when it
was last opened) is merged across editions the way the plugin does: the
record with the highest (updated, device, hash) wins. Highlights and readings
belong to their own file and are listed per edition.
"""

from __future__ import annotations

import json
import re
import sqlite3
import threading
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path

COLLECTIONS_MD5 = "collections"
META_KEYS = ("title", "authors", "series", "series_index", "keywords", "language", "description")
GROUP_PROPS = {"status", "rating", "note", "hist"} | {f"meta.{k}" for k in META_KEYS}
STATUS_LABELS = {"reading": "Reading", "complete": "Finished", "abandoned": "On hold"}
SESSION_GAP = 30 * 60  # seconds between readings that start a new session

_ASCII_LOWER = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")
_PUNCT_OR_CONTROL = re.compile(r"[!-/:-@\[-`{-~\x00-\x1f\x7f]")


def title_key(title, authors) -> str | None:
    """What two files must share to be joined by title: the plugin's
    Store.titleKey (ASCII lowercase, punctuation and control characters as
    spaces, spaces collapsed). None for a missing or placeholder value."""
    def norm(v) -> str:
        if not isinstance(v, str):
            return ""
        return re.sub(" +", " ", _PUNCT_OR_CONTROL.sub(" ", v.translate(_ASCII_LOWER))).strip()
    t, a = norm(title), norm(authors)
    if t in ("", "n a", "untitled") or a in ("", "n a", "unknown", "unknown author"):
        return None
    return f"{t}\0{a}"


def title_groups(group_of: dict[str, str], recorded: set, titles: list[tuple[str, str, str]]) -> dict[str, str]:
    """Files without an identity record joined by title (the plugin's
    loadGroups in store.lua): md5 -> group, for each file placed so. A file
    joins the one book (identity group, or recorded file alone) with its
    title key; files without records sharing a key, with no such book, join
    each other. group_of (md5 -> group) is updated in place."""
    by_key: dict[str, list[str]] = {}
    for md5, title, authors in sorted(titles):
        key = title_key(title, authors)
        if key and md5 not in by_key.setdefault(key, []):
            by_key[key].append(md5)
    placed: dict[str, str] = {}
    for key in sorted(by_key):
        books, loose = set(), []
        for md5 in by_key[key]:
            if md5 in recorded:
                books.add(group_of.get(md5, md5))
            elif md5 not in placed:
                loose.append(md5)
        if not loose or len(books) > 1:
            continue
        members = [m for m, g in group_of.items() if g in books] or list(books)
        members += loose
        if len(members) < 2:
            continue
        grp = min(members)
        for m in members:
            group_of[m] = grp
        for m in loose:
            placed[m] = grp
    return placed


def is_group_prop(prop: str) -> bool:
    return prop in GROUP_PROPS or prop.startswith("coll.")


@dataclass
class Record:
    updated: int
    device: str
    deleted: bool
    hash: str
    value: object

    def beats(self, other: Record | None) -> bool:
        # BookStore.wins: (updated, device, hash), highest wins.
        if other is None:
            return True
        return (self.updated, self.device, self.hash) > (other.updated, other.device, other.hash)


@dataclass
class Annotation:
    md5: str
    kind: str  # rolling (reflowable) or paging (PDF, DjVu)
    key: str
    updated: int
    device: str
    fields: dict
    book: Book | None = None

    @property
    def text(self) -> str:
        return self.fields.get("text") or ""

    @property
    def note(self) -> str:
        return self.fields.get("note") or ""

    @property
    def chapter(self) -> str:
        return self.fields.get("chapter") or ""

    @property
    def color(self) -> str:
        return self.fields.get("color") or "yellow"

    @property
    def drawer(self) -> str:
        return self.fields.get("drawer") or ""

    @property
    def is_bookmark(self) -> bool:
        return not self.fields.get("drawer") and not self.fields.get("pos0")

    @property
    def created(self) -> datetime | None:
        try:
            return datetime.strptime(self.fields.get("datetime", ""), "%Y-%m-%d %H:%M:%S")
        except ValueError:
            return None

    @property
    def page_label(self) -> str:
        page = self.fields.get("page")
        return f"p. {page}" if self.kind == "paging" and isinstance(page, int) else ""

    @property
    def order(self) -> tuple:
        """Position in the book, for listing highlights in reading order."""
        page = self.fields.get("page")
        if self.kind == "paging":
            pos = self.fields.get("pos0")
            y = pos.get("y", 0) if isinstance(pos, dict) else 0
            return (page if isinstance(page, (int, float)) else 0, y, self.key)
        return (xpointer_key(self.fields.get("pos0") or page), self.key)


_STEP = re.compile(r"([^/\[\]]+)(?:\[(\d+)\])?")


def xpointer_key(xp) -> tuple:
    """A sort key for a CREngine XPointer like /body/DocFragment[12]/body/p[3]/text().45.

    Sibling indexes count per tag name, so this is document order within a
    chapter only roughly; chapters (DocFragments) come out right.
    """
    if not isinstance(xp, str):
        return ()
    path, _, offset = xp.partition(".")
    key = [int(m.group(2) or 1) for m in _STEP.finditer(path)]
    key.append(int(offset) if offset.isdigit() else 0)
    return tuple(key)


@dataclass
class Edition:
    md5: str
    title: str = ""
    authors: str = ""
    pages: int | None = None
    kinds: set = field(default_factory=set)
    read_time: int = 0
    pages_read: int = 0
    first_read: int | None = None
    last_read: int | None = None
    progress: float | None = None  # furthest page read / total pages
    # Book identity: what devices said about this file (IDENTITY.md).
    uuids: set = field(default_factory=set)
    sig: str | None = None  # body signature, read from the file itself
    sources: set = field(default_factory=set)  # "file", "sidecar", "link"
    reported_by: set = field(default_factory=set)  # device IDs that sent a fact
    text: str | None = None  # "A", "B", …: files with the same text share a letter
    by_title: bool = False  # no identity record: joined by title and authors


@dataclass
class Book:
    id: str  # the first MD5 of its group, used in URLs
    editions: list[Edition]
    props: dict[str, Record]
    annotations: list[Annotation] = field(default_factory=list)
    collections: list[str] = field(default_factory=list)  # collection ids
    uuids: list[str] = field(default_factory=list)  # from book identity, for matching a catalog
    calibre_ids: list[int] = field(default_factory=list)

    @property
    def md5s(self) -> list[str]:
        return [e.md5 for e in self.editions]

    def value(self, prop: str):
        rec = self.props.get(prop)
        return None if rec is None or rec.deleted else rec.value

    @property
    def title(self) -> str:
        return self.value("meta.title") or self._main.title or "Untitled"

    @property
    def authors(self) -> str:
        return self.value("meta.authors") or self._main.authors or ""

    @property
    def author_list(self) -> list[str]:
        return [a.strip() for a in re.split(r"\n|;", self.authors) if a.strip()]

    @property
    def series(self) -> str:
        s = self.value("meta.series") or ""
        idx = self.value("meta.series_index")
        return f"{s} #{idx}" if s and idx else s

    @property
    def description(self) -> str:
        return self.value("meta.description") or ""

    @property
    def status(self) -> str | None:
        return self.value("status")

    @property
    def status_label(self) -> str:
        return STATUS_LABELS.get(self.status or "", "")

    @property
    def rating(self) -> int | None:
        r = self.value("rating")
        return r if isinstance(r, int) else None

    @property
    def review(self) -> str:
        return self.value("note") or ""

    @property
    def last_opened(self) -> int | None:
        h = self.value("hist")
        if isinstance(h, (int, float)):
            return int(h)
        return self.last_read

    @property
    def _main(self) -> Edition:
        # The edition read the most names the book when nothing else does.
        return max(self.editions, key=lambda e: (e.read_time, bool(e.title)))

    @property
    def read_time(self) -> int:
        return sum(e.read_time for e in self.editions)

    @property
    def first_read(self) -> int | None:
        times = [e.first_read for e in self.editions if e.first_read]
        return min(times) if times else None

    @property
    def last_read(self) -> int | None:
        times = [e.last_read for e in self.editions if e.last_read]
        return max(times) if times else None

    @property
    def progress(self) -> float | None:
        if self.status == "complete":
            return 1.0
        p = [e.progress for e in self.editions if e.progress is not None]
        return max(p) if p else None

    @property
    def highlights(self) -> list[Annotation]:
        return [a for a in self.annotations if not a.is_bookmark]

    @property
    def bookmarks(self) -> list[Annotation]:
        return [a for a in self.annotations if a.is_bookmark]

    @property
    def notes_count(self) -> int:
        return sum(1 for a in self.annotations if a.note and not a.is_bookmark)

    @property
    def joined_by(self) -> list[str]:
        """The UUIDs that tie this book's files together: those in two or more."""
        seen: dict[str, int] = {}
        for e in self.editions:
            for u in e.uuids:
                seen[u] = seen.get(u, 0) + 1
        return sorted(u for u, n in seen.items() if n > 1)

    @property
    def texts(self) -> int:
        """How many different texts its files have (as far as known)."""
        return len({e.text for e in self.editions if e.text})

    @property
    def unread_texts(self) -> int:
        """Files whose text hasn't been read (no signature)."""
        return sum(1 for e in self.editions if not e.sig)

    def search_text(self) -> str:
        return f"{self.title}\n{self.authors}\n{self.series}".casefold()


@dataclass
class Collection:
    id: str
    name: str
    books: list[Book] = field(default_factory=list)


def _decode(value: str | None):
    if value is None:
        return None
    try:
        return json.loads(value)
    except ValueError:
        return None


class Library:
    def __init__(self, data_dir: Path):
        self.data_dir = Path(data_dir)
        self.stats_path = self.data_dir / "statistics.sqlite3"
        self.state_path = self.data_dir / "state.sqlite3"
        self.lock = threading.Lock()
        self.books: dict[str, Book] = {}
        self.by_md5: dict[str, Book] = {}
        self.collections: dict[str, Collection] = {}
        self.annotations: list[Annotation] = []
        self.daily: dict[date, int] = {}
        self.loaded_at: datetime | None = None
        self.counts: dict = {}

    # Connections ------------------------------------------------------------------

    def _connect(self, path: Path) -> sqlite3.Connection | None:
        if not path.exists():
            return None
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=10)
        return conn

    def stats(self) -> sqlite3.Connection | None:
        return self._connect(self.stats_path)

    # Loading ------------------------------------------------------------------------

    def reload(self) -> None:
        state = self._connect(self.state_path)
        stats = self.stats()
        if state is None or stats is None:
            return
        try:
            loaded = self._load(state, stats)
        finally:
            state.close()
            stats.close()
        with self.lock:
            (self.books, self.by_md5, self.collections, self.annotations, self.daily, self.counts) = loaded
            self.loaded_at = datetime.now()

    def _load(self, state: sqlite3.Connection, stats: sqlite3.Connection):
        editions: dict[str, Edition] = {}

        def edition(md5: str) -> Edition:
            e = editions.get(md5)
            if e is None:
                e = editions[md5] = Edition(md5)
            return e

        def name(md5: str, title, authors):
            e = edition(md5)
            if title and not e.title:
                e.title = title
            if authors and not e.authors:
                e.authors = authors

        # Titles, best source first: statistics (the newest row per MD5), then
        # what highlights, book data and identity records carried.
        for md5, title, authors, pages in stats.execute(
                "SELECT md5, title, authors, pages FROM book WHERE md5 IS NOT NULL ORDER BY last_open DESC"):
            name(md5, title, authors)
            if pages and edition(md5).pages is None:
                edition(md5).pages = pages
        for md5, title, authors in state.execute("SELECT md5, title, authors FROM ann_books"):
            name(md5, title, authors)
        for md5, title, authors in state.execute(
                "SELECT md5, title, authors FROM book_books WHERE md5 <> ?", (COLLECTIONS_MD5,)):
            name(md5, title, authors)
        for md5, title, authors in state.execute("SELECT md5, title, authors FROM id_facts"):
            name(md5, title, authors)

        # Reading totals per file.
        for md5, secs, pages, first, last in stats.execute("""
                SELECT b.md5, sum(p.duration), count(DISTINCT p.id_book || ':' || p.page),
                       min(p.start_time), max(p.start_time + p.duration)
                FROM page_stat_data p JOIN book b ON b.id = p.id_book
                WHERE b.md5 IS NOT NULL GROUP BY b.md5"""):
            e = edition(md5)
            e.read_time, e.pages_read, e.first_read, e.last_read = secs or 0, pages or 0, first, last
        # Progress: the furthest page read, as a share of the book.
        for md5, ratio in stats.execute("""
                SELECT b.md5, max(CAST(p.page AS REAL) / p.total_pages)
                FROM page_stat_data p JOIN book b ON b.id = p.id_book
                WHERE p.total_pages > 0 AND b.md5 IS NOT NULL GROUP BY b.md5"""):
            edition(md5).progress = min(ratio, 1.0) if ratio is not None else None

        # Book data, per file.
        props: dict[str, dict[str, Record]] = {}
        for md5, prop, updated, device, deleted, hsh, value in state.execute(
                "SELECT md5, prop, updated, device, deleted, hash, value FROM book_merged"):
            if md5 != COLLECTIONS_MD5:
                edition(md5)
            props.setdefault(md5, {})[prop] = Record(updated, device, bool(deleted), hsh, _decode(value))

        # Annotations, per file.
        annotations: list[Annotation] = []
        for md5, kind, key, updated, device, fields in state.execute(
                "SELECT md5, kind, key, updated, device, fields FROM ann_merged WHERE deleted = 0"):
            f = _decode(fields)
            if isinstance(f, dict):
                annotations.append(Annotation(md5, kind, key, updated, device, f))
                edition(md5).kinds.add(kind)

        # Identifiers the files carry (book identity), for finding covers.
        file_uuids: dict[str, set] = {}
        for uuid, md5 in state.execute("SELECT uuid, md5 FROM id_uuids"):
            file_uuids.setdefault(md5, set()).add(uuid.lower())
        file_ids: dict[str, set] = {}
        for md5, src, sig, device in state.execute("SELECT md5, src, sig, device FROM id_facts"):
            e = editions.get(md5)
            if e is not None:
                e.sources.add(src)
                e.reported_by.add(device)
                if sig and not e.sig:
                    e.sig = sig
        for md5, ids in state.execute("SELECT md5, ids FROM id_facts WHERE ids IS NOT NULL"):
            for ident in ids.split("\n"):
                scheme, _, value = ident.partition(":")
                if scheme.lower() == "calibre" and value.strip().isdigit():
                    file_ids.setdefault(md5, set()).add(int(value))

        # Groups: files the plugin joined as one book, then files without an
        # identity record by title.
        group_of: dict[str, str] = {}
        for md5, grp in state.execute("SELECT md5, grp FROM id_groups"):
            group_of[md5] = grp
        recorded = {md5 for (md5,) in state.execute("SELECT DISTINCT md5 FROM id_facts")}
        by_title = title_groups(group_of, recorded, list(stats.execute(
            "SELECT DISTINCT md5, title, authors FROM book WHERE md5 IS NOT NULL")))
        for md5 in by_title:
            if md5 in editions:
                editions[md5].by_title = True
        members: dict[str, list[str]] = {}
        for md5 in editions:
            members.setdefault(group_of.get(md5, md5), []).append(md5)

        books: dict[str, Book] = {}
        by_md5: dict[str, Book] = {}
        for md5s in members.values():
            md5s.sort()
            eds = sorted((editions[m] for m in md5s), key=lambda e: -e.read_time)
            merged: dict[str, Record] = {}
            for m in md5s:
                if m in by_title:
                    continue  # joined for statistics only
                for prop, rec in props.get(m, {}).items():
                    if not is_group_prop(prop):
                        continue
                    if rec.beats(merged.get(prop)):
                        merged[prop] = rec
            book = Book(id=md5s[0], editions=eds, props=merged)
            letters: dict[str, str] = {}
            for e in eds:  # the most-read file's text is A
                e.uuids = file_uuids.get(e.md5, set())
                if e.sig:
                    e.text = letters.setdefault(e.sig, chr(ord("A") + len(letters)))
            for e in eds:  # the most-read file's identifiers first
                book.uuids += sorted(file_uuids.get(e.md5, set()) - set(book.uuids))
                book.calibre_ids += sorted(file_ids.get(e.md5, set()) - set(book.calibre_ids))
            book.collections = sorted(p[5:] for p, r in merged.items() if p.startswith("coll.") and not r.deleted and r.value)
            books[book.id] = book
            for m in md5s:
                by_md5[m] = book

        for a in annotations:
            a.book = by_md5[a.md5]
            a.book.annotations.append(a)
        for b in books.values():
            b.annotations.sort(key=lambda a: (b.md5s.index(a.md5), a.kind, a.order))

        # Books with nothing to show (no title, readings, highlights or data)
        # are left out: an MD5 only named by an identity fact, say.
        for bid in [bid for bid, b in books.items()
                    if not b.read_time and not b.annotations and not b.props]:
            for m in books[bid].md5s:
                by_md5.pop(m, None)
            del books[bid]

        # Collections.
        collections: dict[str, Collection] = {}
        for prop, rec in props.get(COLLECTIONS_MD5, {}).items():
            if prop.startswith("coll.") and not rec.deleted and isinstance(rec.value, dict):
                cid = prop[5:]
                collections[cid] = Collection(cid, rec.value.get("name") or cid)
        for b in books.values():
            for cid in b.collections:
                if cid not in collections:
                    collections[cid] = Collection(cid, "Favorites" if cid == "favorites" else cid)
                collections[cid].books.append(b)
        for c in collections.values():
            c.books.sort(key=lambda b: b.title.casefold())

        daily = {}
        for day, secs in stats.execute("""
                SELECT date(start_time, 'unixepoch', 'localtime'), sum(duration)
                FROM page_stat_data GROUP BY 1"""):
            daily[date.fromisoformat(day)] = secs

        annotations.sort(key=lambda a: a.created or datetime.min, reverse=True)
        counts = {
            "books": len(books),
            "highlights": sum(1 for a in annotations if not a.is_bookmark),
            "notes": sum(1 for a in annotations if a.note and not a.is_bookmark),
            "bookmarks": sum(1 for a in annotations if a.is_bookmark),
            "readings": stats.execute("SELECT count(*) FROM page_stat_data").fetchone()[0],
            "files": len(editions),
            "versions": sum(1 for b in books.values() if len(b.editions) > 1),
        }
        return books, by_md5, collections, annotations, daily, counts

    # Queries ---------------------------------------------------------------------

    def snapshot(self):
        with self.lock:
            return self.books, self.by_md5, self.collections, self.annotations, self.daily, self.counts

    def sessions(self, md5s: list[str]) -> list[dict]:
        """Reading sessions of these files, newest first."""
        conn = self.stats()
        if conn is None or not md5s:
            return []
        try:
            marks = ",".join("?" * len(md5s))
            rows = conn.execute(f"""
                SELECT b.md5, p.page, p.start_time, p.duration, p.total_pages
                FROM page_stat_data p JOIN book b ON b.id = p.id_book
                WHERE b.md5 IN ({marks}) ORDER BY p.start_time""", md5s).fetchall()
        finally:
            conn.close()
        sessions: list[dict] = []
        cur = None
        for md5, page, start, dur, total in rows:
            if cur is None or start - cur["end"] > SESSION_GAP or md5 != cur["md5"]:
                cur = {"md5": md5, "start": start, "end": start + dur, "time": 0, "pages": set(),
                       "first": page, "last": page, "total": total}
                sessions.append(cur)
            cur["end"] = max(cur["end"], start + dur)
            cur["time"] += dur
            cur["pages"].add(page)
            cur["last"] = page
            cur["total"] = total or cur["total"]
        for s in sessions:
            s["pages"] = len(s["pages"])
        sessions.reverse()
        return sessions

    def daily_for(self, md5s: list[str]) -> dict[date, int]:
        conn = self.stats()
        if conn is None or not md5s:
            return {}
        try:
            marks = ",".join("?" * len(md5s))
            return {date.fromisoformat(d): s for d, s in conn.execute(f"""
                SELECT date(p.start_time, 'unixepoch', 'localtime'), sum(p.duration)
                FROM page_stat_data p JOIN book b ON b.id = p.id_book
                WHERE b.md5 IN ({marks}) GROUP BY 1""", md5s)}
        finally:
            conn.close()

    def daily_books(self, start: int, end: int) -> dict[date, dict[str, tuple[int, int]]]:
        """For readings starting in [start, end): {day: {md5: (seconds, pages)}}.
        Pages are the distinct pages of that file seen that day."""
        conn = self.stats()
        if conn is None:
            return {}
        out: dict[date, dict[str, tuple[int, int]]] = {}
        try:
            for day, md5, secs, pages in conn.execute("""
                    SELECT date(p.start_time, 'unixepoch', 'localtime'), b.md5, sum(p.duration),
                           count(DISTINCT p.page)
                    FROM page_stat_data p JOIN book b ON b.id = p.id_book
                    WHERE p.start_time >= ? AND p.start_time < ? AND b.md5 IS NOT NULL
                    GROUP BY 1, 2""", (start, end)):
                out.setdefault(date.fromisoformat(day), {})[md5] = (secs or 0, pages or 0)
        finally:
            conn.close()
        return out

    def period_stats(self, start: int, end: int) -> dict:
        """Totals for readings starting in [start, end): by book, hour and weekday."""
        conn = self.stats()
        if conn is None:
            return {"by_md5": {}, "hours": [0] * 24, "weekdays": [0] * 7}
        try:
            by_md5 = {m: (s, p) for m, s, p in conn.execute("""
                SELECT b.md5, sum(p.duration), count(DISTINCT p.id_book || ':' || p.page)
                FROM page_stat_data p JOIN book b ON b.id = p.id_book
                WHERE p.start_time >= ? AND p.start_time < ? GROUP BY b.md5""", (start, end))}
            hours = [0] * 24
            for h, s in conn.execute("""
                    SELECT CAST(strftime('%H', start_time, 'unixepoch', 'localtime') AS INTEGER), sum(duration)
                    FROM page_stat_data WHERE start_time >= ? AND start_time < ? GROUP BY 1""", (start, end)):
                hours[h] = s
            weekdays = [0] * 7  # Monday first
            for w, s in conn.execute("""
                    SELECT CAST(strftime('%w', start_time, 'unixepoch', 'localtime') AS INTEGER), sum(duration)
                    FROM page_stat_data WHERE start_time >= ? AND start_time < ? GROUP BY 1""", (start, end)):
                weekdays[(w + 6) % 7] = s
        finally:
            conn.close()
        return {"by_md5": by_md5, "hours": hours, "weekdays": weekdays}
