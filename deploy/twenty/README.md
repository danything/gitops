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
  そのためこのアプリだけ外に開いてある(`AzureADandPersonalMicrosoftAccount`)。**ほかのテナントの人も、個人の Microsoft アカウント
  (outlook.com など)の人も、サインインの画面までは来られる**。個人のアカウントを入れたのは、持ち主の普段の予定(y16m@outlook.com)を
  同期につなぐため(下の「メールとカレンダーの同期」)
- **入れる人は Twenty の側で絞る。** ワークスペースは 1 つだけで、作ったあとは招待か「許可したドメイン」の人しか登録できない
  (`IS_WORKSPACE_CREATION_LIMITED_TO_SERVER_ADMINS`)。許可したドメインは `doany.io` だけ(設定 › セキュリティ。DB に持つ)
- **個人のアカウントで入られる心配は無い。** 個人のアカウントの名前(UPN)はそのメールアドレスで、作るときにそのアドレスでメールを
  受けて確かめる。`@doany.io` のメールを受けられるのは自分のテナントだけなので、他人が `@doany.io` の個人のアカウントを作って
  許可したドメインを通ることはできない。それ以外のアドレス(`@outlook.com` など)は招待が無ければ登録で弾かれる
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

## メールとカレンダーの同期

設定 › アカウントで Microsoft のアカウントをつなぐと、そのメールと予定を取り込む(`MESSAGING_PROVIDER_MICROSOFT_ENABLED`・
`CALENDAR_PROVIDER_MICROSOFT_ENABLED`)。つなぐのは info@doany.io(仕事)と y16m@outlook.com(個人。普段の予定はこちら)。

- **アプリ登録は同じ `twenty`。** つなぐときの戻り先は `/auth/microsoft-apis/get-access-token`(`AUTH_MICROSOFT_APIS_CALLBACK_URL`)。
  権限は Graph の委任の openid・email・profile・offline_access・User.Read・Mail.ReadWrite・Mail.Send・Calendars.ReadWrite。
  **Twenty は、メールだけ・カレンダーだけを同期するときも全部を求める**(上流の get-microsoft-apis-oauth-scopes.ts)。減らすとつなげない
- **自分のテナントのアカウントは、管理者の同意が要ることがある。** テナントの方針でユーザーが Mail.ReadWrite などに同意できないと、
  つなぐときに AADSTS90094 になる。Entra 管理センター › アプリの登録 › twenty › API のアクセス許可 で「doany に管理者の同意を与えます」を押す。
  個人のアカウントは本人が同意の画面で承諾するだけ
- **info@doany.io は Exchange Online Kiosk で同期できる。** Graph のメールと予定の API は Kiosk でも使える(2026-11-21 に Graph で
  メールと予定を読めることを確かめた)。上流の文書の「Microsoft 365 のライセンスが要る」は、メールボックスがあれば足りる。
  個人のアカウント(outlook.com)には、この制限は無い
- **同期を回すのは worker。** 定期のジョブ(`MessagingMessageListFetchCronJob`・`CalendarEventListFetchCronJob` など)は、server が起きるときに
  `cron:register:all` で登録する(イメージの entrypoint.sh。worker では `DISABLE_CRON_JOBS_REGISTRATION` で止めてある)
- **Graph の変更の通知(webhook)は届かないかもしれない。** Twenty は `/webhooks/microsoft/messaging`・`/webhooks/microsoft/calendar` を
  Graph に購読させて、届いたらすぐ取り込む。doany.io のゾーンは Cloudflare がデータセンターの IP にチャレンジを返すので、Microsoft からの
  通知(と購読を作るときの確かめ)は弾かれうる。弾かれても、購読が FAILED になるだけで、定期のジョブ(数分ごと)で取り込まれる
- つないだアカウントのトークン(更新トークン)は DB に `ENCRYPTION_KEY` で暗号化して持つ

## 気にしておくこと

- **版。** `twentycrm/twenty:vX.Y.Z`。server が起きるたびに DB の移行(`upgrade`)が走る。版を飛ばすと移行が長くなる。
  上流の Helm chart は古いので使わず、上流の compose(`packages/twenty-docker/docker-compose.yml`)に合わせて書いている
- **メールは家の中継から送る**(../smtp-relay/。差出人は info@doany.io)。招待のメールや、許可するドメインの確認のメールが届く。
  中継のパスワードは yosegaki と同じ値(`smtp-password`。中継の README「送る側の設定」)
