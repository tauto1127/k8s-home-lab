# PR2 セキュリティ監査と判断記録

確認日: 2026-09-06

## Credential remediation

- `pg-app-user`の履歴上のliteral credentialは実値と分類し、2026-09-06にローテーションした。
  GSM `pg-app-user-password`はversion 1--4をDISABLED、version 5をENABLEDにした。
  値、fingerprint、verifier、hashは記録・表示しない。
- `pg/pg-app-user`はExternalSecret `Ready=True` / `SecretSynced`、targetは
  `pg-app-user`、remote keyは`pg-app-user-password`である。
- CNPG `my-pgsql-cluster`はhealthy、2/2 ready。`app_user`はlogin enabledかつ
  superuserではない。ローテーション後のpassword-auth `SELECT 1`に成功し、確認時の
  active connectionsは0だった。
- Dashboard JWTは`kubernetes-dashboard/root` ServiceAccount用のRS256 token 1件。
  期限切れで、liveに永続的なServiceAccount-token Secretはなく、追加ローテーションは
  実施しなかった。
- GrafanaのGitGuardian 7件は`passwordKey: grafana`という参照キーであり、literal
  valueではないfalse positiveと分類した。

## History rewrite decision

mainの履歴rewriteは実施しない。実効性のあるcredentialはローテーションまたは期限切れ
で無効化し、Grafana検知は参照キーのfalse positiveである。共有履歴のforce rewriteは
影響が大きく、今回のリスク低減に対して不釣り合いと判断した。GitGuardian側のincident
status分類は必要ならUIで別途行う。

この文書は分類とメタデータだけを記録し、Secretの値、token、fingerprint、hashを含めない。rotation記録はrepo/CIから独立検証できない運用証跡であり、activation safetyの自動証明ではない。
