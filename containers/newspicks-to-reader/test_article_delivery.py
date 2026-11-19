import json
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread
from unittest.mock import patch

from fulltext import extract_body_html
from np2reader import Article, enrich_with_browser, save_to_reader


def article_page(body=None, *, permitted=True, news_id=42):
    root = {
        'news({"newsId":99})': {"newsId": 99, "permitted": True},
        'newsBodyPageContents({"newsId":99})': {
            "newsBody": {"body": "<p>別の記事</p>", "remainingCharCount": None},
        },
        f'news({{"newsId":{news_id}}})': {"newsId": news_id, "permitted": permitted},
    }
    if body is not None:
        root['newsBodyPageContents({"newsId":42})'] = {"newsBody": body}
    data = {"props": {"pageProps": {"initialApolloState": {"ROOT_QUERY": root}}}}
    return '<main><h2>注目のコメント</h2>' + '有用なコメント。' * 50 + (
        '</main><script id="__NEXT_DATA__" type="application/json">' + json.dumps(data) + '</script>'
    )


class ArticleDeliveryTest(unittest.TestCase):
    def test_summary_page_cannot_be_mistaken_for_full_text(self):
        self.assertEqual(extract_body_html(article_page(), "42"), "")

    def test_only_requested_and_permitted_complete_body_is_returned(self):
        body = '<h2>記事の後半</h2><div>有料会員向けの本文。</div>'
        full = {"body": body, "remainingCharCount": None}
        self.assertEqual(extract_body_html(article_page(full), "42"), body)
        for page in (
            article_page({"body": body, "remainingCharCount": 300}),
            article_page({"body": body}),
            article_page(full, permitted=False),
            article_page(full, news_id=43),
        ):
            with self.subTest(page=page[-230:]):
                self.assertEqual(extract_body_html(page, "42"), "")

    def test_legacy_browser_response_cannot_replace_the_preview(self):
        class LegacyWorker(BaseHTTPRequestHandler):
            def do_POST(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"ok":true,"complete":true,"html":"<p>Comments</p>"}')

        preview = Article(url='https://newspicks.com/news/42/', truncated=True, body_html='<p>Preview</p>')
        with HTTPServer(('127.0.0.1', 0), LegacyWorker) as server:
            server.timeout = 3
            worker = Thread(target=server.handle_request)
            worker.start()
            try:
                result = enrich_with_browser(preview, f'http://127.0.0.1:{server.server_port}/fetch', '', timeout=3)
            finally:
                worker.join(timeout=3)
        self.assertTrue(result.truncated)
        self.assertFalse(result.fulltext)
        self.assertEqual(result.body_html, '<p>Preview</p>')

    def test_reader_receives_safe_article_markup_without_reparsing(self):
        requests = []

        class Reader(BaseHTTPRequestHandler):
            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                requests.append(request)
                if not request.get('should_clean_html') and not all(request.get(k) for k in ('title', 'author')):
                    self.send_error(400)
                    return
                self.send_response(201)
                self.end_headers()
                self.wfile.write(b'{"id":"fixture-article"}')

        art = Article(url='https://newspicks.com/news/42/', title='テスト記事', body_html=(
            "<h2>記事の後半</h2><div>有料会員向けの本文。</div>"
            "<script>internal script</script><iframe>third-party content</iframe>"
            "<a href='jav&#97;script:alert(1)'>link label</a>"
            "<a href='https://[broken'>malformed link label</a>"
            "<picture><source srcset='/image.png?crop=0,0,640,360\t2x, /small.png 1x'></picture>"
            "<img src='/image.png' onerror='alert(1)'>"
        ))
        with HTTPServer(('127.0.0.1', 0), Reader) as server:
            server.timeout = 3
            thread = Thread(target=server.handle_request)
            thread.start()
            try:
                with patch('np2reader.READWISE_SAVE', f'http://127.0.0.1:{server.server_port}/save/'):
                    save_to_reader(art, 'fixture', 'new', [])
            finally:
                thread.join(timeout=3)
        request, = requests
        self.assertFalse(request['should_clean_html'])
        self.assertIn('<h2>記事の後半</h2><div>有料会員向けの本文。</div>', request['html'])
        self.assertIn('src="https://newspicks.com/image.png"', request['html'])
        self.assertIn('malformed link label', request['html'])
        self.assertIn(
            'srcset="https://newspicks.com/image.png?crop=0,0,640,360 2x, https://newspicks.com/small.png 1x"',
            request['html'],
        )
        for unwanted in ('internal script', 'third-party content', 'javascript:', 'onerror='):
            self.assertNotIn(unwanted, request['html'])
