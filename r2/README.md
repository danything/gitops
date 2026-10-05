# r2

restic の置き場(Cloudflare R2 の `doany-restic`)の設定を git で持つ。
**あるべき姿は [drift.ts](drift.ts) の先頭**にあり、CI([r2-drift](../.github/workflows/r2-drift.yml))が
毎週と `r2/` を触ったときに実物と突き合わせる。**読むだけで、当てはしない。**

道具は Cloudflare の [`cf`](https://blog.cloudflare.com/cloudflare-cf-cli-launch/)(2026-09-28 に open beta)。
版は [package-lock.json](package-lock.json) で固定してあり、Renovate が追う。

## なぜ「見るだけ」か

- **R2 を書ける鍵はバックアップを消せる鍵。** 公開リポジトリの CI に置けば、ワークフローを書き換えられる
  人がバックアップを消せる。CI に `delete` を渡さないのは `bootstrap-apply` と同じ方針
  (cilium-drift が ClusterRoleBinding を書かないのと同じ理由)
- **`cf` には R2 を宣言的に書く口が無い。** `cloudflare.config.ts` が持てるのは Workers だけで、
  R2 はバインディングとして参照できるだけ(cloudflare/cf#61)。バケットの設定は
  `cf r2 buckets lifecycle update` のような命令でしか変えられないので、「git を当てる」形にすると
  差分計算を自前で書くことになる。**変えるのは年に一度あるかどうか**なので割に合わない
- **API トークンは管理対象にしない。** トークンを発行できる権限は、事実上何でもできる権限

## 何を見ているか

**壊れると restic のリポジトリが黙って壊れる、または外に漏れる設定だけ。**

| | あるべき姿 | ずれるとどうなるか |
| --- | --- | --- |
| 場所 / クラス | APAC / Standard | 作り直された(= 中身が別物)ことに気づける |
| lifecycle | **消すルール・移すルールが 0 本**、マルチパートの残骸を消すルールは有る | 消すルールがあると restic の pack が消え、`restic check` まで誰も気づかない。IA への移行は最低保存期間と読み出しの課金が乗る |
| ロック | 0 本 | `prune` が消せず、k8up の Prune が毎週落ちる |
| 公開 | r2.dev もカスタムドメインも無し | 置き場の一覧が外から見える(中身は暗号化されている) |
| 容量 | ─(**記録だけ**。落とさない) | ROADMAP Phase 3「R2 の容量をもう一度見る」の材料。ジョブの Summary に出る |

## 手元で流す

```shell
cd r2 && npm ci
npm run typecheck                                             # 型の検査(CI も流す)
CLOUDFLARE_API_TOKEN=… CLOUDFLARE_ACCOUNT_ID=… node drift.ts
```

**TypeScript だがビルドは無い。** Node 24 が `.ts` から型を剥がして直接走らせる。そのため
剥がすだけで済む書き方に限る(enum・namespace・引数プロパティは不可。`tsconfig.json` の
`erasableSyntaxOnly` が弾く)。型そのものは Node は見ないので、`npm run typecheck` で別に見る。

トークンは CI と同じ読み取り専用のもので足りる(`cf auth login` 済みなら要らない)。

## ずれていたら

1. **Cloudflare 側が正しい**(わざと変えた)なら、`drift.ts` の `BUCKETS` を直す PR を出す
2. **git 側が正しい**なら、手元から `cf` で直す。**書ける鍵はその場で作ってその場で捨てる**
   (`cf auth login` のブラウザ認証で済む。保存しない)

```shell
cf r2 buckets lifecycle get doany-restic        # まず今の姿を見る
cf r2 buckets lifecycle update doany-restic …   # 引数は `--help`。--dry-run がある
```

## トークン

`R2_READ_TOKEN` は **Workers R2 Storage Metadata Read だけ**の Account API token
(名前は `gitops r2-drift (read-only)`)。**設定は読めて、オブジェクトの中身は読めない。**
`Workers R2 Storage Read` より狭く、drift.ts が叩くもの(バケット・lifecycle・ロック・
ドメイン・容量)は全部これで読める(2026-10-05 に確認)。

作り直すときは `cf` で作れる(`cf auth login` に `account_api_tokens:create` が入っている)。
値は画面に出さずに secrets へ流す:

```shell
A=$(cf auth whoami | jq -r '.accounts[0].id'); export CLOUDFLARE_ACCOUNT_ID=$A
cf accounts tokens permission-groups list | jq '.[] | select(.name=="Workers R2 Storage Metadata Read") | .id'
cf accounts tokens create --name "gitops r2-drift (read-only)" \
  --policies "[{\"effect\":\"allow\",\"resources\":{\"com.cloudflare.api.account.$A\":\"*\"},\"permission_groups\":[{\"id\":\"<上の id>\"}]}]" \
  | jq -r .value | gh secret set R2_READ_TOKEN
```

**`cf` の出力は API の封筒(`{success, result}`)を外した `result` だけ**(beta.12 で確認)。
drift.ts は両方の形を読めるようにしてある。
