# newspicks-to-reader の activation runbook

## このPRの範囲

newspicks-to-reader の **app activation**。外側 `Kustomization/newspicks-to-reader` の
`suspend: true` と `flux.takutk.com/activation-blocked: "true"` を外す。
merge すると Flux が namespace / ExternalSecret / PVC / Deployment×2 / Service×2 / Ingress を apply する。
クラスタへの手動 apply、`flux resume`、手動 reconcile はしない。

## 構成

preparation と同じ。image は digest 固定:

`ghcr.io/tauto1127/newspicks-to-reader:0.1.0@sha256:4e4b31fa5e52a9cdb63b4757cf6225dced8a8d0713b4672f08f013922c8777b2`

## 前提（merge 前に済ませる）

1. **image pull**  
   GHCR の package は private。`namespace newspicks-to-reader` に imagePullSecret を置くか、
   package を public にする。private のままなら activation で `ImagePullBackOff` になる。
2. **ExternalSecret の remote key 3 件**
   - `newspicks-to-reader-readwise-token`
   - `newspicks-to-reader-home-token`
   - `newspicks-to-reader-fulltext-token`
   `Secret/newspicks-to-reader-secrets` が `SecretSynced` にならないと Deployment は起動しない。
3. **Cloudflare Tunnel**
   `newspicks-to-reader.takutk.com` → Kong（`192.168.11.211:80`）の ingress を追加する。

## 有効化

`prune: false` を維持する。CLI resume は使わない。

1. Preparation（#71, #72 で完了）
2. App activation（このPR）: 外側 `suspend: false`、marker を外す。
   `fluxActivation.activeKustomizations` に inventory を追加し、
   `scripts/validate-flux-ownership.rb` の phase 境界フィルタに `newspicks-to-reader` を追加する。

## merge 後の確認

```sh
kubectl -n newspicks-to-reader get all,externalsecret,pvc,ingress
kubectl -n newspicks-to-reader logs deploy/newspicks-to-reader-ingest
kubectl -n newspicks-to-reader logs deploy/newspicks-to-reader-fulltext
```

`fulltext` は NewsPicks 未ログインのため `/fetch` が `not_logged_in` を返すのが正常。

## ログイン（手動 1 回）

```sh
kubectl -n newspicks-to-reader port-forward deploy/newspicks-to-reader-fulltext 8790:8790
curl -sS localhost:8790/login/status -H "x-np2reader-token: $NP2R_FULLTEXT_TOKEN"
curl -sS -X POST localhost:8790/login/submit \
  -H "x-np2reader-token: $NP2R_FULLTEXT_TOKEN" -H "content-type: application/json" \
  -d '{"email":"...","password":"..."}'
```

パスワードは保存しない。プロファイルは PVC `newspicks-to-reader-profile` に残る。

## ロールバック

Git で preparation の停止状態へ戻す。uninstall と `prune: true` はしない。
