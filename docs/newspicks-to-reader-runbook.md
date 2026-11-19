# newspicks-to-reader の Flux 移行 runbook

## このPRの範囲

newspicks-to-reader の **preparation**。新規 workload なので adopt はない。
外側 `Kustomization/newspicks-to-reader` と内側 `HelmRelease` の代わりに raw Deployment を置き、
外側 Kustomization は `suspend: true`、`prune: false`、`flux.takutk.com/activation-blocked: "true"` で停止したまま merge する。
クラスタへの手動 apply、`flux resume`、手動 reconcile はしない。

## 構成

```
iOS NewsPicks アプリ ─共有→ ショートカット
  → https://newspicks-to-reader.takutk.com/ingest   (Kong Ingress)
    → Service/newspicks-to-reader-ingest:8787       (ingest_server.py)
      → Service/newspicks-to-reader-fulltext:8790   (fulltext.py, 必要時に Chromium を起動)
        → Readwise Reader API /api/v3/save/
```

- Namespace: `newspicks-to-reader`
- Image: `containers/newspicks-to-reader/` から GitHub Actions でビルドする。両 Deployment で同じイメージ digest を指定する。
- PVC: `newspicks-to-reader-profile`、`nfs-client`、2Gi、RWO（Playwright のプロファイル＝NewsPicks のログインセッションを保持）
- Secret: `newspicks-to-reader-secrets`（ExternalSecret → ClusterSecretStore `onepassword`）
  - `newspicks-to-reader-readwise-token/credential` → `READWISE_TOKEN`
  - `newspicks-to-reader-home-token/password` → `NP2R_HOME_TOKEN`
  - `newspicks-to-reader-fulltext-token/password` → `NP2R_FULLTEXT_TOKEN`
- Ingress: `newspicks-to-reader.takutk.com`（class `kong`、TLS は既存の Kong に任せる）
- 外部公開は Cloudflare Tunnel 側で `newspicks-to-reader.takutk.com` を受ける（別エージェントの作業）

## 有効化

`prune: false` を維持する。CLI resume は使わない。

1. Preparation（このPR）: 外側 `suspend: true`、marker あり。namespace と ExternalSecret は作られない。
2. Config activation（別PR）: 外側 `suspend: false`、marker を外す。namespace / PVC / ExternalSecret / Deployment が作られる。
   この時点で `fulltext` は起動するが、NewsPicks 未ログインなので `/fetch` は `not_logged_in` を返す。
3. ログイン（手動 1 回）: `kubectl -n newspicks-to-reader port-forward deploy/newspicks-to-reader-fulltext 8790:8790` して
   `x-np2reader-token` に `NP2R_FULLTEXT_TOKEN` を指定し、`POST /login/submit` へ NewsPicks の認証情報を送る。
   以後は PVC 上のプロファイルで自動。パスワードは保存しない。
4. iOS ショートカット作成（`docs/newspicks-to-reader-shortcut.md`）。

稼働確認は両 Service の `GET /health`。NewsPicks のセッション確認は別に `GET /login/status` を使い、
`fulltext` に直接接続する場合は `NP2R_FULLTEXT_TOKEN`、`ingest` 経由の場合は `NP2R_HOME_TOKEN` を指定する。

## ロールバック

Git で preparation の停止状態へ戻す。uninstall と `prune: true` はしない。
PVC は `Retain` 相当で残るため、再開時にログインをやり直す必要はない。

## 既知の制約

- 画像は amd64 のみ。クラスタは amd64 ノードのみなので問題ない。
- Playwright は 1 ブラウザ・1 記事ずつ。`Recreate` 戦略で並列化しない（bot 判定回避）。
- プレミアム本文の取得は「自分の購読で読める内容を自分の Reader に送る」用途に限定する。
- NewsPicks 側の仕様変更で壊れたら `extract_body_html()` のセレクタを直す。
