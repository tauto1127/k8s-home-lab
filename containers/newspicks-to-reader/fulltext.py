#!/usr/bin/env python3
"""
fulltext.py — プレミアム記事の「残り」をブラウザで取る部分だけを分離した常駐ワーカー。

np2reader.py（SSR 取得）で本文が足りない記事だけをここに回す。
Playwright の永続プロファイル（NewsPicks ログイン済みセッション）で記事の
本文ページを開き、NewsPicks が返した記事本文だけを取り出す。

設計方針（Readform / readwise-full-content と同じ発想）:
  - ログインは「手動 1 回だけ」。プロファイルに Cookie が残るので以後は自動。
  - パスワードは保存しない。1Password は初回ログインのときだけ人が使う。
  - 永続プロファイルを使う処理は直列に実行する。

使い方:
  # 初回だけ（画面のあるマシンで実行し、ブラウザで手動ログイン）
  python3 fulltext.py --login

  # 1 記事を取得して HTML を stdout に出す（np2reader から呼ばれる想定）
  python3 fulltext.py --url https://newspicks.com/news/17906125/ --out /tmp/a.html

  # 常駐モード: 自宅サーバーの HTTP 口から叩く
  python3 fulltext.py --serve --port 8790

環境変数:
  NP2R_PROFILE   Playwright のプロファイル置き場（既定: ~/.local/share/np2reader/profile）
  NP2R_HEADLESS  1 なら headless（既定 1）
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from threading import Lock

from np2reader import NEWSPICKS, apollo_root, article_id, next_data

DEFAULT_PROFILE = Path(os.environ.get("NP2R_PROFILE", Path.home() / ".local/share/np2reader/profile"))


def _import_playwright():
    try:
        from playwright.sync_api import sync_playwright  # noqa: F401
    except ImportError:
        sys.exit("playwright がありません: python3 -m pip install playwright && python3 -m playwright install chromium")
    from playwright.sync_api import sync_playwright
    return sync_playwright


def clear_stale_singleton() -> None:
    """前のプロセスが残した Chromium の Singleton を消す。

    PVC 上のプロファイルは Pod の再作成をまたいで残るため、クラッシュや強制終了のあとに
    SingletonLock が残ると、以後の起動がすべて "profile appears to be in use" で失敗する。
    """
    for name in ("SingletonLock", "SingletonCookie", "SingletonSocket"):
        try:
            (DEFAULT_PROFILE / name).unlink()
        except FileNotFoundError:
            pass


def launch(p, headless: bool):
    DEFAULT_PROFILE.mkdir(parents=True, exist_ok=True)
    clear_stale_singleton()
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
        # コンテナ内は root 扱いで動くため、Chromium の sandbox を無効化しないと起動しない。
        chromium_sandbox=False,
        args=["--headless=new"] if headless else [],
    )
    return ctx


def is_logged_in(page) -> bool:
    """ヘッダに「ログイン」ボタンが出ているかで判定（NewsPicks は未ログイン時に出る）。"""
    try:
        txt = page.inner_text("header", timeout=5000)
    except Exception:
        return False
    return "ログイン" not in txt


def _article_query(root: dict, name: str, news_id: str) -> dict:
    prefix = name + "("
    for key, value in root.items():
        if not (key.startswith(prefix) and key.endswith(")") and isinstance(value, dict)):
            continue
        try:
            args = json.loads(key[len(prefix):-1])
        except json.JSONDecodeError:
            continue
        if isinstance(args, dict) and str(args.get("newsId")) == news_id:
            return value
    return {}


def extract_body_html(page_html: str, news_id: str) -> str:
    """指定記事について、閲覧許可と残り文字数を確認できた本文だけを返す。"""
    root = apollo_root(next_data(page_html) or {})
    news = _article_query(root, "news", news_id)
    if str(news.get("newsId")) != news_id or news.get("permitted") is not True:
        return ""
    contents = _article_query(root, "newsBodyPageContents", news_id)
    body = contents.get("newsBody") or {}
    html = body.get("body")
    if not isinstance(html, str) or not html.strip() or "remainingCharCount" not in body:
        return ""
    remaining = body["remainingCharCount"]
    return html if remaining is None or (type(remaining) is int and remaining == 0) else ""


def fetch(url: str, headless: bool = True, timeout_ms: int = 45000) -> dict:
    news_id = article_id(url)
    if news_id is None:
        return {"ok": False, "error": "not a NewsPicks article URL"}
    body_url = f"{NEWSPICKS}/news/{news_id}/body/"
    sync_playwright = _import_playwright()
    with sync_playwright() as p:
        ctx = launch(p, headless)
        try:
            page = ctx.new_page()
            response = page.goto(body_url, wait_until="domcontentloaded", timeout=timeout_ms)
            if response is None or not response.ok or response.url.rstrip("/") != body_url.rstrip("/"):
                return {"ok": False, "error": "article_body_unavailable"}

            logged_in = is_logged_in(page)
            if not logged_in:
                return {"ok": False, "error": "not_logged_in"}
            body = extract_body_html(response.text(), news_id)
            if not body:
                return {"ok": False, "error": "article_body_incomplete"}
            return {
                "ok": True,
                "url": url,
                "news_id": news_id,
                "title": page.title().split(" - ")[0].strip(),
                "logged_in": logged_in,
                "complete": True,
                "html": body,
                "chars": len(re.sub(r"\s+", "", re.sub(r"<[^>]+>", "", body))),
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


def remote_submit(payload: dict, headless: bool) -> dict:
    """認証情報または Cookie を永続プロファイルに反映する。パスワードは保存しない。"""
    cookies = payload.get("cookies")
    email, password = payload.get("email"), payload.get("password")
    if not cookies and not (email and password):
        return {"ok": False, "error": "email and password are required"}

    sync_playwright = _import_playwright()
    with sync_playwright() as p:
        ctx = launch(p, headless)
        try:
            page = ctx.new_page()
            if cookies:
                ctx.add_cookies(cookies)
                page.goto("https://newspicks.com/", wait_until="domcontentloaded")
            else:
                page.goto("https://newspicks.com/login-page/?path=%2F", wait_until="domcontentloaded")
                page.locator('input[type="email"]').fill(email)
                page.locator('input[type="password"]').fill(password)
                page.get_by_role("button", name="ログイン", exact=True).click()
                page.wait_for_url("https://newspicks.com/", wait_until="domcontentloaded")
            ok = is_logged_in(page)
            return {"ok": ok, "state": "logged_in" if ok else "failed"}
        finally:
            ctx.close()


def remote_status(headless: bool) -> dict:
    sync_playwright = _import_playwright()
    with sync_playwright() as p:
        ctx = launch(p, headless)
        try:
            page = ctx.new_page()
            page.goto("https://newspicks.com/", wait_until="domcontentloaded")
            logged_in = is_logged_in(page)
            return {"ok": True, "state": "logged_in" if logged_in else "idle", "logged_in": logged_in}
        finally:
            ctx.close()


def serve(port: int, headless: bool) -> None:
    """ブラウザを使う操作を直列化し、ヘルスチェックは独立して応答する。"""
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    token = os.environ.get("NP2R_FULLTEXT_TOKEN", "")
    profile_lock = Lock()

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
            path = self.path.rstrip("/")
            if path == "/health":
                return self._json(200, {"ok": True})
            if not self._authed():
                return self._json(401, {"ok": False, "error": "unauthorized"})
            if path == "/login/status":
                try:
                    with profile_lock:
                        status = remote_status(headless)
                except Exception:
                    return self._json(502, {"ok": False, "error": "could not check NewsPicks login"})
                return self._json(200, status)
            return self._json(404, {"ok": False, "error": "not found"})

        def do_POST(self):  # noqa: N802
            if not self._authed():
                return self._json(401, {"ok": False, "error": "unauthorized"})
            req = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
            path = self.path.rstrip("/")

            if path == "/login/submit":
                try:
                    with profile_lock:
                        res = remote_submit(req, headless)
                except Exception:
                    return self._json(502, {"ok": False, "error": "NewsPicks login failed"})
                return self._json(200 if res.get("ok") else 502, res)

            if path != "/fetch":
                return self._json(404, {"ok": False, "error": "not found"})

            url = req.get("url", "")
            if not isinstance(url, str) or article_id(url) is None:
                return self._json(400, {"ok": False, "error": "not a NewsPicks article URL"})
            try:
                with profile_lock:
                    res = fetch(url, headless=headless)
                code = 200 if res.get("ok") else 502
            except Exception as e:  # noqa: BLE001
                res, code = {"ok": False, "error": str(e)}, 500
            self._json(code, res)

        def log_message(self, *a):  # 静かに
            pass

    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--login", action="store_true")
    ap.add_argument("--url")
    ap.add_argument("--out")
    ap.add_argument("--serve", action="store_true")
    ap.add_argument("--port", type=int, default=8790)
    ap.add_argument("--headless", type=int, default=int(os.environ.get("NP2R_HEADLESS", "1")))
    a = ap.parse_args(argv)

    if a.login:
        login()
        return 0
    if a.serve:
        serve(a.port, bool(a.headless))
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
