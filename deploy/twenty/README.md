# Twenty(t.doany.io)

取引先・人・商談(CRM)と、メモ・タスク・独自の表を 1 か所に置く。手続きの記録やタスクボード、事業の検討書もここ。
ログインは Microsoft(Entra ID)だけ。AI(Claude Code)からは組み込みの MCP か REST / GraphQL の API で読み書きする。

上流: <https://github.com/twentyhq/twenty>(AGPL-3.0。`@license Enterprise` の付いた部分(SSO・監査ログなど)は商用で、使っていない)。

| ファイル | 中身 |
| --- | --- |
| [twenty.yaml](twenty.yaml) | 本体の server(画面・API・MCP)と worker(ジョブ)、共通の設定、添付ファイルの PVC |
| [postgres.yaml](postgres.yaml) | DB(PostgreSQL 18 系) |
| [redis.yaml](redis.yaml) | キャッシュとジョブの列。PVC は持たない |
| [httproute.yaml](httproute.yaml) | `t.doany.io`。全部 3000 に流す |
| [secrets.sops.yaml](secrets.sops.yaml) | 秘密(SOPS)。DB と Redis のパスワード、暗号化の鍵、Microsoft のクライアントシークレット、VolSync の分 |
| [volsync.yaml](volsync.yaml) | バックアップ(VolSync。DB と添付の PVC をスナップショットから) |

## 誰が入れるか

- **ログインは Microsoft だけ。** パスワードは止めてある(`AUTH_PASSWORD_ENABLED=false`)
- **アプリ登録は Twenty 専用の `twenty`**([pulumi/entra-twenty.ts](../../pulumi/entra-twenty.ts))。
  Twenty は認可の入口を `common` に決め打ちしていて、自分のテナント専用の共用のアプリ登録 Main では弾かれる(AADSTS50194)。
  そのためこのアプリだけマルチテナントにしてあり、**ほかのテナントの人もサインインの画面までは来られる**
- **入れる人は Twenty の側で絞る。** ワークスペースは 1 つだけで、作ったあとは招待か「許可したドメイン」の人しか登録できない
  (`IS_WORKSPACE_CREATION_LIMITED_TO_SERVER_ADMINS`)。許可したドメインは `doany.io` だけ(設定 › セキュリティ。DB に持つ)
- 識別に使うのは Microsoft のアカウントの UPN(`info@doany.io` など)

## 最初のワークスペース

ワークスペースが無いうちは、**最初に入った人がワークスペースを作り、管理者になる**。経路ができたらすぐ info@doany.io で入って作り、
設定 › メンバーで持ち主が info@doany.io であることを確かめる。ほかの人に先に作られていたら、DB の PVC を消して作り直す
(ワークスペースはまだ空なので失うものは無い)。作ったら、設定 › セキュリティで次をする。

- 許可するドメインに `doany.io` を足す(確かめのメールは info@doany.io に届く)
- 招待のリンクを止める

## 鍵

- `encryption-key` は DB の中の秘密(API キーなど)を暗号化する。**変えると読めなくなる。** 替えるときは、古い値を
  `FALLBACK_ENCRYPTION_KEY` に入れて新しい値を入れる(上流の .env.example)
- `microsoft-client-secret` には期限がある(テナントの方針で最長 180 日。今のものは 2027-05-17 まで)。切れたらサインインできなくなる。
  画面で作り直して `tools/t sops edit secrets.sops.yaml` で差し替える

## 気にしておくこと

- **版。** `twentycrm/twenty:vX.Y.Z`。server が起きるたびに DB の移行(`upgrade`)が走る。版を飛ばすと移行が長くなる。
  上流の Helm chart は古いので使わず、上流の compose(`packages/twenty-docker/docker-compose.yml`)に合わせて書いている
- **メールとカレンダーの同期は使っていない。** 使うならアプリ登録に Graph の Mail.ReadWrite・Mail.Send・Calendars.ReadWrite を足し、
  `MESSAGING_PROVIDER_MICROSOFT_ENABLED` などを true にする(Microsoft 365 のライセンスが要る)
- **メールを送らない。** `EMAIL_DRIVER` は既定のまま(ログに出すだけ)。招待のメールは届かないので、許可したドメインで入ってもらう
