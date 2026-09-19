# Rybbit(rt.doany.io)

アクセス解析。Google Analytics の置き換えで、クッキーを使わない(同意バナーが要らない)。
トドロク(tk.doany.io)の LP から購入までのどこで離脱するかを、ファネル・ユーザージャーニー・
セッションリプレイで見るために置いた(2026-09-19)。AGPL-3.0、自分で動かす分には縛りはない。

上流: <https://github.com/rybbit-io/rybbit>。構成は上流の docker-compose.yml をそのまま k8s に写した。

| ファイル | 中身 |
| --- | --- |
| [rybbit.yaml](rybbit.yaml) | backend(Fastify、`/api`)と client(Next.js)。`ghcr.io/rybbit-io/rybbit-{backend,client}:vX.Y.Z` を 2 つ同じタグで |
| [clickhouse.yaml](clickhouse.yaml) | イベントの倉庫。上流の設定 4 本を ConfigMap に、メモリの上限だけこの箱向けに下げた(limit 3 Gi、1 クエリ 2 GB) |
| [postgres.yaml](postgres.yaml) | ユーザー・サイト・設定。forgejo と同じ 17 系、`pg_dump` を k8up に |
| [redis.yaml](redis.yaml) | セッション追跡のカウンタ。PVC は持たない |
| [rybbit-secrets.yaml](rybbit-secrets.yaml) | Infisical `/rybbit/rybbit` の 4 キー → Secret `rybbit` |
| [httproute.yaml](httproute.yaml) | `rt.doany.io`。`/api` は backend、ほかは client。上流の Caddyfile にある `/.well-known/oauth-*`(MCP 向け)は使わないので置かない |

バックアップは [../k8up/schedules.yaml](../k8up/schedules.yaml) の `rybbit`(ClickHouse の PVC をファイルとして、PostgreSQL は `pg_dump`)。

## 使い始め

1. Infisical(il.doany.io)に フォルダ `/rybbit/rybbit` を作り、`clickhouse-password` / `postgres-password` /
   `redis-password` / `better-auth-secret` を英数字のランダム(32 文字くらい)で入れる。
   入れるまで Pod は `CreateContainerConfigError` で待つ(壊れてはいない)
2. <https://rt.doany.io> を開き、最初のアカウントを作る(これが管理者)
3. **すぐに** [rybbit.yaml](rybbit.yaml) の `DISABLE_SIGNUP` と `NEXT_PUBLIC_DISABLE_SIGNUP` を `"true"` にして
   PR を出す。false のままだと誰でもこのインスタンスにアカウントを作れる(2026-09-19 に済み。
   人を足すなら一時的に false に戻すか、画面の招待で。招待メールは Resend が無いので届かない)
4. 画面で「サイトを追加」→ `tk.doany.io`。出てくるサイト ID をトドロクの `PUBLIC_RYBBIT_SITE_ID`
   (todoroku の `deploy/deployment.yaml`)に入れる。トドロクの root layout が
   `https://rt.doany.io/api/script.js` を読み、購入完了と車両の登録をイベントで送る
5. Rybbit のファネルに「LP → ログイン → 台帳 → 車両の登録 → 料金 → 購入」を作る

## 気にしておくこと

- **訪問者の IP と国。** Cloudflare の後ろにいるので、backend に届く `X-Forwarded-For` の先頭が
  訪問者の IP かどうかを最初に確かめる(Rybbit の「国」が Cloudflare のデータセンターの所在地ばかりなら
  ずれている)。上流の Caddyfile は Cloudflare の範囲を `trusted_proxies` にして対処している。
  Cilium Gateway(Envoy)は既定で XFF を追記するので、たぶんそのままで正しい
- **メモリ。** ClickHouse は limit 3 Gi。1 サイトなら実測 数百 MB で足りるはず。足りなければ
  clickhouse.yaml の limit と `resource_limits.xml` は比率なので limit だけ上げればよい
- **版。** GitHub のリリースの `vX.Y.Z` を 2 つのイメージに同じタグで。Renovate が PR を出す。
  ClickHouse・PostgreSQL・Redis は上流の compose が使っている版に合わせる
- **PSA は baseline。** privileged にした他の namespace と違い、hostPort も特権も要らない。
  Talos に移ったときそのまま通る
