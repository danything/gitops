# matrix

Matrix のサーバー一式(`m.doany.io`)。**Zulip からの移行先**(2026-10-06 に移して、Zulip は畳んだ)。
Zulip の最後のバックアップ(pg_dump と添付ファイル)は R2 に `final` / `retired` のタグで残っている。

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
  前提で選んだ(本人、2026-10-06)
- **Zulip の履歴は持ってこない。** Mattermost からも Zulip からも、Matrix への公式の取り込みが無い
- **通知のルームは暗号化しない。** hookshot は暗号化したルームに書けない(Redis と暗号化の設定が要る)。
  Element は非公開のルームを既定で暗号化するので、通知のルームは作るときに暗号化を切る

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

`notify-*` の 8 つ(2026-10-06 に作った)。Zulip のメッセージは持ってきていない(ほとんどが bot の通知のため)。

- 作ったのは hookshot(`@hookshot:doany.io`)。`@info:doany.io` も作成者(room version 12 の `additional_creators`)
  なので、権限は最上位で外されない
- **暗号化していない。** hookshot は暗号化したルームに書けない。暗号化を後から入れると戻せないので、入れないこと
- webhook は [hookshot.yaml](hookshot.yaml) の `connections`。URL は `https://m.doany.io/webhook/<ID>` で、ID は
  Infisical `/matrix/matrix` の `hook-<部屋>`(公開のリポジトリなので git に置かない)
- スマホに通知が来るのは worklog・denpa・github だけ(m.text で投稿する)。ほかは m.notice で、Element の既定では
  未読が付くだけで通知されない(Mattermost のときと同じ分け方)

| ルーム | 送り元 | URL の在処 |
| --- | --- | --- |
| `notify-server` | k8up の通知 | Infisical `/k8up/k8up-global` の `mattermostWebhook`(名前は据え置き) |
| 〃 | ホストのバックアップ | ホストの `/etc/k3s-backup/env` の `MATTERMOST_WEBHOOK`(**sed で書き換えない**。URL の `&` で壊れる) |
| `notify-argocd` | Argo CD | `bootstrap/argocd/helmchart.yaml`(SOPS)の `service.webhook.mattermost` |
| `notify-ashi` | ashi | Infisical `/ashi/ashi-secrets` の `notify-webhook-url` |
| `notify-todoroku` | todoroku | Infisical `/todoroku/todoroku-secrets` の `mattermost-webhook-url` |
| `notify-worklog` | worklog | Infisical `/worklog/worklog-secrets` の `mattermost-webhook-url` |
| `notify-denpa` | denpa | denpa の DB(`webhooks` テーブル。画面の設定) |
| `notify-forgejo` | Forgejo | Forgejo の組織 `doa` の webhook(種類は Slack。DB の `webhook` id 2) |
| `notify-github` | GitHub | GitHub の組織 `danything` の webhook |

足すとき:ルームを暗号化なしで作り、hookshot を招待して権限を上げる → Infisical に `hook-<部屋>` を足す →
`connections` と render の env に足す。

## 通話(LiveKit)

LiveKit が Matrix の通話(Element Call)の音声と映像を中継する。2026-10-06 に入れた。手順の元は Tuwunel の
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

**8443 の UDP と TCP をノード(10.0.0.2)に転送しておくこと。** Mattermost Calls のときと同じ番号なので、
その転送をそのまま使う(消していなければ)。Gateway と Cloudflare は通らない。

外から見える IP は LiveKit が STUN で調べる。家の中の端末も外の IP に向けて送るので、ルーターの
NAT ループバック(ヘアピン)が要る。家の中だけつながらないときはこれを疑う(Tuwunel の docs の Troubleshooting)。

### 秘密

Infisical `/matrix/matrix` の `livekit-secret`。API キーの名前は `matrix`(秘密ではない)。

### やっていないこと

- TURN(LiveKit 内蔵のもの)。UDP がだめなときの TCP 8443 で足りる見込み。会社のネットワークなど
  8443 も塞がれた所からつなぐなら、TURN の TLS(443)が要る
- 昔ながらの 1 対 1 の通話(Element Web の「レガシー」)。Element Web は Element Call だけを使う設定
  (`element_call.use_exclusively`)にした。Element X と同じ仕組みに揃える

## バックアップ

k8up(毎日 13:30 UTC)。**Tuwunel の DB は動いたまま写すと壊れうる**ので、ファイルとしては取らない。

1. k8up が backup サイドカーの `k8up.io/backupcommand` を流す
2. サイドカーが Tuwunel に SIGUSR2 を送る。Tuwunel は `admin_signal_execute` で `server backup-database` を流し、
   整合の取れたバックアップを `backups/` に作る(2 世代)
3. できたら `backups/` と `media/`(アップロードされたファイル)を tar で k8up に渡す

戻すとき:tar を PVC に展開し、Tuwunel を 1 回だけ `tuwunel --restore-backup` で起動する
(Tuwunel の docs/backups.md「Restoring a managed backup」)。
