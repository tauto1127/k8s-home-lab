#!/usr/bin/env python3
"""
fulltext.py — プレミアム記事の「残り」をブラウザで取る部分だけを分離した常駐ワーカー。

np2reader.py（SSR 取得）で本文が足りない記事だけをここに回す。
Playwright の永続プロファイル（= あなたの NewsPicks ログイン済みセッション）を使い、
記事ページを実際に描画して本文 DOM を丸ごと抜き、Reader 用の HTML に詰め替える。

設計方針（Readform / readwise-full-content と同じ発想）:
  - ログインは「手動 1 回だけ」。プロファイルに Cookie が残るので以後は自動。
  - パスワードは保存しない。1Password は初回ログインのときだけ人が使う。
  - ヘッドレスで通らない場合は headful（xvfb）にフォールバック。
  - 1 記事ずつ、人間のペース（数秒待ち・スクロール）で処理する。並列化しない。

使い方:
  # 初回だけ（画面のあるマシンで実行し、ブラウザで手動ログイン）
  python3 fulltext.py --login

  # 1 記事を取得して HTML を stdout に出す（np2reader から呼ばれる想定）
  python3 fulltext.py --url https://newspicks.com/news/17906125/ --out /tmp/a.html

  # 常駐モード: 自宅サーバーの HTTP 口から叩く
  python3 fulltext.py --serve --port 8790

環境変数:
  NP2R_PROFILE   Playwright のプロファイル置き場（既定: ~/.local/share/np2reader/profile）
  NP2R_HEADLESS  1 なら headless（既定 1）。Cloudflare に弾かれる場合 0 + xvfb-run
"""

from __future__ import annotations

import argparse
import html as htmllib
import json
import os
import re
import sys
import time
from pathlib import Path

DEFAULT_PROFILE = Path(os.environ.get("NP2R_PROFILE", Path.home() / ".local/share/np2reader/profile"))
ARTICLES = [
    "#body .original-v2",  # 通常記事（プレミアム含む）
    "#body",               # フォールバック
    "main",
    "article",
]
# 本文に入ってきたら落とすもの（ナビ・シェア・関連記事・コメント・課金導線）
DROP_SELECTORS = [
    "script", "style", "noscript", "iframe",
    ".paging-container", ".twitter-share-button", ".share", ".sns",
    ".next-article", ".prev-article", ".related", ".comment", ".comments",
    "header", "footer", "nav",
]


def _import_playwright():
    try:
        from playwright.sync_api import sync_playwright  # noqa: F401
    except ImportError:
        sys.exit("playwright がありません: python3 -m pip install playwright && python3 -m playwright install chromium")
    from playwright.sync_api import sync_playwright
    return sync_playwright


def launch(p, headless: bool):
    DEFAULT_PROFILE.mkdir(parents=True, exist_ok=True)
    ctx = p.chromium.launch_persistent_context(
        str(DEFAULT_PROFILE),
        headless=headless,
        locale="ja-JP",
        timezone_id="Asia/Tokyo",
        viewport={"width": 430, "height": 932},  # モバイル相当のレイアウト
        user_agent=(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        ),
        is_mobile=True,
        has_touch=True,
    )
    return ctx


def human_pause(lo: float = 1.5, hi: float = 3.5) -> None:
    import random
    time.sleep(random.uniform(lo, hi))


def scroll_through(page) -> None:
    """遅延読み込み画像を起こすため、ゆっくり最後までスクロールする。"""
    height = page.evaluate("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)")
    y = 0
    while y < height:
        y += 600
        page.evaluate(f"window.scrollTo(0, {y})")
        time.sleep(0.35)
        height = page.evaluate("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)")
    page.evaluate("window.scrollTo(0, 0)")
    time.sleep(0.5)


def is_logged_in(page) -> bool:
    """ヘッダに「ログイン」ボタンが出ているかで判定（NewsPicks は未ログイン時に出る）。"""
    try:
        txt = page.inner_text("header", timeout=5000)
    except Exception:
        return False
    return "ログイン" not in txt


def extract_body_html(page) -> tuple[str, bool]:
    """本文 DOM を取得。プレミアムの壁が消えているか（=全文取れたか）も返す。"""
    for sel in ARTICLES:
        node = page.query_selector(sel)
        if not node:
            continue
        html = node.evaluate(
            """(el, drop) => {
                const clone = el.cloneNode(true);
                for (const s of drop) clone.querySelectorAll(s).forEach(n => n.remove());
                return clone.innerHTML;
            }""",
            DROP_SELECTORS,
        )
        text = re.sub(r"\s+", "", re.sub(r"<[^>]+>", "", html))
        wall = "プレミアム会員限定" in text or "残り" in text and "文字" in text
        if len(text) > 200:
            return html, not wall
    return "", False


def fetch(url: str, headless: bool = True, timeout_ms: int = 45000) -> dict:
    sync_playwright = _import_playwright()
    with sync_playwright() as p:
        ctx = launch(p, headless)
        try:
            page = ctx.new_page()
            page.goto("https://newspicks.com/", wait_until="domcontentloaded", timeout=timeout_ms)
            human_pause()
            logged_in = is_logged_in(page)
            if not logged_in:
                return {"ok": False, "error": "not_logged_in", "hint": "python3 fulltext.py --login でログインしてください"}

            page.goto(url, wait_until="domcontentloaded", timeout=timeout_ms)
            human_pause(2.0, 4.0)
            scroll_through(page)

            body_html, complete = extract_body_html(page)
            title = page.title().split(" - ")[0].strip()
            return {
                "ok": bool(body_html),
                "url": url,
                "title": title,
                "logged_in": logged_in,
                "complete": complete,
                "html": body_html,
                "chars": len(re.sub(r"\s+", "", re.sub(r"<[^>]+>", "", body_html))),
            }
        finally:
            ctx.close()


def login() -> None:
    """手動ログイン用。ブラウザが開くので、1Password から貼り付けてログインし、Enter で閉じる。"""
    sync_playwright = _import_playwright()
    with sync_playwright() as p:
        ctx = launch(p, headless=False)
        page = ctx.new_page()
        page.goto("https://newspicks.com/", wait_until="domcontentloaded")
        print("ブラウザで NewsPicks にログインしてください。完了したらこのターミナルで Enter。", file=sys.stderr)
        input()
        print(f"プロファイル保存先: {DEFAULT_PROFILE}", file=sys.stderr)
        ctx.close()


# --------------------------------------------------------------------------- #
# 遠隔ログイン（クラスタ運用向け）
#   ブラウザの画面を /login に VNC で映し、/login/submit で 1Password から
#   受け取った値（または Cookie）を流し込む。パスワードは保存しない。
# --------------------------------------------------------------------------- #
_remote: dict = {"page": None, "ctx": None, "playwright": None, "state": "idle", "message": ""}


def remote_start(port: int, headless: bool) -> None:
    sync_playwright = _import_playwright()
    p = sync_playwright().start()
    ctx = p.chromium.launch_persistent_context(
        str(DEFAULT_PROFILE),
        headless=headless,
        locale="ja-JP",
        timezone_id="Asia/Tokyo",
        viewport={"width": 430, "height": 932},
        user_agent=(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        ),
        is_mobile=True,
        has_touch=True,
        args=[f"--remote-debugging-port={port}", "--remote-debugging-address=127.0.0.1"],
    )
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    page.goto("https://newspicks.com/", wait_until="domcontentloaded")
    _remote.update(page=page, ctx=ctx, playwright=p, state="idle", message="")


def remote_submit(payload: dict) -> dict:
    """ログイン情報を流し込む。payload は以下のいずれか:
      {"email": ..., "password": ...}   フォーム入力
      {"cookies": [{name, value, domain, path}, ...]}   セッション移行
    """
    page = _remote.get("page")
    if page is None:
        return {"ok": False, "error": "browser not started"}
    try:
        if payload.get("cookies"):
            _remote["ctx"].add_cookies(payload["cookies"])
            page.goto("https://newspicks.com/", wait_until="domcontentloaded")
            ok = is_logged_in(page)
            _remote.update(state="logged_in" if ok else "failed", message="cookies applied")
            return {"ok": ok, "state": _remote["state"]}

        email, password = payload.get("email"), payload.get("password")
        if not email or not password:
            return {"ok": False, "error": "email and password are required"}

        page.goto("https://newspicks.com/login", wait_until="domcontentloaded")
        page.fill('input[type="email"], input[name="email"]', email)
        page.click('button[type="submit"], button:has-text("次へ"), button:has-text("ログイン")')
        human_pause(1.0, 2.0)
        page.fill('input[type="password"], input[name="password"]', password)
        page.click('button[type="submit"], button:has-text("ログイン")')
        page.wait_for_load_state("domcontentloaded")
        human_pause(2.0, 3.0)
        ok = is_logged_in(page)
        _remote.update(state="logged_in" if ok else "failed", message="password login")
        return {"ok": ok, "state": _remote["state"]}
    except Exception as e:  # noqa: BLE001
        _remote.update(state="failed", message=str(e))
        return {"ok": False, "error": str(e)}


def remote_status() -> dict:
    page = _remote.get("page")
    logged_in = False
    if page is not None:
        try:
            logged_in = is_logged_in(page)
        except Exception:
            logged_in = False
    return {"ok": True, "state": _remote["state"], "logged_in": logged_in, "message": _remote["message"]}


def serve(port: int, headless: bool, login_port: int = 0) -> None:
    """HTTP 口。POST /fetch {"url": ...} で HTML を返す。

    login_port > 0 なら、ログイン用の Chromium を VNC で見える形で起動し、
    /login /login/submit /login/status を生やす。
    """
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    token = os.environ.get("NP2R_FULLTEXT_TOKEN", "")

    class H(BaseHTTPRequestHandler):
        def _json(self, code: int, payload: dict) -> None:
            body = json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("content-type", "application/json; charset=utf-8")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _authed(self) -> bool:
            return not token or self.headers.get("x-np2reader-token") == token

        def do_GET(self):  # noqa: N802
            if not self._authed():
                return self._json(401, {"ok": False, "error": "unauthorized"})
            if self.path.rstrip("/") == "/health":
                return self._json(200, {"ok": True, **remote_status()})
            if self.path.rstrip("/") == "/login/status":
                return self._json(200, remote_status())
            return self._json(404, {"ok": False, "error": "not found"})

        def do_POST(self):  # noqa: N802
            if not self._authed():
                return self._json(401, {"ok": False, "error": "unauthorized"})
            req = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
            path = self.path.rstrip("/")

            if path == "/login/submit":
                res = remote_submit(req)
                return self._json(200 if res.get("ok") else 502, res)

            if path != "/fetch":
                return self._json(404, {"ok": False, "error": "not found"})

            url = req.get("url", "")
            if not re.search(r"newspicks\.com/news/\d+", url):
                return self._json(400, {"ok": False, "error": "not a NewsPicks article URL"})
            try:
                res = fetch(url, headless=headless)
                code = 200 if res.get("ok") else 502
            except Exception as e:  # noqa: BLE001
                res, code = {"ok": False, "error": str(e)}, 500
            self._json(code, res)

        def log_message(self, *a):  # 静かに
            pass

    if login_port:
        remote_start(login_port, headless=False)

    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--login", action="store_true")
    ap.add_argument("--url")
    ap.add_argument("--out")
    ap.add_argument("--serve", action="store_true")
    ap.add_argument("--port", type=int, default=8790)
    ap.add_argument("--login-port", type=int, default=int(os.environ.get("NP2R_LOGIN_CDP_PORT", "0")),
                    help=">0 ならログイン用ブラウザを起動し VNC で操作できるようにする")
    ap.add_argument("--headless", type=int, default=int(os.environ.get("NP2R_HEADLESS", "1")))
    a = ap.parse_args(argv)

    if a.login:
        login()
        return 0
    if a.serve:
        serve(a.port, bool(a.headless), a.login_port)
        return 0
    if not a.url:
        ap.print_help()
        return 2

    res = fetch(a.url, headless=bool(a.headless))
    if a.out and res.get("ok"):
        Path(a.out).write_text(res["html"], encoding="utf-8")
        res.pop("html", None)
    print(json.dumps(res, ensure_ascii=False))
    return 0 if res.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
