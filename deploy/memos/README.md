# Memos(ms.doany.io)

Markdown の短いメモを時系列で積み、タグで束ねる。手続きの記録・調べもの・事業の検討書などを置く。
ログインは Entra ID(共用のアプリ登録 Main、[docs/entra.md](../../docs/entra.md))。
AI(Claude Code)からは公式の MCP(`https://ms.doany.io/mcp`)か REST API で読み書きする。

上流: <https://github.com/usememos/memos>(MIT。有料版や無料の枠は無い)。SQLite で 1 レプリカ。

| ファイル | 中身 |
| --- | --- |
| [memos.yaml](memos.yaml) | 本体(`neosmemo/memos:X.Y.Z`)と、宣言的設定の `instance.json`(Entra・インスタンスの設定・管理者) |
| [httproute.yaml](httproute.yaml) | `ms.doany.io`。全部 5230 に流す |
| [secrets.sops.yaml](secrets.sops.yaml) | 秘密(SOPS)。Secret `memos`(Entra の共用 secret・管理者のパスワード)と VolSync の分 |
| [volsync.yaml](volsync.yaml) | バックアップ(VolSync。`/var/opt/memos` の PVC をスナップショットから。SQLite と添付) |

## 誰が入れるか

- **入れるのは doany.io のアカウントだけ**(`identifierFilter`)。初めて Entra で入るとアカウントが自動で作られる。
  ゲスト(ほかのドメイン)を入れたくなったら `identifierFilter` を広げる
- **Entra のユーザーの mail 属性が空だと入れない**(identifier に使う email が Graph の userinfo に来ないため。ライセンスの無いアカウントなど)。入れないときはまずここを見る
- **パスワードでのログインと登録は止めてある**(`disallowPasswordAuth`)。ただし ADMIN の info はパスワードでも入れる(非常口)
- **閲覧はログインした人だけ**(`INSTANCE_ACCESS_MODE_PRIVATE`)。メモの公開範囲は各メモで決める
  (PRIVATE は本人だけ、PROTECTED はログインした人全員、PUBLIC は誰でも)

## 管理者

- 管理者は `info`(info@doany.io)。宣言的設定の `users` が起動のたびに作る・保つので、手で作る手順は無い。
  Entra の info@doany.io は `linkedIdentities` でこのアカウントに結んである(結ばないと UUID の名前の別のアカウントができる)
- パスワードは Secret の `admin-password`(`tools/t sops -d` で見られる)。変えたら memos.yaml の `writeOnlyVersion` を上げる
  (上げないと送り直さない。上げると info のセッションは切れる)

## 気にしておくこと

- **設定は instance.json で持つ。** ここに書いた項目は画面・API から変えられない。項目を外すときはファイルから消すだけでは起動が止まるので、
  `removed` を書く(上流の docs/configuration/declarative-configuration)。適用に失敗すると Pod が起きない
- **版。** 暦の版(`26.11.1`。`v` は付かない)。Renovate が PR を出す。26.10 で API の道が `/api/v1/...` から `/api/...` に変わった
- **AI 用のトークン(PAT)** は宣言的設定では作れない。要るときに info で作る(`POST /api/users/info/personalAccessTokens`)
