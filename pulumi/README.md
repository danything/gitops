# pulumi

Cloudflare と Entra ID の設定を [Pulumi](https://www.pulumi.com/) で持つ。いまは 2 つ:

- **R2 の `doany-restic`**(restic の置き場。2026-10-05)── [index.ts](index.ts)
- **Entra のアプリ登録(共用の 1 つ)のリダイレクト URI**(2026-10-06)── [entra.ts](entra.ts)。
  **アプリを足す・消すときは、そのアプリのマニフェストと同じ PR で entra.ts も直す**

| いつ | 何が起きるか | 鍵 |
| --- | --- | --- |
| PR | `pulumi preview`。**差分が PR にコメントされる** | 読み取り(R2 の設定) |
| main に入った | `pulumi up`。**マージした時点で当たる** | 書き込み(Environment `pulumi-apply`、main だけ) |
| 毎週月曜(と手動実行) | `preview --refresh --expect-no-changes`。Cloudflare 側を直接いじっていたら落ちる。あわせて [report.ts](report.ts) | 読み取り |

ワークフローは [../.github/workflows/pulumi.yml](../.github/workflows/pulumi.yml)。

## 何を持っているか

**壊れると restic のリポジトリが黙って壊れる、または外に漏れる設定だけ。**

| | あるべき姿 | ずれるとどうなるか |
| --- | --- | --- |
| バケット | APAC / Standard。**`protect` 付き** | `protect` を外すと、コードの間違い 1 つでバックアップが丸ごと消える |
| lifecycle | マルチパートの残骸を 7 日で消す既定ルール 1 本だけ。**消す・移すルールは置かない** | 消すルールがあると restic の pack が消え、`restic check` まで誰も気づかない |
| ロック | 無し | `prune` が消せず、k8up の Prune が毎週落ちる |
| r2.dev | 無効 | 置き場の一覧が外から見える(中身は暗号化されている) |

Pulumi で表せないものは [report.ts](report.ts) が毎週見る。

- **カスタムドメインが付いていないこと。** `R2CustomDomain` は「付いているもの」しか持てない
- **容量**(アカウント全体)。ズレではないので落とさず、ジョブの Summary に記録するだけ

## 鍵と state

**書き込みの鍵は、R2 の設定を書き換えられる(= バックアップのバケットを消せる)。** 守りは 2 つ。

- **Environment `pulumi-apply` に置き、main からしか使えない。** PR のジョブには読み取りの鍵しか渡らない
- **`doany-restic` に `protect` が付いている。** Pulumi はこのリソースを消すのを拒否する

**承知していること:** preview の鍵も state バケットには書ける(state のロックに要る)。同じリポジトリから
PR を出せる人は、ワークフローを書き換えて state をいじれる。ただし R2 の設定(バックアップのバケット)は
読めるだけで変えられない。書けるのは本人だけ、という前提で受け入れている(2026-10-05)。

state は R2 の別バケット **`doany-pulumi`**(APAC)にあり、パスフレーズで暗号化している。
**state に秘密は入れていない**(アカウント ID は環境変数で渡す)ので、パスフレーズを失くしても
`pulumi stack init` からやり直せる。`doany-restic` は `import` で取り込み直される。
`doany-pulumi` 自体は Pulumi で持っていない(state の置き場を state で持つと鶏卵になる)。2026-10-05 に `cf` で作った。

| どこ | 何 |
| --- | --- |
| Actions secrets | `PULUMI_BACKEND_URL` / `PULUMI_CONFIG_PASSPHRASE` / `CLOUDFLARE_ACCOUNT_ID` / `PREVIEW_CLOUDFLARE_API_TOKEN` / `PREVIEW_AWS_ACCESS_KEY_ID` / `PREVIEW_AWS_SECRET_ACCESS_KEY` |
| Environment `pulumi-apply` | `CLOUDFLARE_API_TOKEN` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` |
| 手元 | パスフレーズの写し `~/.config/doany/pulumi-passphrase` |

`AWS_*` は state の置き場(R2 の S3 API)のため。**値は同じ API トークンから作る**(R2 の仕様で、
トークンの ID がアクセスキー、値の sha256 がシークレットになる)。

| トークン(Cloudflare での名前) | 権限 |
| --- | --- |
| `gitops pulumi preview (R2 read + state)` | Workers R2 Storage Metadata Read(アカウント)+ Bucket Item Write(`doany-pulumi` だけ。state のロックに要る) |
| `gitops pulumi apply (R2 write + state)` | Workers R2 Storage Write(アカウント)+ Bucket Item Write(`doany-pulumi` だけ) |

## Entra

**鍵を置いていない。** GitHub Actions の OIDC トークンを、Entra のワークロード ID のフェデレーションで受ける。
CI 用のアプリ登録を 2 つに分けてある(R2 の preview / apply と同じ考え方)。

| アプリ登録 | 権限 | 入れる GitHub の実行 | ID の置き場 |
| --- | --- | --- | --- |
| `gitops pulumi preview (Entra read)` | Microsoft Graph の `Application.Read.All`(読むだけ) | PR、main(週次・手動実行) | リポジトリの Variables `PREVIEW_AZURE_CLIENT_ID` |
| `gitops pulumi apply (Entra write)` | `Application.ReadWrite.OwnedBy` + **共用のアプリ登録の所有者** | Environment `pulumi-apply` だけ | Environment の Variables `AZURE_CLIENT_ID` |

apply 用は「自分が所有者のアプリ登録」しか書けないので、触れるのは共用のアプリ登録(`b0fa498f-…`)1 つだけ。
テナント ID はリポジトリの Variables `AZURE_TENANT_ID`。

持っているのは**リダイレクト URI の一覧だけ**(`ApplicationRedirectUris`)。クライアントシークレット・アプリロール・
割り当ては Pulumi の外(`docs/entra.md`)。手元で流すときは `az login` のログインがそのまま使われる。

## 手元で流す

```shell
cd pulumi && bun install
bun run typecheck
export CLOUDFLARE_ACCOUNT_ID=… CLOUDFLARE_API_TOKEN=… AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…
export PULUMI_CONFIG_PASSPHRASE_FILE=~/.config/doany/pulumi-passphrase
pulumi login "s3://doany-pulumi?endpoint=https://<アカウント ID>.r2.cloudflarestorage.com&region=auto"
pulumi preview --stack prod --diff
```

**`up` は手元から打たない。** main に入れれば CI が当てる。手元から当てると git と state がずれる。

**TypeScript だがビルドは無い。** Pulumi のランタイムも bun(`Pulumi.yaml` の `runtime: bun`)。
bun は型を見ないので `bun run typecheck` で別に見る(CI も流す)。

`report.ts` は `cf` を bun の上で起動する(`cf` の bin は `#!/usr/bin/env node` なので、そのまま起動すると
node を探しに行く)。**`cf` の出力は API の封筒を外した `result` だけ**(beta.12)だが、両方の形を読める。

## 版

| | どこで固定 | 追うもの |
| --- | --- | --- |
| Pulumi の CLI | [.pulumi-version](.pulumi-version) | 手で上げる(SDK の `@pulumi/pulumi` と揃える) |
| SDK・provider・`cf` | [bun.lock](bun.lock) | Renovate |
| bun | [.bun-version](.bun-version) | Renovate |

## 経緯

2026-10-05 まで、ここは `r2/` で、`drift.ts` が `cf` で実物を読んで突き合わせるだけだった
(当てるのは手で、という方針)。本人の判断で「PR で差分、マージで当てる」に切り替えた。
`doany-restic` の設定はそのとき実物と同じ内容で書き、バケットは `import` で取り込んだ
(lifecycle・ロック・r2.dev は import できないリソースなので、最初の `up` で同じ内容を書き直した)。
