# infisical

https://il.doany.io -- セルフホストの Infisical。中身の説明は上位の README の「Secret」を参照。

## 管理者アカウント

初期化(`POST /api/v1/admin/bootstrap`)で作った `admin@doany.io` は現存しない
(2026-09-02 にログインを試して "Failed to find user")。いまの管理者は個人アカウントで、
資格情報はこのリポジトリに置かない。

ロックアウトしたときの復旧は、SMTP(info@doany.io 経由)が生きていればログイン画面の
パスワードリセット。それも届かない場合は `infisical` ns の PostgreSQL に入って
`users` テーブルから管理者を特定し、Infisical のドキュメントにある手順でリセットする。

初期化で一緒に作られる "Instance Admin Identity"(root 相当の Machine Identity)は
セットアップ後に削除してある。必要なら UI の Organization Settings > Identities で作り直す。
