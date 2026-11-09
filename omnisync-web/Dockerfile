# OmniSync web. Build from the repository root, so the plugin's code is in the context:
#   docker build -f omnisync-web/Dockerfile -t omnisync-web .
# (compose.yaml in this folder does that.)

FROM python:3.13-slim-trixie

# LuaJIT and the libraries the plugin's code loads through FFI.
RUN apt-get update \
 && apt-get install -y --no-install-recommends luajit lua-filesystem libsqlite3-0 libzstd1 tzdata \
 && rm -rf /var/lib/apt/lists/*

# KOReader's own files, pinned to the commits the plugin is tested against
# (omnisync.koplugin/DESIGN.md): lua-ljsqlite3, its FFI headers, sha2 (for the
# same content hashes devices compute), and the statistics plugin (for its schema).
ARG KOREADER_BASE_REV=12807cac21c14533fef359ce7b64ed702f88a312
ARG KOREADER_REV=b166eb52be2e604adf20343d7c426c283307c378
ADD https://raw.githubusercontent.com/koreader/koreader-base/${KOREADER_BASE_REV}/ffi/posix_h.lua /opt/koreader-base/ffi/posix_h.lua
ADD https://raw.githubusercontent.com/koreader/koreader-base/${KOREADER_BASE_REV}/ffi/sqlite3_h.lua /opt/koreader-base/ffi/sqlite3_h.lua
ADD https://raw.githubusercontent.com/koreader/koreader-base/${KOREADER_BASE_REV}/ffi/zstd_h.lua /opt/koreader-base/ffi/zstd_h.lua
ADD https://raw.githubusercontent.com/koreader/koreader-base/${KOREADER_BASE_REV}/ffi/sha2.lua /opt/koreader-base/ffi/sha2.lua
ADD https://raw.githubusercontent.com/koreader/koreader-base/${KOREADER_BASE_REV}/thirdparty/lua-ljsqlite3/init.lua /opt/koreader-base/thirdparty/lua-ljsqlite3/init.lua
ADD https://raw.githubusercontent.com/koreader/koreader/${KOREADER_REV}/plugins/statistics.koplugin/main.lua /opt/koreader/statistics.koplugin/main.lua

WORKDIR /opt/omnisync-web
COPY omnisync-web/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# The plugin's own modules: the ingester merges with exactly this code.
COPY omnisync.koplugin/omnisync /opt/omnisync/omnisync
COPY omnisync-web/ingest ./ingest
COPY omnisync-web/app ./app

RUN chmod -R a+rX /opt/koreader-base /opt/koreader /opt/omnisync \
 && useradd --system --uid 1000 --home-dir /cache omnisync \
 && mkdir -p /cache && chown omnisync /cache

ENV OMNISYNC_LIB=/opt/omnisync \
    KOREADER_BASE=/opt/koreader-base \
    KOREADER_STATS=/opt/koreader/statistics.koplugin/main.lua \
    OMNISYNC_READING_DIR=/data/reading \
    OMNISYNC_DATA_DIR=/cache \
    SYNC_INTERVAL=60 \
    PYTHONUNBUFFERED=1

USER omnisync
VOLUME /cache
EXPOSE 8080
HEALTHCHECK --interval=60s --timeout=5s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=4)"
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers", "--forwarded-allow-ips", "*"]
