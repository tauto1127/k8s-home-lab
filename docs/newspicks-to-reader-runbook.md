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
      → Service/newspicks-to-reader-fulltext:8790   (fulltext.py, Playwright 常駐)
        → Readwise Reader API /api/v3/save/
```

- Namespace: `newspicks-to-reader`
- Image: `ghcr.io/tauto1127/newspicks-to-reader:0.1.0@sha256:0f683355996e1e0097ac24ae30da9f6abed42702c6c8934f2152febf499e1679`（`containers/newspicks-to-reader/` から GitHub Actions で build、digest は 2026-11-14 の main build）
- PVC: `newspicks-to-reader-profile`、`nfs-client`、2Gi、RWO（Playwright のプロファイル＝NewsPicks のログインセッションを保持）
- Secret: `newspicks-to-reader-secrets`（ExternalSecret → ClusterSecretStore `secret-store-provider`）
  - `newspicks-to-reader-readwise-token` → `READWISE_TOKEN`
  - `newspicks-to-reader-home-token` → `NP2R_HOME_TOKEN`
  - `newspicks-to-reader-fulltext-token` → `NP2R_FULLTEXT_TOKEN`
- Ingress: `newspicks-to-reader.takutk.com`（class `kong`、TLS は既存の Kong に任せる）
- 外部公開は Cloudflare Tunnel 側で `newspicks-to-reader.takutk.com` を受ける（別エージェントの作業）

## 有効化

`prune: false` を維持する。CLI resume は使わない。

1. Preparation（このPR）: 外側 `suspend: true`、marker あり。namespace と ExternalSecret は作られない。
2. Config activation（別PR）: 外側 `suspend: false`、marker を外す。namespace / PVC / ExternalSecret / Deployment が作られる。
   この時点で `fulltext` は起動するが、NewsPicks 未ログインなので `/fetch` は `not_logged_in` を返す。
3. ログイン（手動 1 回）: `kubectl -n newspicks-to-reader port-forward deploy/newspicks-to-reader-fulltext 8790:8790` して
   `POST /login/submit` に 1Password から取り出した認証情報を投げる、または VNC で Chromium を操作する。
   以後は PVC 上のプロファイルで自動。パスワードは保存しない。
4. iOS ショートカット作成（`docs/newspicks-to-reader-shortcut.md`）。

## ロールバック

Git で preparation の停止状態へ戻す。uninstall と `prune: true` はしない。
PVC は `Retain` 相当で残るため、再開時にログインをやり直す必要はない。

## 既知の制約

- 画像は amd64 のみ。クラスタは amd64 ノードのみなので問題ない。
- Playwright は 1 ブラウザ・1 記事ずつ。`Recreate` 戦略で並列化しない（bot 判定回避）。
- プレミアム本文の取得は「自分の購読で読める内容を自分の Reader に送る」用途に限定する。
- NewsPicks 側の仕様変更で壊れたら `extract_body_html()` のセレクタを直す。
