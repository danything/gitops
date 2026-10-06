# GlitchTip(gt.doany.io)

エラー収集。Sentry 互換で、Sentry の SDK(Android・JavaScript ほか)がそのまま送れる。
denpa-tv(Android TV)のクラッシュと例外を受けるために置いた(2026-10-06)。denpa の Web からも送れる。
MIT。上流: <https://gitlab.com/glitchtip/glitchtip-backend>

| ファイル | 中身 |
| --- | --- |
| [glitchtip.yaml](glitchtip.yaml) | 本体(`glitchtip/glitchtip:X.Y.Z`)。画面・API・取り込み・ワーカーを 1 Pod で。Valkey は置かない。chart を使わない理由はファイルの先頭 |
| [postgres.yaml](postgres.yaml) | DB(イベントもここ)。rybbit と同じ 17 系、`pg_dump` を k8up に |
| [glitchtip-secrets.yaml](glitchtip-secrets.yaml) | Infisical `/glitchtip/glitchtip` の 4 キー → Secret `glitchtip` |
| [httproute.yaml](httproute.yaml) | `gt.doany.io`。SSO の前段は置かない(取り込みはアプリが直接叩くため。理由はファイルに) |

バックアップは [../k8up/schedules.yaml](../k8up/schedules.yaml) の `glitchtip`(PostgreSQL は `pg_dump`、アップロードの PVC はファイルとして)。

## 使い始め

1. **Infisical に入れる(同期より先に)。** フォルダ `/glitchtip/glitchtip` に 4 つ。中身は
   [glitchtip-secrets.yaml](glitchtip-secrets.yaml) の表
   - `secret-key` ── 英数字のランダム(`openssl rand -hex 32` など)
   - `postgres-password` ── 英数字のランダム。postgres は最初の起動でしかパスワードを設定しないので、**後から変えるなら DB 側も変える**
   - `oidc-client-secret` ── `${prod.auth.auth-secrets.oidc-client-secret}`(値は写さず参照)
   - `email-password` ── `/mattermost/mattermost` の `smtp-password` と同じ参照
2. **Entra のアプリ登録 Main のリダイレクト URI(Web)に `https://gt.doany.io/accounts/oidc/entra/login/callback/` を足す**
   (末尾の `/` まで完全一致)
3. main にマージ → ArgoCD が同期。初回は initContainer の `setup` がテーブルを作り、
   **管理者 `info@doany.io` を作る**(パスワードは使えない値)。ログに「最初の管理者を作った」と出る。
   ユーザーが 1 人もいない間は登録が開いてしまう作りなので、公開と同時に埋めている
4. **パスワードを決める。** <https://gt.doany.io> のログイン画面 →「Forgot password」→ `info@doany.io`。
   届いたメールのリンクで設定する。メールが届かないときは Pod の中で:

   ```shell
   kubectl -n glitchtip exec -it deploy/glitchtip -c glitchtip -- ./manage.py changepassword info@doany.io
   ```

5. ログインして**組織を作る**(例: `doany`)。`ENABLE_ORGANIZATION_CREATION=false` でも、最初の 1 つと管理者(superuser)は作れる
6. **Entra を繋ぐ。** プロフィール →「Social Auth Accounts」→「Entra ID」。以後は Entra のボタンで入れる。
   **繋いでいない Entra のアカウントでは入れない**(登録を閉じているので、メールが同じでも自動では紐付かない)
7. プロジェクト `denpa-tv`(Android)を作り、DSN(`https://<公開鍵>@gt.doany.io/<番号>`)を denpa-tv の Sentry SDK に入れる

**人を足すとき。** 登録を閉じていると、**招待できるのは GlitchTip に既にいるユーザーだけ**
(`apps/organizations_ext/api.py` の「Only existing users may be invited」)。先に Django の管理画面
(<https://gt.doany.io/admin/>、superuser で入れる)でユーザーを作り、その人がパスワード再設定 → 組織の
「メンバー」から招待、の順。何人もまとめて足すなら一時的に `ENABLE_USER_REGISTRATION` を `"true"` にする PR を出して戻す。

## 気にしておくこと

- **`http://` で Entra に飛ぶなら `TRUSTED_PROXIES` がずれている。** GlitchTip は Gateway の
  `X-Forwarded-Proto` を信じる相手を [glitchtip.yaml](glitchtip.yaml) の `TRUSTED_PROXIES`(Pod の CIDR、
  `10.42.0.0/16`)で決めている。2026-10-06 時点で Gateway(Cilium の Envoy)から来る接続の送り元は
  `10.42.0.148`(CiliumInternalIP)。ここがずれると GlitchTip が自分を `http://` だと思い、Entra に渡す
  `redirect_uri` もパスワード再設定メールのリンクも `http://` になる。Entra は `AADSTS50011` で弾く
- **保持は 30 日**(`GLITCHTIP_RETENTION_DAYS`)。古いパーティションは中のスケジューラが落とす
- **メモリ。** 実測 200 MiB 弱(ローカルで 6.2.6、イベント数件)。limit 1 GiB、ワーカーは RSS 400 MiB で
  入れ替わる(`GRANIAN_WORKERS_MAX_RSS`。理由は glitchtip.yaml)
- **Valkey は無い。** キャッシュとタスクのキューは Postgres。取り込みが多くなって詰まるようなら
  Valkey を足して `VALKEY_URL` を入れる(上流の構成。Redis 互換なら何でもよい)
- **版。** Docker Hub のタグ `X.Y.Z`(`6.2.6` など)。Renovate が PR を出す。PostgreSQL は `renovate.json` で 17 の線に留めてある
- **7.0(未リリース)で web と worker の分割が無くなる。** いまの形(all-in-one 1 つ)は 7.0 の形と同じなので、
  上がるときに作り直しは要らないはず。`GLITCHTIP_EMBED_WORKER` は 7.0 で警告なしに無視される
- **PSA は baseline。** hostPort も特権も要らない。Talos に移ったときそのまま通る
