#!/usr/bin/env python3
"""
np2reader.py — NewsPicks の記事 / 日次ニュースレターを Readwise Reader に「HTML ごと」送る。

iOS の NewsPicks アプリで記事を共有 → Shortcuts でこのスクリプトを叩く → Reader に入る、
を実現するための最小実装。標準ライブラリのみで動く。

使い方:
  # 1) 記事 URL をそのまま渡す（iOS の共有シートから来る URL を想定）
  python3 np2reader.py https://newspicks.com/news/17906125/

  # 2) 日次ニュースレター（4 本のダイジェスト）を最新号から N 号分まとめて送る
  python3 np2reader.py --newsletter 3

  # 3) 実際に送らず、何が送られるか確認
  python3 np2reader.py --dry-run https://newspicks.com/news/17906125/

環境変数:
  READWISE_TOKEN      Readwise の access token（https://readwise.io/access_token）
  NEWSPICKS_COOKIE    （任意）NewsPicks のログイン済み Cookie 文字列
  NP2R_LOCATION       （任意）Reader の保存先 new / later / archive / feed（既定: new）
  NP2R_TAGS           （任意）カンマ区切りタグ（既定: newspicks）

終了コード: 0=成功 / 1=一部失敗 / 2=設定・引数エラー
"""

from __future__ import annotations

import argparse
import html as htmllib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

READWISE_SAVE = "https://readwise.io/api/v3/save/"
NEWSPICKS = "https://newspicks.com"
NEWSLETTER_TOPIC = "newspicks-newsletter"
JST = timezone(timedelta(hours=9))

# NewsPicks は PC の UA だと 403 を返すことがある。モバイル Safari の UA で SSR 済み HTML を取る。
UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
)


# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #
def http_get(url: str, cookie: str | None = None, timeout: int = 30) -> tuple[int, str, str]:
    """(status, body, final_url) を返す。リダイレクトは追わない（外へ飛ぶ記事はリンクを残したい）。"""
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "ja,en;q=0.8"})
    if cookie:
        req.add_header("Cookie", cookie)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            return res.status, res.read().decode("utf-8", "replace"), res.geturl()
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace") if e.fp else ""
        return e.code, body, e.geturl() or url


def next_data(page_html: str) -> dict | None:
    """Next.js の __NEXT_DATA__ を取り出す。"""
    m = re.search(r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', page_html, re.S)
    if not m:
        return None
    try:
        return json.loads(m.group(1))
    except json.JSONDecodeError:
        return None


def apollo_root(data: dict) -> dict:
    try:
        return data["props"]["pageProps"]["initialApolloState"]["ROOT_QUERY"]
    except (KeyError, TypeError):
        return {}


def find_key(root: dict, prefix: str) -> dict | None:
    for k, v in root.items():
        if k.startswith(prefix) and isinstance(v, dict):
            return v
    return None


def find_news(root: dict) -> dict | None:
    return find_key(root, "news(")


# --------------------------------------------------------------------------- #
# 抽出
# --------------------------------------------------------------------------- #
@dataclass
class Article:
    url: str
    title: str = ""
    author: str = ""
    published: str | None = None
    summary: str = ""
    image: str = ""
    body_html: str = ""
    paid: bool = False
    permitted: bool = True
    forbidden: str = "NONE"
    truncated: bool = False
    external_url: str | None = None
    kind: str = "article"  # article | digest | external | video
    notes: list[str] = field(default_factory=list)
    fulltext: bool = False  # ブラウザで本文を取り直したか


def _iso(dt: str | None) -> str | None:
    if not dt:
        return None
    try:
        return datetime.fromisoformat(dt.replace("Z", "+00:00")).astimezone(JST).isoformat(timespec="seconds")
    except ValueError:
        return None


def _strip_tags(s: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", s)).strip()


def parse_article(news_id: str, cookie: str | None = None) -> Article:
    """記事ページ（/body/）を取得して本文 HTML とメタ情報を抜く。"""
    url = f"{NEWSPICKS}/news/{news_id}/"
    art = Article(url=url)

    status, page, final_url = http_get(f"{NEWSPICKS}/news/{news_id}/body/", cookie)
    redirected_offsite = "newspicks.com" not in final_url
    if redirected_offsite:
        # 外部メディアの記事: NewsPicks 側に本文が無く、元記事へ飛ぶ（urllib は 3xx を追跡済み）
        art.kind = "external"
        art.external_url = final_url
        status, page, _ = http_get(url, cookie)  # メタ情報だけ取り直す
    if status != 200:
        raise RuntimeError(f"NewsPicks returned {status} for {url}")

    data = next_data(page) or {}
    root = apollo_root(data)
    news = find_news(root) or {}

    art.title = (news.get("title") or "").strip()
    art.summary = _strip_tags(news.get("summary") or "")
    art.image = news.get("image") or ""
    art.published = _iso(news.get("publishedAt"))
    art.paid = bool(news.get("paid"))
    art.permitted = bool(news.get("permitted", True))
    art.forbidden = news.get("forbiddenReason") or "NONE"
    if news.get("hasExternalLink") and news.get("link"):
        art.external_url = news["link"]
        art.kind = "external"

    page_contents = find_key(root, "newsBodyPageContents(") or find_key(root, "newsSummaryPageContents(") or {}

    # 1) 通常記事: newsBody.body に本文 HTML
    nb = page_contents.get("newsBody") or {}
    body = nb.get("body") or ""
    remaining = nb.get("remainingCharCount") or 0
    if body:
        art.body_html = body
        art.truncated = remaining > 0
        if art.truncated:
            art.notes.append(f"NewsPicks 側で残り {remaining:,} 文字がプレミアム会員限定のため未取得")

    # 2) トピック投稿（日次ニュースレター等）: topicPost.body.html
    tp = page_contents.get("topicPost") or {}
    if not art.body_html and tp:
        tb = tp.get("body") or {}
        art.body_html = tb.get("html") or ""
        art.kind = "digest"
        art.title = art.title or tp.get("title") or ""
        art.published = art.published or _iso(tp.get("published"))

    # 3) 動画: 本文は無い。JSON-LD の VideoObject から説明文（番組概要）を拾う
    if not art.body_html:
        art.kind = "video" if news.get("videoContents") else art.kind
        m = re.search(r'<script type="application/ld\+json">(.*?)</script>', page, re.S)
        try:
            ld = json.loads(m.group(1)) if m else {}
        except json.JSONDecodeError:
            ld = {}
        desc = ld.get("description") or ""
        if desc:
            art.body_html = "".join(f"<p>{htmllib.escape(line)}</p>" for line in desc.splitlines() if line.strip())
        art.notes.append("動画コンテンツのため本文 HTML はありません（番組概要のみ）")

    # 著者（newsBody ページの JSON-LD には author が無いので、HTML 上のプロフィールから拾う）
    if not art.author:
        m = re.search(r'<a href="https://newspicks\.com/user/\d+"[^>]*>\s*<img[^>]*>', page)
        m2 = re.search(r'class="author-name"[^>]*>([^<]+)<', page) or re.search(
            r'"authors":\[\{"__typename":"User","userId":\d+,"displayName":"([^"]+)"', page
        )
        if m2:
            art.author = htmllib.unescape(m2.group(1)).strip()
        elif m:
            art.author = ""

    if not art.title:
        m = re.search(r"<title>(.*?)</title>", page, re.S)
        art.title = htmllib.unescape(m.group(1)).split(" - ")[0].strip() if m else f"NewsPicks {news_id}"

    return art


def parse_newsletter(limit: int = 5, cookie: str | None = None) -> list[dict]:
    """【公式】NewsPicks NewsLetter の最新号を列挙する。"""
    status, page, _ = http_get(f"{NEWSPICKS}/topics/{NEWSLETTER_TOPIC}/", cookie)
    if status != 200:
        raise RuntimeError(f"NewsPicks returned {status} for newsletter topic")
    data = next_data(page) or {}
    try:
        items = data["props"]["pageProps"]["page"]["topic"]["posts"]["items"]
    except (KeyError, TypeError):
        raise RuntimeError("newsletter topic data not found (NewsPicks のページ構造が変わった可能性)")
    return items[:limit]


# --------------------------------------------------------------------------- #
# Reader 用 HTML の整形
# --------------------------------------------------------------------------- #
KEEP_ATTRS = {"href", "src", "alt", "srcset", "width", "height"}


def sanitize(fragment: str) -> str:
    """script/style/iframe を落とし、属性を絞る（Reader 側のクリーニングと相性を良くするため）。"""
    fragment = re.sub(r"<script\b.*?</script>", "", fragment, flags=re.S | re.I)
    fragment = re.sub(r"<style\b.*?</style>", "", fragment, flags=re.S | re.I)
    fragment = re.sub(r"<noscript\b.*?</noscript>", "", fragment, flags=re.S | re.I)

    def clean_tag(m: re.Match) -> str:
        closing, name, attrs = m.group(1), m.group(2).lower(), m.group(3)
        if closing:
            return f"</{name}>"
        kept = re.findall(r'([a-zA-Z-]+)\s*=\s*"([^"]*)"', attrs)
        out = " ".join(f'{k}="{v}"' for k, v in kept if k.lower() in KEEP_ATTRS)
        return f"<{name}{(' ' + out) if out else ''}>"

    fragment = re.sub(r"<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>", clean_tag, fragment)
    # 空の div / p を整理
    fragment = re.sub(r"<(p|div)>\s*</\1>", "", fragment)
    return fragment.strip()


def build_reader_html(art: Article) -> str:
    parts: list[str] = []
    if art.image:
        parts.append(f'<p><img src="{htmllib.escape(art.image, quote=True)}" alt=""></p>')
    if art.summary:
        parts.append(f"<p><em>{htmllib.escape(art.summary)}</em></p>")
    if art.external_url:
        parts.append(
            f'<p><a href="{htmllib.escape(art.external_url, quote=True)}">元記事を開く（{htmllib.escape(art.external_url)}）</a></p>'
        )
    parts.append(sanitize(art.body_html))
    if art.notes:
        parts.append("<hr>")
        parts.append("<p><strong>取得メモ</strong></p><ul>")
        parts.extend(f"<li>{htmllib.escape(n)}</li>" for n in art.notes)
        parts.append("</ul>")
    return "\n".join(p for p in parts if p)


def enrich_with_browser(art: Article, endpoint: str, token: str, timeout: int = 180) -> Article:
    """プレミアム記事の「残り」を fulltext.py（Playwright 常駐）に取りに行く。

    endpoint は `python3 fulltext.py --serve` の URL（例: http://127.0.0.1:8790/fetch）。
    失敗しても例外にせず notes に残す（冒頭だけでも Reader に入れる）。
    """
    req = urllib.request.Request(
        endpoint,
        data=json.dumps({"url": art.url}).encode(),
        headers={"Content-Type": "application/json", **({"x-np2reader-token": token} if token else {})},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            data = json.loads(res.read().decode() or "{}")
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
        art.notes.append(f"ブラウザ取得に失敗（冒頭のみ）: {e}")
        return art

    if not data.get("ok"):
        art.notes.append(f"ブラウザ取得に失敗（冒頭のみ）: {data.get('error') or data.get('hint')}")
        return art

    art.body_html = data["html"]
    art.fulltext = True
    art.truncated = not data.get("complete", True)
    art.title = art.title or data.get("title", "")
    art.notes = [n for n in art.notes if "プレミアム会員限定" not in n]
    if art.truncated:
        art.notes.append("ブラウザで取得したが、ページ上に課金の壁が残っていた")
    return art


def save_to_reader(art: Article, token: str, location: str, tags: list[str], dry_run: bool = False) -> dict:
    payload = {
        "url": art.url,
        "html": build_reader_html(art),
        "should_clean_html": True,
        "title": art.title,
        "summary": art.summary[:1000] if art.summary else None,
        "location": location,
        "category": "article",
        "saved_using": "np2reader",
        "tags": tags,
        "language": "ja",
    }
    if art.author:
        payload["author"] = art.author
    if art.published:
        payload["published_date"] = art.published
    if art.image:
        payload["image_url"] = art.image
    payload = {k: v for k, v in payload.items() if v not in (None, "", [], {})}

    if dry_run:
        return {"dry_run": True, "url": art.url, "title": art.title, "html_bytes": len(payload["html"].encode())}

    req = urllib.request.Request(
        READWISE_SAVE,
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Token {token}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            return json.loads(res.read().decode() or "{}") | {"status": res.status}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:500]
        raise RuntimeError(f"Reader API {e.code}: {detail}")


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
NEWS_ID_RE = re.compile(r"newspicks\.com/(?:news|news-in-app)/(\d+)")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="NewsPicks → Readwise Reader (full HTML)")
    ap.add_argument("urls", nargs="*", help="NewsPicks の記事 URL（複数可）")
    ap.add_argument("--newsletter", type=int, metavar="N", help="日次ニュースレター最新 N 号を送る")
    ap.add_argument("--dry-run", action="store_true", help="Reader へ送らず内容だけ確認")
    ap.add_argument(
        "--fulltext",
        action="store_true",
        default=bool(os.environ.get("NP2R_FULLTEXT_ENDPOINT")),
        help="プレミアム記事の残りを fulltext.py（Playwright）で取り直す（既定: 環境変数があれば有効）",
    )
    args = ap.parse_args(argv)

    token = os.environ.get("READWISE_TOKEN", "")
    cookie = os.environ.get("NEWSPICKS_COOKIE") or None
    location = os.environ.get("NP2R_LOCATION", "new")
    tags = [t.strip() for t in os.environ.get("NP2R_TAGS", "newspicks").split(",") if t.strip()]
    fulltext_endpoint = os.environ.get("NP2R_FULLTEXT_ENDPOINT", "")
    fulltext_token = os.environ.get("NP2R_FULLTEXT_TOKEN", "")

    if not args.dry_run and not token:
        print("READWISE_TOKEN is not set", file=sys.stderr)
        return 2

    targets: list[tuple[str, str]] = []  # (news_id, source_label)

    for u in args.urls:
        m = NEWS_ID_RE.search(u)
        if m:
            targets.append((m.group(1), "url"))
            continue
        # NewsPicks 以外の URL が来た場合: Reader に URL だけ渡す（本文は Reader 側で取得）
        print(f"[skip] not a NewsPicks article URL: {u}", file=sys.stderr)

    if args.newsletter:
        for it in parse_newsletter(args.newsletter, cookie):
            targets.append((str(it["newsId"]), f"newsletter:{it['title']}"))

    if not targets:
        print("nothing to do", file=sys.stderr)
        return 2

    failures = 0
    for news_id, label in targets:
        try:
            art = parse_article(news_id, cookie)
            if args.fulltext and art.truncated and art.kind == "article":
                if fulltext_endpoint:
                    art = enrich_with_browser(art, fulltext_endpoint, fulltext_token)
                else:
                    art.notes.append("--fulltext 指定だが NP2R_FULLTEXT_ENDPOINT が未設定のため冒頭のみ")
            res = save_to_reader(art, token, location, tags, args.dry_run)
            flag = ""
            if art.truncated:
                flag = " [partial: paywall]"
            elif art.fulltext:
                flag = " [fulltext via browser]"
            if art.kind == "external":
                flag = " [external link only]"
            print(json.dumps({"ok": True, "id": news_id, "title": art.title, "kind": art.kind, "result": res}, ensure_ascii=False) + flag)
        except Exception as e:  # noqa: BLE001 — CLI なのでまとめて報告
            failures += 1
            print(json.dumps({"ok": False, "id": news_id, "label": label, "error": str(e)}, ensure_ascii=False), file=sys.stderr)
        time.sleep(1.2)  # Reader API は 50/min 制限。余裕を持って間隔を空ける

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
