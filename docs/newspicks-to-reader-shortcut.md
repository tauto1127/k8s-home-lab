# newspicks-to-reader の iOS ショートカット

NewsPicks アプリの共有シートから 1 タップで Reader に入れるための設定。

## 前提

- `https://newspicks-to-reader.takutk.com` が Cloudflare Tunnel で自宅クラスタへ届いている
- Secret `newspicks-to-reader-secrets` の `NP2R_HOME_TOKEN` を控えてある

## ショートカット「NewsPicks to Reader」

1. 新規ショートカット → ⓘ → **共有シートに表示** を ON、入力タイプは **URL** のみ。
2. アクション:

   | # | アクション | 設定 |
   |---|---|---|
   | 1 | ショートカットの入力を受け取る | 共有シート / URL |
   | 2 | URL を取得 | 入力 |
   | 3 | テキスト | `https://newspicks-to-reader.takutk.com/ingest` |
   | 4 | URL の内容を取得 | 3 の URL、方法 **POST**、要求本文 **JSON**、ヘッダ `x-np2reader-token: <NP2R_HOME_TOKEN>` |
   | 5 | 辞書を取得 | 4 の結果から `ok` |
   | 6 | 結果を表示 | 4 の結果 |

   4 の要求本文（JSON）:

   ```json
   {
     "path": "save",
     "url": "<2 の URL>"
   }
   ```

3. 名前を「NewsPicks to Reader」で保存。

### 共有シートに URL が出てこない場合

NewsPicks アプリは共有時に URL ではなく本文テキストを渡すことがある。
その場合は 2 を「テキストから URL を抽出」（正規表現 `https://newspicks\.com/news/\d+`）に置き換える。

## ニュースレターを毎朝まとめて送る

別ショートカット「NP Newsletter to Reader」を作り、要求本文を `{"path": "newsletter", "n": 1}` にする。
オートメーション（毎朝 7:00）に置けば、前日のダイジェストが Reader の Inbox に入る。

## 動作確認

```bash
curl -sS -X POST https://newspicks-to-reader.takutk.com/ingest \
  -H "x-np2reader-token: $NP2R_HOME_TOKEN" \
  -H "content-type: application/json" \
  -d '{"path":"save","url":"https://newspicks.com/news/17906125/"}'
```

`[fulltext via browser]` が返ればプレミアム本文まで取れている。`[partial: paywall]` ならログインが切れている。

## トークンの扱い

- `NP2R_HOME_TOKEN` はショートカット内にだけ置き、スクショ共有しない。
- 漏れたら Bitwarden/GSM の `newspicks-to-reader-home-token` を差し替え、ExternalSecret の refresh を待ってショートカットを更新する。
