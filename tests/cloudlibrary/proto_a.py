"""Prototype A: what does syncing a Calibre-Web Automated catalog cost?

Read-only: fetches catalog feeds, a few JSON book records and a few covers.
Never downloads books. Credentials come from the environment:

    CL_URL=https://example.org CL_USER=me CL_PASS=secret \
        python3 tests/cloudlibrary/proto_a.py --out /tmp/proto-a

Writes report.json (timings, sizes, data checks) and catalog.json (the
parsed catalog) to --out. catalog.json holds your library's metadata, so
keep --out outside the repo.
"""

from __future__ import annotations

import argparse
import base64
import collections
import gzip
import io
import json
import os
import re
import statistics
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

NS = {
    "a": "http://www.w3.org/2005/Atom",
    "dc": "http://purl.org/dc/terms/",
    "os": "http://a9.com/-/spec/opensearch/1.1/",
}
ACQ = "http://opds-spec.org/acquisition"
IMG = "http://opds-spec.org/image"
THUMB = "http://opds-spec.org/image/thumbnail"


class Client:
    def __init__(self, base: str, user: str, password: str, gzip_ok: bool = True):
        self.base = base.rstrip("/")
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        self.headers = {"Authorization": "Basic " + token, "User-Agent": "KOReader cloudlibrary proto"}
        if gzip_ok:
            self.headers["Accept-Encoding"] = "gzip"
        self.log: list[dict] = []

    def get(self, path: str, extra: dict | None = None) -> tuple[int, dict, bytes, dict]:
        url = path if path.startswith("http") else self.base + path
        request = urllib.request.Request(url, headers={**self.headers, **(extra or {})})
        started = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                status, headers, body = response.status, dict(response.headers), response.read()
        except urllib.error.HTTPError as exc:
            status, headers, body = exc.code, dict(exc.headers), exc.read()
        elapsed = time.monotonic() - started
        wire = len(body)
        if headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        entry = {"path": path, "status": status, "seconds": round(elapsed, 3), "wire_bytes": wire,
                 "bytes": len(body)}
        self.log.append(entry)
        return status, headers, body, entry


def parse_feed(body: bytes) -> tuple[list[dict], str | None]:
    root = ET.fromstring(body)
    next_href = None
    for link in root.findall("a:link", NS):
        if link.get("rel") == "next":
            next_href = link.get("href")
    books = []
    for entry in root.findall("a:entry", NS):
        book: dict = {
            "uuid": (entry.findtext("a:id", "", NS) or "").removeprefix("urn:uuid:"),
            "title": entry.findtext("a:title", "", NS),
            "updated": entry.findtext("a:updated", "", NS),
            "published": entry.findtext("a:published", "", NS),
            "authors": [a.findtext("a:name", "", NS) for a in entry.findall("a:author", NS)],
            "languages": [l.text for l in entry.findall("dc:language", NS)],
            "summary": entry.findtext("a:summary", None, NS),
            "tags": [], "custom": {}, "formats": [], "cover": None,
        }
        publisher = entry.find("a:publisher", NS)
        if publisher is not None:
            book["publisher"] = publisher.findtext("a:name", "", NS)
        for cat in entry.findall("a:category", NS):
            scheme = cat.get("scheme") or ""
            if scheme.startswith("custom_column:"):
                book["custom"][cat.get("term")] = cat.get("label")
            else:
                book["tags"].append(cat.get("term"))
        for link in entry.findall("a:link", NS):
            rel, href = link.get("rel"), link.get("href")
            if rel == ACQ:
                book["formats"].append({"type": link.get("type"), "href": href,
                                        "size": int(link.get("length") or 0)})
                m = re.search(r"/opds/download/(\d+)/", href or "")
                if m:
                    book["calibre_id"] = int(m.group(1))
            elif rel in (IMG, THUMB):
                book["cover"] = href
        if book["formats"] or book["uuid"]:
            books.append(book)
    return books, next_href


def crawl(client: Client, start: str, limit_pages: int | None = None) -> tuple[list[dict], list[dict]]:
    books, pages, href = [], [], start
    while href and (limit_pages is None or len(pages) < limit_pages):
        status, _headers, body, entry = client.get(href)
        if status != 200:
            entry["error"] = body[:200].decode(errors="replace")
            pages.append(entry)
            break
        page_books, href = parse_feed(body)
        entry["entries"] = len(page_books)
        pages.append(entry)
        books.extend(page_books)
    return books, pages


def summarise(pages: list[dict]) -> dict:
    secs = [p["seconds"] for p in pages]
    return {
        "requests": len(pages),
        "total_seconds": round(sum(secs), 2),
        "median_page_seconds": round(statistics.median(secs), 3) if secs else None,
        "max_page_seconds": max(secs) if secs else None,
        "wire_bytes": sum(p["wire_bytes"] for p in pages),
        "bytes": sum(p["bytes"] for p in pages),
    }


def series_crawl(client: Client) -> tuple[dict, dict]:
    """Walk /opds/series: letter index -> series list -> books in each series."""
    requests_before = len(client.log)
    started = time.monotonic()
    membership: dict[str, dict] = {}

    def subsections(path: str) -> list[tuple[str, str]]:
        out, href = [], path
        while href:
            status, _h, body, _e = client.get(href)
            if status != 200:
                break
            root = ET.fromstring(body)
            for entry in root.findall("a:entry", NS):
                for link in entry.findall("a:link", NS):
                    if link.get("rel") == "subsection":
                        out.append((entry.findtext("a:title", "", NS), link.get("href")))
            href = next((l.get("href") for l in root.findall("a:link", NS) if l.get("rel") == "next"),
                        None)
        return out

    letters = subsections("/opds/series")
    series_links = []
    for _letter, href in letters:
        series_links.extend(subsections(href))
    for name, href in series_links:
        books, _pages = crawl(client, href)
        for position, book in enumerate(books, start=1):
            membership[book["uuid"]] = {"series": name, "position": position}
    return membership, {
        "letters": len(letters), "series": len(series_links),
        "requests": len(client.log) - requests_before,
        "seconds": round(time.monotonic() - started, 2),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--skip-series", action="store_true")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    client = Client(os.environ["CL_URL"], os.environ["CL_USER"], os.environ["CL_PASS"])
    report: dict = {}

    _s, _h, body, entry = client.get("/opds/stats")
    report["stats"] = {"result": json.loads(body), "seconds": entry["seconds"]}

    # Full list, as a full sync would do it.
    started = time.monotonic()
    books, pages = crawl(client, "/opds/books/letter/00")
    report["full_list"] = summarise(pages)
    report["full_list"]["wall_seconds"] = round(time.monotonic() - started, 2)
    report["full_list"]["entries"] = len(books)
    report["full_list"]["page_size"] = pages[0].get("entries") if pages else None

    # Same first page without gzip, and caching headers.
    _s, headers, _b, plain = Client(os.environ["CL_URL"], os.environ["CL_USER"],
                                    os.environ["CL_PASS"], gzip_ok=False).get("/opds/books/letter/00")
    report["compression"] = {
        "gzip_wire_bytes_page1": pages[0]["wire_bytes"] if pages else None,
        "plain_wire_bytes_page1": plain["wire_bytes"],
        "content_encoding_offered": headers.get("Content-Encoding"),
    }
    report["caching_headers"] = {k: headers.get(k) for k in
                                 ("ETag", "Last-Modified", "Cache-Control", "Expires")}
    if headers.get("ETag"):
        status, _h, _b, _e = client.get("/opds/books/letter/00",
                                        {"If-None-Match": headers["ETag"]})
        report["caching_headers"]["conditional_status"] = status

    # New-books catch-up: first page of /opds/new, newest first.
    newest, new_pages = crawl(client, "/opds/new", limit_pages=1)
    report["new_feed_page1"] = summarise(new_pages)
    report["new_feed_page1"]["newest_updated"] = [b["updated"] for b in newest[:3]]
    report["new_feed_page1"]["sorted_by_updated_desc"] = (
        [b["updated"] for b in newest] == sorted((b["updated"] for b in newest), reverse=True))

    # Data checks.
    uuids = collections.Counter(b["uuid"] for b in books)
    fmt = collections.Counter(f["type"] for b in books for f in b["formats"])
    report["data"] = {
        "unique_uuids": len(uuids),
        "duplicate_uuids": [u for u, n in uuids.items() if n > 1][:10],
        "stats_vs_crawled": report["stats"]["result"].get("books", 0) - len(uuids),
        "formats": dict(fmt),
        "books_without_epub": sum(1 for b in books if not any(
            "epub" in (f["type"] or "") for f in b["formats"])),
        "books_without_formats": sum(1 for b in books if not b["formats"]),
        "books_without_cover": sum(1 for b in books if not b["cover"]),
        "books_with_summary": sum(1 for b in books if b["summary"]),
        "median_summary_chars": statistics.median([len(b["summary"]) for b in books if b["summary"]]
                                                  or [0]),
        "placeholder_published": sum(1 for b in books if b["published"].startswith("101-")),
        "custom_columns": dict(collections.Counter(k for b in books for k in b["custom"])),
        "languages": dict(collections.Counter(l for b in books for l in b["languages"])),
        "tags": len({t for b in books for t in b["tags"]}),
        "multi_author_books": sum(1 for b in books if len(b["authors"]) > 1),
    }

    # Series.
    if not args.skip_series:
        membership, report["series_crawl"] = series_crawl(client)
        report["series_crawl"]["books_in_series"] = len(membership)
        for b in books:
            if b["uuid"] in membership:
                b["series"] = membership[b["uuid"]]["series"]
                b["series_position"] = membership[b["uuid"]]["position"]

    # JSON book records: series_index and last_modified, a few samples.
    samples = [b for b in books if b.get("series")][:5] or books[:5]
    ajax = []
    for b in samples:
        status, headers, body, entry = client.get(f"/ajax/book/{b['uuid']}")
        record = {"status": status, "seconds": entry["seconds"],
                  "content_type": headers.get("Content-Type")}
        try:
            data = json.loads(body) if status == 200 and body.strip() else None
        except ValueError:
            data = None
            record["not_json"] = body[:80].decode(errors="replace")
        if isinstance(data, dict):
            record.update({k: data.get(k) for k in ("series", "series_index", "last_modified",
                                                     "timestamp")})
            record["series_position_from_feed"] = b.get("series_position")
        ajax.append(record)
    report["ajax_book_samples"] = ajax

    # Covers: a few samples, sizes and image dimensions.
    covers = []
    for b in [b for b in books if b["cover"]][:: max(1, len(books) // 10)][:10]:
        status, headers, body, entry = client.get(b["cover"])
        info = {"status": status, "seconds": entry["seconds"], "bytes": entry["bytes"],
                "type": headers.get("Content-Type"), "cache": headers.get("Cache-Control"),
                "etag": bool(headers.get("ETag"))}
        try:
            from PIL import Image
            with Image.open(io.BytesIO(body)) as image:
                info["size"] = image.size
        except Exception as exc:  # noqa: BLE001
            info["size_error"] = repr(exc)
        covers.append(info)
    report["cover_samples"] = covers
    report["cover_estimate"] = {
        "median_bytes": statistics.median([c["bytes"] for c in covers]) if covers else None,
        "median_seconds": statistics.median([c["seconds"] for c in covers]) if covers else None,
    }
    report["total_requests"] = len(client.log)

    with open(os.path.join(args.out, "report.json"), "w") as fh:
        json.dump(report, fh, indent=2)
    with open(os.path.join(args.out, "catalog.json"), "w") as fh:
        json.dump(books, fh)
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
