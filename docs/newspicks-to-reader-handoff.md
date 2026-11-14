# newspicks-to-reader の現状と残作業

最終更新: 2026-11-14

## いまの状態

| 項目 | 状態 |
|---|---|
| Flux パッケージ | **app-active**（`suspend: false`）。#71 で追加、#73 で活性化 |
| image | `ghcr.io/tauto1127/newspicks-to-reader:0.1.0@sha256:917378f6244b9d8b15f41d3ed28319cd9155da2f62cc9ea1ca5e05b8b849b360` |
| Namespace / PVC / Ingress / Service | 作成済み（PVC は Bound、Ingress は Kong で `newspicks-to-reader.takutk.com`） |
| `ingest` | コンテナは起動する（`/health` 応答を確認済み）。Secret 未作成のため `CreateContainerConfigError` |
| `fulltext` | Chromium 起動まで到達（`xvfb-run` 経由、`/health` が `{"ok": true, "logged_in": false}` を返すことを確認済み）。Secret 未作成のため待機中 |

## ブロッカー（この2つで動き出す）

1. **GSM に remote secret 3 件を作成**
   - `newspicks-to-reader-readwise-token` … https://readwise.io/access_token
   - `newspicks-to-reader-home-token` … 任意のランダム文字列（Worker と共有）
   - `newspicks-to-reader-fulltext-token` … 任意のランダム文字列
   `ExternalSecret/newspicks-to-reader-secrets` が `SecretSynced` になれば Pod が起動する。

2. **Cloudflare Tunnel に `newspicks-to-reader.takutk.com` → `http://192.168.11.211:80`（Kong）を追加**

## そのあと

1. 初回ログイン（手動 1 回）
   ```sh
   kubectl -n newspicks-to-reader port-forward deploy/newspicks-to-reader-fulltext 8790:8790
   curl -sS localhost:8790/login/status -H "x-np2reader-token: $NP2R_FULLTEXT_TOKEN"
   curl -sS -X POST localhost:8790/login/submit \
     -H "x-np2reader-token: $NP2R_FULLTEXT_TOKEN" -H "content-type: application/json" \
     -d '{"email":"...","password":"..."}'
   ```
2. iOS ショートカット作成（`docs/newspicks-to-reader-shortcut.md`）
3. 疎通確認
   ```sh
   curl -sS -X POST https://newspicks-to-reader.takutk.com/ingest \
     -H "x-np2reader-token: $NP2R_HOME_TOKEN" -H "content-type: application/json" \
     -d '{"path":"save","url":"https://newspicks.com/news/17906125/"}'
   ```
   `[fulltext via browser]` が返ればプレミアム本文まで取れている。

## クラスタで踏んだ落とし穴（再発防止メモ）

| 症状 | 原因 | 対処 |
|---|---|---|
| build が 127 で落ちる | `playwright install --with-deps` が PATH 上の python を要求 | 公式 python イメージに venv は無い。`python -m playwright install-deps` を先に実行 |
| `libatomic.so.1` が無い | slim イメージに無い | `libatomic1` を apt で追加 |
| `Executable doesn't exist at /home/np2r/.cache/...` | ブラウザは root の `/root/.cache` に入る | `PLAYWRIGHT_BROWSERS_PATH=/ms-playwright` |
| `/root` 配下が読めない | `/root` は 0700 | 共有パスへ |
| `Missing X server or $DISPLAY` | このイメージの Chromium は X 必須 | `xvfb` を入れ、`xvfb-run` 配下で起動 |
| `xvfb-run: 0: not found` | `sh -c` で `--server-args` の値が分割 | 値を引用符で囲む |
| コンテナが終了しない | `command` に xvfb-run を置くと PID 1 になる | `exec xvfb-run ...` |
| `profile appears to be in use` | PVC に SingletonLock が残る | 起動時に `Singleton*` を削除（実装済み） |

## 注意

- `fulltext` は 1 ブラウザ・1 記事ずつ。並列化しないこと（bot 判定とプロファイルロックの両方で壊れる）。
- 検証時は Secret を差し替えると Deployment が Flux に巻き戻される。一時的な検証は `kubectl patch` を都度当て直す。
