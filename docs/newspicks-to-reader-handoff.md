# newspicks-to-reader の現状と残作業

## いまの状態

- Flux パッケージは有効化済み。`ExternalSecret/newspicks-to-reader-secrets` は 1Password の 3 項目を同期する。
- `ingest` は Pod の IP で待ち受ける。`fulltext` はヘッドレスで動き、ログイン・ログイン状態確認・記事取得のときだけ永続プロファイルを開く。
- 両方の `/health` は認証不要。`fulltext` の `/health` は NewsPicks のログイン状態とは独立して `{"ok": true}` を返す。

## クラスタ外から使う前に

**Cloudflare Tunnel に `newspicks-to-reader.takutk.com` → `http://192.168.11.211:80`（Kong）を追加する。**

## そのあと

1. 初回ログインは公開経路がなくてもできる。別ターミナルでポート転送を起動する。
   ```sh
   kubectl -n newspicks-to-reader port-forward deploy/newspicks-to-reader-fulltext 8790:8790
   ```
   元のターミナルで実行し、NewsPicks の認証情報を入力する。パスワードは端末に表示されない。
   ```sh
   python3 - <<'PY'
   import base64, getpass, json, subprocess, urllib.request

   token = base64.b64decode(subprocess.check_output([
       "kubectl", "-n", "newspicks-to-reader", "get", "secret",
       "newspicks-to-reader-secrets", "-o", "jsonpath={.data.NP2R_FULLTEXT_TOKEN}",
   ])).decode()
   body = json.dumps({
       "email": getpass.getpass("NewsPicks email: "),
       "password": getpass.getpass("NewsPicks password: "),
   }).encode()
   request = urllib.request.Request("http://127.0.0.1:8790/login/submit", body, {
       "content-type": "application/json", "x-np2reader-token": token,
   })
   with urllib.request.urlopen(request, timeout=180) as response:
       print(response.read().decode())
   PY
   ```
2. iOS ショートカット作成（`docs/newspicks-to-reader-shortcut.md`）
3. 疎通確認
   ```sh
   curl -sS -X POST https://newspicks-to-reader.takutk.com/ingest \
     -H "x-np2reader-token: $NP2R_HOME_TOKEN" -H "content-type: application/json" \
     -d '{"path":"save","url":"https://newspicks.com/news/17906125/"}'
   ```
   `[fulltext via browser]` は送信元での全文取得を示す。返された Reader のリンクを開き、記事後半の見出しと本文を確認する。
   API で確認する場合は Reader の `GET /api/v3/list/?id=<id>&withHtmlContent=true` の `html_content` を参照する。

## クラスタで踏んだ落とし穴（再発防止メモ）

| 症状 | 原因 | 対処 |
|---|---|---|
| build が 127 で落ちる | `playwright install --with-deps` が PATH 上の python を要求 | 公式 python イメージに venv は無い。`python -m playwright install-deps` を先に実行 |
| `libatomic.so.1` が無い | slim イメージに無い | `libatomic1` を apt で追加 |
| `Executable doesn't exist at /home/np2r/.cache/...` | ブラウザは root の `/root/.cache` に入る | `PLAYWRIGHT_BROWSERS_PATH=/ms-playwright` |
| `/root` 配下が読めない | `/root` は 0700 | 共有パスへ |
| `ingest` の `/health` に Pod IP から接続できない | ループバックだけで待ち受けていた | コンテナでは `0.0.0.0` で待ち受ける |
| `fulltext` が Python を起動する前に止まる | PID 1 の `xvfb-run` が Xvfb の起動通知を待ち続ける | Xvfb を使わず Python を直接起動する |
| `fulltext` の `/health` が 401 | 以前は認証が必要だった | `/health` を認証なしで返し、認証付きの `/login/status` でログインを確認する |
| `profile appears to be in use` | PVC に Chromium のロックが残る | プロファイルを直列で開き、起動時に古い `Singleton*` を削除する |

## 注意

- `fulltext` は 1 Pod で運用する。`Recreate` とリクエストの直列化で、同じ Chromium プロファイルの同時起動を防ぐ。
