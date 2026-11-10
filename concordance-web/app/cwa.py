"""Book covers from a Calibre-Web Automated (or Calibre-Web) server.

Matching: Concordance's book identity records each file's UUIDs, which include
the Calibre library UUID, and that UUID is the <id> of the book's OPDS entry.
So the catalog ("all books", /opds/books/letter/00, page by page) is read
once a day into a UUID -> cover link map. Files that carry a calibre:<id>
identifier match by ID as well.

Covers are fetched by the app (the browser never sees the CWA login), kept
in <data dir>/covers/, and checked again with If-None-Match after a week.

Book descriptions (Calibre's comments) are kept from the catalog too.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from html import unescape
from pathlib import Path

from .settings import Settings

log = logging.getLogger("concordance-web")

ATOM = "{http://www.w3.org/2005/Atom}"
ACQUISITION = "http://opds-spec.org/acquisition"
IMAGE = "http://opds-spec.org/image"
THUMBNAIL = "http://opds-spec.org/image/thumbnail"
CATALOG_AGE = 24 * 3600   # read the catalog again after this
COVER_AGE = 7 * 24 * 3600  # check a kept cover again after this
MAX_PAGES = 2000
MAX_COVER = 10 * 1024 * 1024
TIMEOUT = 30
USER_AGENT = "concordance-web"
CATALOG_VERSION = 2  # 2: with descriptions
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


# Line breaks and paragraph ends (perhaps with a namespace prefix, from inline XHTML).
_BREAK_RE = re.compile(r"<\s*(?:(?:\w+:)?br|/(?:\w+:)?(?:p|div|li|h[1-6]|blockquote))\b[^>]*>", re.I)
_TAG_RE = re.compile(r"<[^>]*>")


def plain_text(html: str) -> str:
    """Text of a description that may be HTML: tags dropped, one blank line between paragraphs."""
    if not html:
        return ""
    text = _TAG_RE.sub("", _BREAK_RE.sub("\n", html)) if "<" in html else html
    text = unescape(text)
    paras = [" ".join(p.split()) for p in re.split(r"\n\s*\n|\n", text)]
    return "\n\n".join(p for p in paras if p)


class CWAError(Exception):
    pass


def normalize_uuid(s: str) -> str | None:
    s = (s or "").strip().lower()
    s = s.removeprefix("urn:").removeprefix("uuid:")
    return s if UUID_RE.match(s) else None


def image_type(data: bytes) -> str | None:
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    return None


class CWA:
    def __init__(self, settings: Settings, data_dir: Path):
        self.settings = settings
        self.dir = Path(data_dir) / "covers"
        self.catalog_path = Path(data_dir) / "cwa_catalog.json"
        self.lock = threading.Lock()
        self.crawl_lock = threading.Lock()
        self.fetch_locks: dict[str, threading.Lock] = {}
        self.by_uuid: dict[str, str] = {}   # Calibre UUID -> cover href (absolute)
        self.by_id: dict[int, str] = {}     # Calibre book ID -> cover href
        self.descs: dict[str, str] = {}     # Calibre UUID (or "id:<n>") -> description
        self.desc_ids: dict[int, str] = {}  # Calibre book ID -> key in descs
        self.version = 0                    # of the saved catalog
        self.catalog_url = ""               # the server the catalog was read from
        self.read_at: float | None = None
        self.books = 0
        self.last_error = ""
        self.crawling = False
        self._load_catalog()

    # Settings ------------------------------------------------------------------------

    @property
    def url(self) -> str:
        return self.settings.get("cwa_url").strip()

    @property
    def configured(self) -> bool:
        return bool(self.url)

    def _auth_header(self) -> str | None:
        user = self.settings.get("cwa_username")
        if not user:
            return None
        token = f"{user}:{self.settings.get('cwa_password')}".encode()
        return "Basic " + base64.b64encode(token).decode()

    def _request(self, url: str, headers: dict | None = None) -> urllib.request.Request:
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, **(headers or {})})
        auth = self._auth_header()
        # Only send the login to the configured server (feeds could link elsewhere).
        if auth and urllib.parse.urlsplit(url).netloc == urllib.parse.urlsplit(self.url).netloc:
            req.add_header("Authorization", auth)
        return req

    def _get(self, url: str, headers: dict | None = None, limit: int = 20 * 1024 * 1024):
        """(status, headers, body). Raises CWAError with a readable reason."""
        try:
            with urllib.request.urlopen(self._request(url, headers), timeout=TIMEOUT) as resp:
                body = resp.read(limit + 1)
                if len(body) > limit:
                    raise CWAError(f"{url}: response too large")
                return resp.status, resp.headers, body
        except urllib.error.HTTPError as e:
            if e.code == 304:
                return 304, e.headers, b""
            if e.code == 401:
                raise CWAError("The server refused the username or password (401).") from None
            raise CWAError(f"{url}: HTTP {e.code} {e.reason}") from None
        except urllib.error.URLError as e:
            raise CWAError(f"Can't reach {urllib.parse.urlsplit(url).netloc}: {e.reason}") from None
        except (TimeoutError, OSError) as e:
            raise CWAError(f"Can't reach {urllib.parse.urlsplit(url).netloc}: {e}") from None

    # Catalog -------------------------------------------------------------------------

    def _feed(self, url: str) -> ET.Element:
        _, _, body = self._get(url, {"Accept": "application/atom+xml"})
        try:
            root = ET.fromstring(body)
        except ET.ParseError:
            raise CWAError(f"{url} isn't an OPDS feed. Use the server's OPDS address, e.g. https://books.example.com/opds") from None
        if root.tag != ATOM + "feed":
            raise CWAError(f"{url} isn't an OPDS feed.")
        return root

    @staticmethod
    def _links(el: ET.Element):
        for link in el.findall(ATOM + "link"):
            yield link.get("rel") or "", link.get("href") or "", link.get("type") or ""

    def _section(self, feed: ET.Element, base: str, suffix: str) -> str | None:
        for entry in feed.findall(ATOM + "entry"):
            for _, href, _ in self._links(entry):
                path = urllib.parse.urlsplit(href).path.rstrip("/")
                if path.endswith(suffix):
                    return urllib.parse.urljoin(base, href)
        return None

    def _root(self) -> tuple[str, ET.Element]:
        url = self.url.rstrip("/")
        try:
            return url, self._feed(url)
        except CWAError:
            # A server address without /opds: try with it.
            if not url.endswith("/opds"):
                try:
                    return url + "/opds", self._feed(url + "/opds")
                except CWAError:
                    pass
            raise

    def test(self) -> str:
        """Checks the address and login. Returns a summary, or raises CWAError."""
        url, root = self._root()
        if not self._section(root, url, "/books"):
            raise CWAError("That's an OPDS catalog, but not a Calibre-Web one (no \"Alphabetical Books\").")
        title = root.findtext(ATOM + "title") or "OPDS catalog"
        return f"Connected to {title.strip()} at {url}."

    def refresh_catalog(self) -> None:
        """Reads the whole catalog (blocking). Errors are kept in last_error."""
        if not self.configured:
            return
        if not self.crawl_lock.acquire(blocking=False):
            return
        self.crawling = True
        try:
            by_uuid, by_id, descs, desc_ids, count = self._crawl()
            with self.lock:
                self.by_uuid, self.by_id, self.books = by_uuid, by_id, count
                self.descs, self.desc_ids, self.version = descs, desc_ids, CATALOG_VERSION
                self.catalog_url = self.url
                self.read_at = time.time()
                self.last_error = ""
            self._save_catalog()
            log.info("CWA catalog: %d books, %d with covers, %d with descriptions", count, len(by_uuid), len(descs))
        except CWAError as e:
            self.last_error = str(e)
            log.warning("CWA catalog: %s", e)
        except Exception as e:  # a bug here mustn't take the app down
            self.last_error = f"Reading the catalog failed: {e}"
            log.exception("CWA catalog")
        finally:
            self.crawling = False
            self.crawl_lock.release()

    def _crawl(self):
        root_url, root = self._root()
        books_url = self._section(root, root_url, "/books")
        if not books_url:
            raise CWAError("No \"Alphabetical Books\" section: is this a Calibre-Web server?")
        index = self._feed(books_url)
        url = self._section(index, books_url, "/letter/00")
        if not url:
            raise CWAError("No \"All\" entry in the catalog's alphabetical index.")
        by_uuid: dict[str, str] = {}
        by_id: dict[int, str] = {}
        descs: dict[str, str] = {}
        desc_ids: dict[int, str] = {}
        count = 0
        seen_pages = set()
        for _ in range(MAX_PAGES):
            if url in seen_pages:
                break
            seen_pages.add(url)
            feed = self._feed(url)
            for entry in feed.findall(ATOM + "entry"):
                cover = thumb = None
                calibre_id = None
                is_book = False
                for rel, href, _ in self._links(entry):
                    if rel == THUMBNAIL:
                        thumb = href
                    elif rel == IMAGE:
                        cover = href
                    elif rel.startswith(ACQUISITION):
                        is_book = True
                        m = re.search(r"/download/(\d+)/", href)
                        calibre_id = calibre_id or (int(m.group(1)) if m else None)
                if not is_book:
                    continue
                count += 1
                uuid = normalize_uuid(entry.findtext(ATOM + "id") or "")
                desc = self._description(entry)
                if desc and (uuid or calibre_id is not None):
                    key = uuid or f"id:{calibre_id}"
                    descs[key] = desc
                    if calibre_id is not None:
                        desc_ids[calibre_id] = key
                href = cover or thumb  # the full image: the thumbnail is small
                if not href:
                    continue
                href = urllib.parse.urljoin(url, href)
                if uuid:
                    by_uuid[uuid] = href
                if calibre_id is not None:
                    by_id[calibre_id] = href
            nxt = next((h for r, h, _ in self._links(feed) if r == "next"), None)
            if not nxt:
                break
            url = urllib.parse.urljoin(url, nxt)
        return by_uuid, by_id, descs, desc_ids, count

    @staticmethod
    def _description(entry: ET.Element) -> str:
        """The entry's description: <content> or <summary>, as text or (X)HTML."""
        for tag in ("content", "summary"):
            el = entry.find(ATOM + tag)
            if el is None:
                continue
            if len(el):  # inline XHTML: serialize the children so paragraphs survive
                html = "".join(ET.tostring(c, encoding="unicode") for c in el)
            else:
                html = el.text or ""
            text = plain_text(html)
            if text:
                return text
        return ""

    def _save_catalog(self) -> None:
        with self.lock:
            data = {"version": self.version, "url": self.catalog_url, "read_at": self.read_at,
                    "books": self.books, "by_uuid": self.by_uuid,
                    "by_id": {str(k): v for k, v in self.by_id.items()},
                    "descs": self.descs, "desc_ids": {str(k): v for k, v in self.desc_ids.items()}}
        tmp = self.catalog_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data))
        tmp.replace(self.catalog_path)

    def _load_catalog(self) -> None:
        try:
            data = json.loads(self.catalog_path.read_text())
            self.catalog_url = data.get("url", "")
            self.read_at = data.get("read_at")
            self.books = data.get("books", 0)
            self.by_uuid = dict(data.get("by_uuid", {}))
            self.by_id = {int(k): v for k, v in data.get("by_id", {}).items()}
            self.descs = dict(data.get("descs", {}))
            self.desc_ids = {int(k): v for k, v in data.get("desc_ids", {}).items()}
            self.version = data.get("version", 1)
        except (OSError, ValueError, AttributeError):
            pass

    def catalog_due(self) -> bool:
        if not self.configured:
            return False
        if self.catalog_url != self.url or not self.read_at or self.version < CATALOG_VERSION:
            return True
        return time.time() - self.read_at > CATALOG_AGE

    def forget(self) -> None:
        """Drops the catalog and kept covers (the server changed or was removed)."""
        with self.lock:
            self.by_uuid, self.by_id, self.books = {}, {}, 0
            self.descs, self.desc_ids, self.version = {}, {}, 0
            self.catalog_url, self.read_at, self.last_error = "", None, ""
        self.catalog_path.unlink(missing_ok=True)
        if self.dir.exists():
            for f in self.dir.iterdir():
                f.unlink(missing_ok=True)

    # Covers --------------------------------------------------------------------------

    def cover_href(self, uuids, calibre_ids) -> str | None:
        if not self.configured or self.catalog_url != self.url:
            return None
        with self.lock:
            for u in uuids:
                href = self.by_uuid.get(u)
                if href:
                    return href
            for i in calibre_ids:
                href = self.by_id.get(i)
                if href:
                    return href
        return None

    def description(self, uuids, calibre_ids) -> str:
        if not self.configured or self.catalog_url != self.url:
            return ""
        with self.lock:
            for u in uuids:
                if u in self.descs:
                    return self.descs[u]
            for i in calibre_ids:
                key = self.desc_ids.get(i)
                if key in self.descs:
                    return self.descs[key]
        return ""

    def matched(self, books) -> int:
        return sum(1 for b in books if self.cover_href(b.uuids, b.calibre_ids))

    def cover(self, href: str) -> tuple[bytes, str] | None:
        """The image at href (from the cache, fetched or checked as needed), or None."""
        key = hashlib.sha256(href.encode()).hexdigest()[:32]
        body_path, meta_path = self.dir / key, self.dir / f"{key}.json"
        with self.lock:
            flock = self.fetch_locks.setdefault(key, threading.Lock())
        with flock:
            meta = {}
            try:
                meta = json.loads(meta_path.read_text())
            except (OSError, ValueError):
                pass
            have = body_path.exists() and meta.get("type")
            if have and time.time() - meta.get("checked", 0) < COVER_AGE:
                return body_path.read_bytes(), meta["type"]
            headers = {"Accept": "image/*"}
            if have and meta.get("etag"):
                headers["If-None-Match"] = meta["etag"]
            if have and meta.get("modified"):
                headers["If-Modified-Since"] = meta["modified"]
            try:
                status, resp_headers, body = self._get(href, headers, limit=MAX_COVER)
            except CWAError as e:
                log.info("cover %s: %s", href, e)
                return (body_path.read_bytes(), meta["type"]) if have else None
            if status == 304 and have:
                meta["checked"] = time.time()
            else:
                ctype = image_type(body)
                if not ctype:
                    return (body_path.read_bytes(), meta["type"]) if have else None
                self.dir.mkdir(parents=True, exist_ok=True)
                tmp = body_path.with_suffix(".part")
                tmp.write_bytes(body)
                tmp.replace(body_path)
                meta = {"type": ctype, "checked": time.time(), "href": href,
                        "etag": resp_headers.get("ETag"), "modified": resp_headers.get("Last-Modified")}
            meta_path.write_text(json.dumps(meta))
            return body_path.read_bytes(), meta["type"]
