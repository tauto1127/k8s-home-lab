# syntax=docker/dockerfile:1
FROM python:3.12-slim-bookworm

# Playwright のブラウザを /root/.cache に置くと、実行ユーザー 1000 から
# 読めない（/root が 0700）ため、全ユーザーが読める共有パスに固定する。
ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    NP2R_PROFILE=/data/profile \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

# libatomic1 は playwright 同梱の node ドライバが要求する（slim イメージには入っていない）。
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl libatomic1 xvfb xauth \
    && rm -rf /var/lib/apt/lists/*

# Playwright（Chromium）と OS 依存をまとめて入れる。
# 公式 python イメージには venv が無い（ensurepip が無効化されている）ため venv は作らない。
# install-deps は apt を実行するので root のまま先に入れる。
RUN pip install --no-cache-dir playwright && \
    python -m playwright install-deps chromium && \
    python -m playwright install chromium && \
    rm -rf /var/lib/apt/lists/*

# このコンテナの Chromium は X が無いと起動できない（headless 指定でも同じ）。
# fulltext は xvfb-run 配下で起動する前提なので、Xvfb を入れておく。
WORKDIR /app
COPY np2reader.py fulltext.py ingest_server.py ./

RUN useradd -u 1000 -m np2r && mkdir -p /data/profile && chown -R 1000:1000 /data
USER 1000

EXPOSE 8787 8790
CMD ["python", "ingest_server.py"]
