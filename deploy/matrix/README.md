# matrix

Matrix のサーバー一式(`m.doany.io`)。

| 名前 | 何か | ここで動くか |
| --- | --- | --- |
| Matrix | チャットのプロトコル(メールでいう SMTP) | ─ |
| **Element** | 使うアプリ。スマホは **Element X**、PC は Element Desktop か **https://e.doany.io** | Web 版だけ動かす([element-web.yaml](element-web.yaml))|
| **Tuwunel** | Matrix のサーバー([tuwunel.yaml](tuwunel.yaml))。DB(RocksDB)も中にある | 動かす |
| **hookshot** | 外からの通知をルームに流す([hookshot.yaml](hookshot.yaml)) | 動かす |
| **LiveKit** | 通話(Element Call)の音声と映像の中継([livekit.yaml](livekit.yaml)、[lk-jwt-service.yaml](lk-jwt-service.yaml))。`lk.doany.io` | 動かす |

## 最小構成にした理由

- **サーバーは Tuwunel 1 つ。** Tuwunel は自前の OAuth/OIDC サーバーを持ち、ログインを Entra に回せる。
  スマホの Element X は「OAuth か パスワード」しか受け付けない(legacy SSO を使わない。element-x-android の
  `LoginModePresenter.kt`)ので、Synapse だと MAS と Postgres が別に要る
- **Element Web だけ自分で立てる**(`e.doany.io`)。サーバーを doany.io に決め打ちにし、外のサービス
  (統合マネージャー、利用統計など)を切ってある。中身は静的なファイルなので軽い。スマホと PC は公式のアプリ
- **サーバー(`m.doany.io`)は隠せない。** Element Web はブラウザの中で動き、ブラウザが直接サーバーと話す。
  スマホのアプリと外からの webhook も同じ。Web とサーバーのドメインを分けているのは、一緒にする利点が薄いため
- **フェデレーションは無し。** 家の中だけで使う

## 承知していること

- **日本語の検索は弱い。** Tuwunel は記号と空白でしか単語を区切らないので、ひらがなや漢字の続きは
  ひとかたまりでしか当たらない(`src/service/rooms/search/mod.rs`)。Synapse も英語用の検索に決め打ちで
  (`to_tsvector('english', …)`)、日本語圏の共通の悩み。**後から見たい情報はメッセージではなくドキュメントに書く**
  前提で選んだ(本人)

## ログイン

Entra だけ(Tuwunel の `[[global.identity_provider]]`)。パスワードのログインは無い。

- **ID は `@<メールの @ の前>:doany.io`**(Entra の userinfo に `preferred_username` が無いため `email` から作る)。
  info@doany.io は `@info:doany.io`
- **初回のログインで自動で作られる。最初にログインした人が管理者**になる。新規登録の画面は無い
  (誰が入れるかは Entra が決める)
- リダイレクト URI は `pulumi/entra.ts`(`https://m.doany.io/_matrix/client/unstable/login/sso/callback/<client_id>`)
- `doany.io/.well-known/matrix/client` だけ Tuwunel に回している([httproute.yaml](httproute.yaml))。
  Element でサーバーを聞かれたら **`doany.io`** と入れればよい

## 通知のルーム

**スペース「通知」**にまとめてある。部屋の名前は接頭辞を付けず短く(`server`・`argocd`・`ashi`・
`todoroku`・`worklog`・`denpa`・`forgejo`・`contact`・`feed`)。名前は表示用で、hookshot も webhook も部屋の ID で動くので、変えても影響しない。

- 作ったのは hookshot(`@hookshot:doany.io`)。`@info:doany.io` も作成者(room version 12 の `additional_creators`)
  なので、権限は最上位で外されない
- **暗号化していない。** hookshot は暗号化したルームに書けない。暗号化を後から入れると戻せないので、入れないこと
  (Element は非公開のルームを既定で暗号化するので、作るときに切る)
- webhook の置き場は 2 通り。URL はどちらも `https://m.doany.io/webhook/<ID>`
  - **静的な接続**: [hookshot.yaml](hookshot.yaml) の `connections`。ID は [secrets.sops.yaml](secrets.sops.yaml) の `matrix` の
    `hook-<部屋>`(公開のリポジトリなので平文では置かない)。変換のスクリプト(Slack の attachments など)が要るものと、gitops の中のもの
  - **ルームの state**: 部屋で `!hookshot webhook <名前>` を打って作る(下の「webhook」)。gitops には何も書かないので、
    gitops の外のアプリはこちらにする(アプリを消しても gitops を直さなくてよい)。今は `denpa`
- **投稿は全部 m.notice(bot の発言)**。通知と音は Element の設定で決める:
  グループの会話は「音あり」、bot のメッセージは「オン」(音無しで通知)、要らない部屋は部屋ごとに「メンションのみ」。

| ルーム | 送り元 | URL の在処 |
| --- | --- | --- |
| `server` | バックアップの通知([../backup/notify.yaml](../backup/notify.yaml)) | [../backup/secrets.sops.yaml](../backup/secrets.sops.yaml) の `mattermostWebhook`(名前は据え置き) |
| 〃 | Cloudflare(証明書・DDoS・オリジン不達など) | Cloudflare の通知の webhook の送り先([../../pulumi/notifications.ts](../../pulumi/notifications.ts)) |
| `argocd` | Argo CD | `bootstrap/argocd-values.sops.yaml`(SOPS)の `service.webhook.mattermost` |
| `ashi` | ashi | ashi のリポジトリの `deploy/secrets.sops.yaml`(`ashi-secrets` の `notify-webhook-url`) |
| `todoroku` | todoroku | todoroku のリポジトリの `deploy/secrets.sops.yaml`(`todoroku-secrets` の `mattermost-webhook-url`) |
| `worklog` | worklog | worklog のリポジトリの `deploy/secrets.sops.yaml`(`worklog-secrets` の `mattermost-webhook-url`) |
| `denpa` | denpa(webhook はルームの state) | denpa の DB(`webhooks` テーブル。画面の設定) |
| `forgejo` | Forgejo | Forgejo の組織 `doa` の webhook(種類は Slack。DB の `webhook` id 2) |
| `contact` | doany.io のお問い合わせフォーム(danything/corp) | corp のリポジトリの `deploy/secrets.sops.yaml`(`corp-secrets` の `contact-webhook-url`) |

足すとき:ルームを暗号化なしで作り、hookshot を招待して権限を上げる → 下の「webhook」で作る。
静的な接続にするときだけ、secrets.sops.yaml に `hook-<部屋>` を足し(`sops edit`)、`connections` と render の env に足す。

### webhook(ルームの state)

hookshot の汎用の webhook はルームの state(`uk.half-shot.matrix-hookshot.generic.hook`、state key は名前)に置ける。
ID(URL の秘密の部分)は hookshot の bot の room account data にあり、Tuwunel の DB(VolSync で取っている)に残るので、
Redis が無くても再起動で変わらない(hookshot の `src/Connections/GenericHook.ts`)。

- **作る**: 部屋で `!hookshot webhook <名前>`(3〜64 文字)。部屋には「See admin room for secret url.」とだけ返り、
  **URL は管理用の部屋に届く**。それを送り元(アプリの設定など)に入れる。本文 `{"text": …}` はそのまま m.notice で投稿される
- **消す**: `!hookshot webhook remove <名前>`。一覧は `!hookshot webhook list`(名前だけ。URL は出ない)
- **作り直すときは、必ず先に remove する。** 同じ名前でもう一度 `!hookshot webhook <名前>` を打つと、1 つの名前に ID が 2 つできる。
  再起動のあとどちらの URL が効くかは account data の並び順で決まり、選べない
- **管理用の部屋**は `@info:doany.io` と `@hookshot:doany.io` の暗号化なしの DM。hookshot は起動するときに、
  account data に `admin_user` のある部屋を管理用の部屋として読む。1 人に 1 つだけにしておく(複数あると、どれに届くか選べない)
  - **DM を招待で作ったときは、hookshot を再起動するまで管理用の部屋にならない。** hookshot は招待に入ってから account data を書くが、
    管理用の部屋にするかは入った時点で見るため(`src/Bridge.ts` の `onRoomInvite`・`onRoomJoin`)。それまでは `help` などにも答えない。
    再起動は hookshot.yaml の ConfigMap を変える PR で起こす(Reloader が入れ替える)
  - 古い管理用の部屋を自分が抜けていても、hookshot はそこに URL を送り続ける(相手がまだ居るかを見ない)。
    使わなくなった管理用の部屋は、Tuwunel の管理用の部屋で `!admin users force-leave-room @hookshot:doany.io <部屋の ID>` で hookshot を出してから再起動する

## GitHub 連携(hookshot)

**使っていない。** GitHub の通知は GitHub のアプリで受ける。**App を消して設定を残すと、hookshot が `Integration not found` で
起動しなくなり、通知が全部止まる。**また入れるなら、GitHub App を作り直して
`github:`・秘密・`/github` の経路・`@_github_` の名前空間を戻す(git の履歴の #243 が手順)。

## RSS

hookshot の feeds で RSS / Atom を購読する(10 分おき)。購読はルームに feed の接続(state)を書く。
ルームで `!hookshot feed <URL>` を打つか、hookshot の bot として state
`uk.half-shot.matrix-hookshot.feed`(state key と本文の `url` に URL)を書く。

流す先はスペース「通知」の **`feed`**(暗号化なし、`@info:doany.io` も作成者)。

| 購読 | URL |
| --- | --- |
| b.doany.io のブログ | `https://b.doany.io/rss.xml` |

## 通話(LiveKit)

LiveKit が Matrix の通話(Element Call)の音声と映像を中継する。手順の元は Tuwunel の
`docs/calls/matrix_rtc.md`。

| 部品 | 役目 | 在処 |
| --- | --- | --- |
| LiveKit | 音声と映像の中継(SFU) | [livekit.yaml](livekit.yaml) |
| lk-jwt-service | Matrix のユーザーを確かめて、LiveKit に入るトークンを出す | [lk-jwt-service.yaml](lk-jwt-service.yaml) |

### つながり方

1. Element が Tuwunel に聞く(`/.well-known/matrix/client` か `rtc/transports`)→ `https://lk.doany.io`
   (Tuwunel の `livekit_url`。[tuwunel.yaml](tuwunel.yaml))
2. Element が Tuwunel の OpenID のトークンを `lk.doany.io/get_token` に出す。lk-jwt-service は
   `doany.io/.well-known/matrix/server` → `m.doany.io` の `/_matrix/federation/v1/openid/userinfo` で確かめる
   (フェデレーションは切っているが、この口は開いている)
3. もらったトークンで `wss://lk.doany.io`(LiveKit の合図)につなぐ
4. 音声と映像は **ノードの 8443(UDP。だめなら TCP)** に直接流れる

### ルーターの転送

**8443 の UDP と TCP がノード(10.0.0.2)に届くこと。** ルーターは DMZ で全部をノードに向けているので、
転送の設定は要らない(docs/router.md)。Gateway と Cloudflare は通らない。

外から見える IP は LiveKit が STUN で調べる。家の中の端末も外の IP に向けて送るので、ルーターの
NAT ループバック(ヘアピン)が要る。家の中だけつながらないときはこれを疑う(Tuwunel の docs の Troubleshooting)。

### 秘密

[secrets.sops.yaml](secrets.sops.yaml) の `matrix` の `livekit-secret`。API キーの名前は `matrix`(秘密ではない)。

### やっていないこと

- TURN(LiveKit 内蔵のもの)。UDP がだめなときの TCP 8443 で足りる見込み。会社のネットワークなど
  8443 も塞がれた所からつなぐなら、TURN の TLS(443)が要る
- 昔ながらの 1 対 1 の通話(Element Web の「レガシー」)。Element Web は Element Call だけを使う設定
  (`element_call.use_exclusively`)にした。Element X と同じ仕組みに揃える

## バックアップ

VolSync([volsync.yaml](volsync.yaml)、毎日 19:00 UTC)。`tuwunel-data` を PVC ごと
スナップショットから取る。RocksDB は crash-consistent なスナップショットから自分で立ち直るので、
Tuwunel にバックアップを作らせることはもうしない(k8up の頃の `backups/` は 2026-11-01 に PVC から消した)。

戻すときは PVC ごと戻して、そのまま Tuwunel を起動する。
