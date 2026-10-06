# zulip

Zulip(`z.doany.io`)。**Mattermost(`mm.doany.io`)からの移行先**(2026-10-05 に決めた)。

| | |
| --- | --- |
| 本体 | 公式の Helm chart(`ghcr.io/zulip/helm-charts/zulip`)を [application.yaml](application.yaml) で。Zulip 12.3 |
| DB | **PGroonga 入りの Postgres 17**([postgres.yaml](postgres.yaml))。日本語の全文検索のため |
| 脇役 | RabbitMQ / memcached / Redis を公式イメージで素に([services.yaml](services.yaml))。chart 同梱の Bitnami(更新が止まった `bitnamilegacy`)は使わない |
| ログイン | **Entra ID だけ**(汎用 OIDC。auth / argocd / erpnext / mattermost と同じアプリ登録)。パスワードのログインは無い |
| メール | Exchange Online の SMTP AUTH(info@doany.io) |
| プッシュ通知 | Zulip の中継サービス(Mobile Push Notification Service) |
| 通話 | **meet.jit.si**(Zulip の既定)。Mattermost Calls の代わり。サーバー側には何も無い |
| バックアップ | k8up。DB は pg_dump、添付ファイルは PVC `zulip-data`([../k8up/schedules.yaml](../k8up/schedules.yaml)。14:00 UTC) |

## 使い始め

### 1. Infisical に値を入れる(`/zulip/zulip`)

| キー | 値 |
| --- | --- |
| `postgres-password` `rabbitmq-password` `memcached-password` `redis-password` | 長いランダム文字列(`openssl rand -hex 32`)。サービス間の合言葉 |
| `secret-key` | 長いランダム文字列(`openssl rand -base64 48`)。**変えるとセッションが全部切れる** |
| `smtp-password` | `/mattermost/mattermost` の `smtp-password` と同じ値 |
| `oidc-client-secret` | `/mattermost/mattermost` の `oidc-client-secret` と同じ値 |

**入れてからマージする。** 足りないと Pod が `CreateContainerConfigError` で止まる
(`zulip-org-id` / `zulip-org-key` だけは後で入れる。下の 4)。

### 2. Entra にリダイレクト URI を足す

アプリ登録 `b0fa498f-…` の「認証」→ Web のリダイレクト URI に **`https://z.doany.io/complete/oidc/`**。
手順は [../../docs/entra.md](../../docs/entra.md)。

### 3. Mattermost のデータを取り込む

マージすると Zulip は**組織の無い空の状態**で上がる。そこへ Mattermost のチーム `doa`(1 つだけ)を流し込む。
**取り込みは空のサーバーにしかできない**(やり直すなら DB を作り直す)。

```shell
# Mattermost 側: 添付込みで書き出す(7.3 以降は添付が既定で入る)
kubectl -n mattermost exec deploy/mattermost -- /mattermost/bin/mmctl --local export create
kubectl -n mattermost exec deploy/mattermost -- /mattermost/bin/mmctl --local export list
kubectl -n mattermost exec deploy/mattermost -- /mattermost/bin/mmctl --local export download <名前>.zip /tmp/mm.zip
kubectl -n mattermost cp mattermost/<pod>:/tmp/mm.zip ./mm.zip -c mattermost

# Zulip 側: /data(PVC)に置いて変換 → 取り込み
kubectl -n zulip cp ./mm.zip zulip-0:/data/mm.zip -c zulip
kubectl -n zulip exec zulip-0 -c zulip -- bash -euc '
  cd /data && rm -rf mm conv && mkdir mm && unzip -q mm.zip -d mm
  mv mm/import.jsonl mm/export.json
  chown -R zulip:zulip /data/mm
  runuser -u zulip -- /home/zulip/deployments/current/scripts/stop-server
  runuser -u zulip -- /home/zulip/deployments/current/manage.py convert_mattermost_data /data/mm --output /data/conv
  runuser -u zulip -- /home/zulip/deployments/current/manage.py import "" /data/conv/doa
  runuser -u zulip -- /home/zulip/deployments/current/scripts/start-server'

# 自分をオーナーに(取り込んだ組織では誰もオーナーになっていないことがある)
kubectl -n zulip exec zulip-0 -c zulip -- runuser -u zulip -- \
  /home/zulip/deployments/current/manage.py change_user_role -r '' info@doany.io owner

# 最初のチャンネルを Zulip の既定に揃える(Town Square → general、Off-Topic → sandbox、Zulip を作る)
kubectl -n zulip exec -i zulip-0 -c zulip -- runuser -u zulip -- \
  /home/zulip/deployments/current/manage.py shell < apps/zulip/post-import.py
```

**最初のチャンネルは Mattermost に従わず、Zulip の既定に揃える**(本人、2026-10-05)。Mattermost の
Town Square と Off-Topic は投稿が参加の 1 件ずつしかなかった(中身は `notify-*` にある)。
[post-import.py](post-import.py) が次のようにする(何度流しても同じ結果になる)。

| Zulip | 役目 | 元 |
| --- | --- | --- |
| `general` | 組織全体の会話。新しいチャンネルと Zulip の更新のお知らせもここ | Town Square |
| `sandbox` | 試し書き | Off-Topic |
| `Zulip` | Zulip の使い方の質問と話し合い | 新しく作る |

名前は英語のまま(Zulip の日本語訳でも名前は訳さない)、説明は Zulip の日本語訳の文。3 つとも新しく入った人が
自動で参加するチャンネルにする。`notify-*` はそのまま移る。

- チャンネル → ストリーム、DM → DM、リアクション・添付・カスタム絵文字は移る
- **ユーザーはメールアドレスで Entra に結びつく。** 取り込んだ人は Entra で入ればそのまま自分のアカウント。
  `auto_signup` は切ってある(取り込んでいない人は招待してから)
- 終わったら `/data/mm*` と `/data/conv` は消す(PVC はバックアップされるので、残すと R2 に乗る)

### 4. プッシュ通知の中継に登録する

```shell
kubectl -n zulip exec -it zulip-0 -c zulip -- runuser -u zulip -- \
  /home/zulip/deployments/current/manage.py register_server
```

規約に同意すると登録される。**できた 2 つの値を Infisical に入れる**(コンテナの中のファイルは起動のたびに描き直されるので、
そのままだと再起動で登録が消える):

```shell
kubectl -n zulip exec zulip-0 -c zulip -- /home/zulip/deployments/current/scripts/get-django-setting ZULIP_ORG_ID
kubectl -n zulip exec zulip-0 -c zulip -- /home/zulip/deployments/current/scripts/get-django-setting ZULIP_ORG_KEY
```

→ Infisical `/zulip/zulip` の `zulip-org-id` / `zulip-org-key`。

### 5. 通知の送り先を Zulip に替える

Zulip で**受け口用の bot**(Incoming webhook bot)を作り、その API キーで URL を作る。送り元ごとに
**ストリームとトピックを URL で分けられる**(Mattermost は webhook ごとにチャンネル固定だった)。

```
https://z.doany.io/api/v1/external/slack_incoming?api_key=<bot の API キー>&stream=<ストリーム>&topic=<トピック>
```

**どれも Slack 互換の形(`{"text": …}` や attachments)で送っている**ので、URL を替えるだけでよい。

| Mattermost の webhook | 送り元 | URL の在処 |
| --- | --- | --- |
| server | k8up の notify / ホストのバックアップ | Infisical `/k8up/k8up-global` の `mattermostWebhook` と、ホストの `/etc/k3s-backup/env`(`MATTERMOST_WEBHOOK`。`recovery/env.age` も作り直す) |
| ArgoCD | Argo CD の通知 | `bootstrap/argocd/helmchart.yaml`(SOPS)の `service.webhook.mattermost` |
| ashi | ashi | ashi の `NOTIFY_WEBHOOK_URL`(Infisical) |
| shadai | todoroku | todoroku の `MATTERMOST_WEBHOOK_URL`(Infisical) |
| worklog | worklog | worklog-cloud の `MATTERMOST_WEBHOOK_URL`(Infisical) |
| denpa | denpa | denpa の設定(Infisical) |
| Forgejo | Forgejo のリポジトリの webhook | Forgejo の画面。**Zulip の Gitea 用の受け口**(`/api/v1/external/gitea`)に向け、Forgejo 側の種類を Gitea にする |

### 6. Mattermost を畳む

しばらく並べて動かし、通知が全部 Zulip に来るのを確かめてから:

- `apps/mattermost/` を消す(Argo CD が prune する。PVC も消える ── 最後の pg_dump は R2 に残る)
- ルーターの **8443(Calls)の転送**を消す
- Entra のリダイレクト URI から `https://mm.doany.io/signup/office365/complete` を消す
- Infisical の `/mattermost/mattermost` を消す
- k8up の通知が `mattermost/…` を「25 時間以上更新されていない」と言い出すので、
  `restic tag --host mattermost --add retired`([../k8up/README.md](../k8up/README.md)「やめたアプリの残り」)

## 決めたこと

- **Helm chart の同梱サービスは使わない。** Bitnami のイメージが更新されないため。chart は外部のサービスの
  パスワードを Secret の参照で受けられるので、秘密を values に書かずに済む
- **PGroonga。** Zulip の標準の全文検索は英語だけ。PGroonga の公式イメージには Zulip の英語の辞書が無いので、
  `postgresql.missing_dictionaries` で辞書無しで DB を作る(初回だけ効く。**後から PGroonga に替えるのは手間**なので最初から)。**拡張(`CREATE EXTENSION pgroonga`)は Zulip のマイグレーションは作らない**ので、Postgres の初期化(`postgres.yaml` の initdb)で作る ── 無いと初回の migrate が `access method "pgroonga" does not exist` で落ちる(2026-10-06 に踏んだ)
- **汎用 OIDC で Entra に繋ぐ。** Zulip の AzureAD 用のバックエンドはテナント共通の口を叩くので、単一テナントのアプリ登録では通らない
- **通話は meet.jit.si。** 自前の通話サーバーは持たない(Mattermost Calls の hostPort とルーターの転送が不要になる)
