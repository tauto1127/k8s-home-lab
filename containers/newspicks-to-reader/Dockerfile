# syntax=docker/dockerfile:1
FROM python:3.12-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    NP2R_PROFILE=/data/profile

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Playwright（Chromium）と OS 依存をまとめて入れる。
# `playwright install --with-deps` は PATH 上の python を要求するため、
# 明示的に venv の python を PATH の先頭に置く。
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
RUN pip install --no-cache-dir playwright && \
    python -m playwright install --with-deps chromium && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY np2reader.py fulltext.py ingest_server.py ./

RUN useradd -u 1000 -m np2r && mkdir -p /data/profile && chown -R 1000:1000 /data
USER 1000

EXPOSE 8787 8790
CMD ["python", "ingest_server.py"]
