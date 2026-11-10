"""A stand-in for a Calibre-Web Automated server's OPDS catalog, for testing covers.

    python3 tests/fake_cwa.py [port]      (default 8790; login reader / secret)

Serves /opds, /opds/books, /opds/books/letter/00 (two pages, with a "next"
link) and /opds/cover/<id> (PNG, with ETags), for the books in
make_fixture.lua that have UUIDs, plus books this library doesn't have.
"""

import base64
import struct
import sys
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

USER, PASSWORD = "reader", "secret"
BOOKS = [  # (calibre id, uuid, title, rgb)
    (11, "1a2b3c4d-0000-4000-8000-000000000001", "Pride and Prejudice", (150, 60, 50)),
    (12, "1a2b3c4d-0000-4000-8000-000000000002", "Moby-Dick", (30, 70, 120)),
    (13, "1a2b3c4d-0000-4000-8000-000000000003", "Frankenstein", (40, 90, 50)),
    (14, "9f9f9f9f-0000-4000-8000-000000000099", "A book not read here", (90, 90, 90)),
]
PAGE = 2


def png(rgb, w=120, h=180):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def feed(title, entries, next_href=None):
    nxt = f'<link rel="next" href="{next_href}" type="application/atom+xml;profile=opds-catalog"/>' if next_href else ""
    return (f'<?xml version="1.0" encoding="UTF-8"?><feed xmlns="http://www.w3.org/2005/Atom">'
            f"<id>urn:uuid:feed</id><title>{title}</title>{nxt}{''.join(entries)}</feed>").encode()


def nav(title, href):
    return (f"<entry><title>{title}</title><id>{href}</id>"
            f'<link rel="subsection" href="{href}" type="application/atom+xml;profile=opds-catalog"/></entry>')


def book(cid, uuid, title):
    return (f"<entry><title>{title}</title><id>urn:uuid:{uuid}</id>"
            f'<link rel="http://opds-spec.org/image" href="/opds/cover/{cid}" type="image/png"/>'
            f'<link rel="http://opds-spec.org/image/thumbnail" href="/opds/cover/{cid}" type="image/png"/>'
            f'<link rel="http://opds-spec.org/acquisition" href="/opds/download/{cid}/epub/" type="application/epub+zip"/>'
            f"</entry>")


class Handler(BaseHTTPRequestHandler):
    hits = []

    def log_message(self, *args):
        pass

    def send(self, code, body=b"", ctype="application/atom+xml", headers=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        Handler.hits.append(self.path)
        expected = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
        if self.headers.get("Authorization") != expected:
            return self.send(401, b"login", "text/plain", {"WWW-Authenticate": 'Basic realm="cwa"'})
        path, _, query = self.path.partition("?")
        if path == "/opds":
            return self.send(200, feed("Calibre-Web", [nav("Alphabetical Books", "/opds/books"), nav("New", "/opds/new")]))
        if path == "/opds/books":
            return self.send(200, feed("Books", [nav("All", "/opds/books/letter/00"), nav("A", "/opds/books/letter/a")]))
        if path == "/opds/books/letter/00":
            offset = int(query.partition("offset=")[2] or 0) if "offset=" in query else 0
            page = BOOKS[offset:offset + PAGE]
            nxt = f"/opds/books/letter/00?offset={offset + PAGE}" if offset + PAGE < len(BOOKS) else None
            return self.send(200, feed("All", [book(c, u, t) for c, u, t, _ in page], nxt))
        if path.startswith("/opds/cover/"):
            cid = int(path.rsplit("/", 1)[1])
            for c, _, _, rgb in BOOKS:
                if c == cid:
                    etag = f'"cover-{cid}"'
                    if self.headers.get("If-None-Match") == etag:
                        return self.send(304, headers={"ETag": etag})
                    return self.send(200, png(rgb), "image/png", {"ETag": etag})
        self.send(404, b"not found", "text/plain")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8790
    print(f"fake CWA on http://127.0.0.1:{port}/opds", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
