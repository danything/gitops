# AFFiNE(an.doany.io)

ドキュメントとホワイトボードのワークスペース(Notion + Miro のようなもの)。手続きや調べものの整理に使う。
ログインは Entra ID(共用のアプリ登録 Main、[docs/entra.md](../../docs/entra.md))。

上流: <https://github.com/toeverything/AFFiNE>。構成は上流の `.docker/selfhost/compose.yml` をそのまま k8s に写した。

| ファイル | 中身 |
| --- | --- |
| [affine.yaml](affine.yaml) | 本体(`ghcr.io/toeverything/affine:X.Y.Z`)。起動前に initContainer で config.json を描き、`self-host-predeploy.js`(DB のマイグレーション)を流す |
| [postgres.yaml](postgres.yaml) | DB。上流どおり pgvector 入りの 16 系 |
| [redis.yaml](redis.yaml) | キャッシュとジョブのキュー。PVC は持たない |
| [setup-admin.yaml](setup-admin.yaml) | 最初の管理者(info@doany.io)を作る Job。2 回目からは何もしない |
| [secrets.sops.yaml](secrets.sops.yaml) | 秘密(SOPS)。Secret `affine` の 5 キーと VolSync の分 |
| [httproute.yaml](httproute.yaml) | `an.doany.io`。全部 3010 に流す |
| [volsync.yaml](volsync.yaml) | バックアップ(VolSync。PostgreSQL と storage の PVC をスナップショットから) |

## 誰が何を見られるか

- **入れるのは Entra のテナントの人(本人とゲスト)だけ。** 初めて Entra で入ると AFFiNE のアカウントが自動で作られる
  (`allowSignupForOauth: true`)。パスワード・マジックリンクでの新規登録は閉じてある(`allowSignup: false`)
- **アカウントができても、見えるのは自分の空のワークスペースだけ。** ほかのワークスペースは、持ち主が招待した人にしか見えない。
  招待した人は編集できる(AFFiNE にワークスペース単位の「読むだけ」は無い。読むだけにしたい文書は文書ごとに Reader を付ける)
- **人数の上限: 無料のセルフホストは 1 ワークスペース 10 人まで。** 超えるとそのワークスペースが丸ごと読み取り専用になる
- **パスワードでのログインを止める設定は無い。** メール(MAILER)を設定していないので、パスワードを持つのは最初の管理者だけ
  (Gateway で塞ぐような工夫はしない、と決めた。2026-11-17)

## 最初の管理者

AFFiNE は利用者が 0 人のあいだだけ管理者を作らせる。先に誰かが Entra で入ると管理者のいないまま初期化されるので、
**公開の経路(HTTPRoute)より先に** [setup-admin.yaml](setup-admin.yaml) の Job がクラスタの中から info@doany.io で作る。

1. 経路なしで入れた最初の PR(#872)で、Job が管理者を作った(2026-11-17 済み。`kubectl logs -n affine job/setup-admin` に「管理者を作った」か「もう作ってある」)
2. そのあとの PR で `httproute.yaml` と `pulumi/entra.ts` のリダイレクト URI を足して公開した
3. <https://an.doany.io> で「Entra(OIDC)でログイン」→ info@doany.io で入ると、同じアドレスの管理者に結び付く
4. パスワード(Secret の `admin-password`)は Entra が使えないときの非常口。`tools/t sops -d` で見られる

## 気にしておくこと

- **設定は config.json(affine.yaml の ConfigMap)で持つ。** 管理画面(/admin)で保存した値は DB に入り config.json より強くなるので、
  認証の項目は管理画面で触らない
- **ライセンス。** 画面と大半のコードは MIT / MPL-2.0。サーバーの一部は Enterprise Edition のライセンスで、
  契約が無ければ無料の枠(10 人・100 GB・1 ファイル 100 MB・履歴 30 日)で動く。コードを改造して枠を外すのは EE の条件に触れる
- **版。** `ghcr.io/toeverything/affine` の `X.Y.Z` を本体と predeploy に同じタグで。Renovate が PR を出す
- **全文検索の外部サービス(indexer)は置かない**(上流の compose と同じ)。AI(Copilot)も設定していない
