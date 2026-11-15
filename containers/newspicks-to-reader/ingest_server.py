#!/usr/bin/env python3
"""
ingest_server.py — 自宅サーバーの受け口。Worker（または iOS ショートカット）から叩かれる。

  POST /ingest  {"path": "save", "url": "https://newspicks.com/news/17906125/"}
  POST /ingest  {"path": "newsletter", "n": 1}
  GET  /health
  GET  /login/status            （fulltext のログイン状態を中継）
  POST /login/submit            （1Password から受け取った email/password or cookies を中継）

中身は np2reader.py のサブプロセス呼び出しだけ。Readwise トークンと NewsPicks の
ログインはこのプロセスの環境変数にだけ置く（Worker 側には置かない）。

環境変数:
  NP2R_HOME_TOKEN   必須。Worker と共有する認証トークン
  NP2R_SCRIPT       np2reader.py のパス（既定: このファイルと同じディレクトリ）
  READWISE_TOKEN / NP2R_FULLTEXT_ENDPOINT / NP2R_FULLTEXT_TOKEN / NP2R_LOCATION / NP2R_TAGS
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = os.environ.get("NP2R_SCRIPT", str(HERE / "np2reader.py"))
TOKEN = os.environ.get("NP2R_HOME_TOKEN", "")
NEWS_ID = re.compile(r"newspicks\.com/(?:news|news-in-app)/(\d+)")
FULLTEXT = os.environ.get("NP2R_FULLTEXT_ENDPOINT", "")
FULLTEXT_TOKEN = os.environ.get("NP2R_FULLTEXT_TOKEN", "")


def fulltext_call(method: str, path: str, payload: dict | None = None, timeout: int = 60) -> tuple[int, dict]:
    """fulltext コンテナの管理 API を中継する。"""
    base = FULLTEXT.rsplit("/fetch", 1)[0]
    req = urllib.request.Request(
        base + path,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={"Content-Type": "application/json", **({"x-np2reader-token": FULLTEXT_TOKEN} if FULLTEXT_TOKEN else {})},
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            return res.status, json.loads(res.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode() or "{}")
        except json.JSONDecodeError:
            return e.code, {"ok": False, "error": f"upstream {e.code}"}
    except (urllib.error.URLError, TimeoutError) as e:
        return 502, {"ok": False, "error": f"fulltext unreachable: {e}"}


def run(cmd: list[str], timeout: int = 600) -> tuple[int, str, str]:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=os.environ.copy())
    return p.returncode, p.stdout, p.stderr


class Handler(BaseHTTPRequestHandler):
    def _reply(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):  # noqa: N802
        if TOKEN and self.headers.get("x-np2reader-token") != TOKEN:
            return self._reply(401, {"ok": False, "error": "unauthorized"})
        if self.path.rstrip("/") != "/ingest":
            return self._reply(404, {"ok": False, "error": "not found"})
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        except json.JSONDecodeError:
            return self._reply(400, {"ok": False, "error": "bad json"})

        path = req.get("path")
        if path == "login":
            code, payload = fulltext_call("POST", "/login/submit", req, timeout=180)
            return self._reply(code, payload)
        if path == "save":
            url = req.get("url") or ""
            if not NEWS_ID.search(url):
                return self._reply(400, {"ok": False, "error": "not a NewsPicks article URL"})
            cmd = [sys.executable, SCRIPT, "--fulltext", url]
        elif path == "newsletter":
            n = int(req.get("n") or 1)
            if not 1 <= n <= 20:
                return self._reply(400, {"ok": False, "error": "n must be 1..20"})
            cmd = [sys.executable, SCRIPT, "--newsletter", str(n)]
        else:
            return self._reply(400, {"ok": False, "error": "unknown path"})

        try:
            code, out, err = run(cmd)
        except subprocess.TimeoutExpired:
            return self._reply(504, {"ok": False, "error": "timeout"})
        return self._reply(200 if code == 0 else 502, {"ok": code == 0, "stdout": out.strip(), "stderr": err.strip()})

    def do_GET(self):  # noqa: N802
        path = self.path.rstrip("/")
        if path == "/health":
            return self._reply(200, {"ok": True, "script": SCRIPT, "fulltext": bool(FULLTEXT)})
        if path == "/login/status":
            code, payload = fulltext_call("GET", "/login/status")
            return self._reply(code, payload)
        return self._reply(404, {"ok": False, "error": "not found"})

    def log_message(self, fmt, *args):  # 1 行ログだけ残す
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main() -> int:
    port = int(os.environ.get("NP2R_PORT", "8787"))
    if not TOKEN:
        print("NP2R_HOME_TOKEN is not set", file=sys.stderr)
        return 2
    if not Path(SCRIPT).exists():
        print(f"np2reader.py not found: {SCRIPT}", file=sys.stderr)
        return 2
    ThreadingHTTPServer((os.environ.get("NP2R_BIND", "0.0.0.0"), port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
