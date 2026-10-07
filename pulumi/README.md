# pulumi

Cloudflare・Entra ID・NetBird の設定を [Pulumi](https://www.pulumi.com/) で持つ。主なもの:

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
| Actions secrets | `PULUMI_BACKEND_URL` / `PULUMI_CONFIG_PASSPHRASE` / `CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_NOTIFY_WEBHOOK_URL`(notifications.ts の送り先)/ `CLOUDFLARE_ZONE_ID`(dns.ts)/ `PREVIEW_CLOUDFLARE_API_TOKEN` / `PREVIEW_AWS_ACCESS_KEY_ID` / `PREVIEW_AWS_SECRET_ACCESS_KEY` |
| Environment `pulumi-apply` | `CLOUDFLARE_API_TOKEN` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` |
| 手元 | パスフレーズの写し `~/.config/doany/pulumi-passphrase` |

`AWS_*` は state の置き場(R2 の S3 API)のため。**値は同じ API トークンから作る**(R2 の仕様で、
トークンの ID がアクセスキー、値の sha256 がシークレットになる)。

| トークン(Cloudflare での名前) | 権限 |
| --- | --- |
| `gitops pulumi preview (R2 read + state)` | Workers R2 Storage Metadata Read(アカウント)+ Bucket Item Write(`doany-pulumi` だけ。state のロックに要る)+ Notifications Read + doany.io の Zone / DNS / Zone Settings の Read |
| `gitops pulumi apply (R2 write + state)` | Workers R2 Storage Write(アカウント)+ Bucket Item Write(`doany-pulumi` だけ)+ Notifications Write + doany.io の Zone Read / DNS Write / Zone Settings Write |

## DNS とゾーンの設定

[dns.ts](dns.ts)。doany.io の DNS のうち **ExternalDNS が作らないもの**(ワイルドカード・メール・CAA・ドメインの確認)と、
ゾーンの設定(SSL・常に HTTPS・最低の TLS の版・HSTS)。2026-10-07 に手で作ってあったものを import で取り込んだ。

- アプリごとの名前は ExternalDNS(アプリの HTTPRoute から)。apex の A / AAAA は cloudflare-ddns(家の IP が変わる)。
  **どちらもここには書かない**(二重に持つと取り合いになる)
- **ワイルドカードは `_` で始まる名前も拾う。** DKIM(`selector1._domainkey`)などを足すときは、明示のレコードで上書きする

## Cloudflare の通知

[notifications.ts](notifications.ts)。証明書・DDoS・オリジン不達・不正利用の報告・Security Insights を、Matrix の
部屋 `server`(スペース「通知」。hookshot の受け口 `cloudflare`)に流す。送り先の URL は hookshot の ID を含むので Actions secrets の
`CLOUDFLARE_NOTIFY_WEBHOOK_URL`(Infisical `/matrix/matrix` の `hook-cloudflare` から作る)。トークンの Notifications の
権限は 2026-10-07 に足した。

## Entra

**鍵を置いていない。** GitHub Actions の OIDC トークンを、Entra のワークロード ID のフェデレーションで受ける。
CI 用のアプリ登録を 2 つに分けてある(R2 の preview / apply と同じ考え方)。

| アプリ登録 | 権限 | 入れる GitHub の実行 | ID の置き場 |
| --- | --- | --- | --- |
| `gitops pulumi preview (Entra read)` | Microsoft Graph の `Application.Read.All`(読むだけ) | PR、main(週次・手動実行) | リポジトリの Variables `PREVIEW_AZURE_CLIENT_ID` |
| `gitops pulumi apply (Entra write)` | `Application.ReadWrite.OwnedBy` + **共用のアプリ登録の所有者** | Environment `pulumi-apply` だけ | Environment の Variables `AZURE_CLIENT_ID` |

**フェデレーションの subject は番号入りの形**(`repo:danything@143234231/gitops@1311609465:pull_request` など)。
このリポジトリは「変わらない subject」(`use_immutable_subject`)を使っていて、組織やリポジトリの名前が変わっても
信頼が崩れない。`repo:danything/gitops:…` で登録すると `AADSTS700213` で入れない(2026-10-06 に踏んだ)。
今の形は `gh api repos/danything/gitops/actions/oidc/customization/sub` の `sub_claim_prefix`。

apply 用は「自分が所有者のアプリ登録」しか書けない。所有者になっているのは、共用のアプリ登録(`b0fa498f-…`)と CI 用の 2 つ。
テナント ID はリポジトリの Variables `AZURE_TENANT_ID`。

持っているのは**リダイレクト URI の一覧**(entra.ts)と、**CI 用のアプリ登録 2 つの信頼の設定**(entra-ci.ts。
2026-10-07 に取り込んだ。apply のサービスプリンシパルを 2 つの所有者にして書けるようにした。消せないよう protect)。クライアントシークレット・アプリロール・
割り当ては Pulumi の外(`docs/entra.md`)。手元で流すときは `az login` のログインがそのまま使われる。

## NetBird

[netbird.ts](netbird.ts)。NetBird (https://nb.doany.io) の **DNS (ネームサーバー・ゾーン・レコード)、自宅の LAN への経路
(ネットワーク・ルーター・リソース)、exit ノードのルート、アクセスのポリシー**。2026-10-07 に画面で作ってあったものを import で取り込んだ。
**画面で変えると、次の週次の preview (--refresh) がずれとして落ちる。**

- **持っていないもの:** グループの中身 (ピアはセットアップキーやログインで入る。ID で指すだけ)、ピア、ユーザー、
  セットアップキー、アカウントの設定
- provider は Terraform の [netbirdio/netbird](https://github.com/netbirdio/terraform-provider-netbird) を Pulumi で包んだもの
  (`pulumi package add terraform-provider netbirdio/netbird <版>`)。生成した SDK は [sdks/netbird](sdks/netbird) に置き、
  `bun install` のときにビルドする (`trustedDependencies`)。**版を上げるときは SDK を作り直す** (runtime が bun だと
  `pulumi package add` が通らないので、`runtime: nodejs` の空のプロジェクトで作ってコピーする)
- `*.doany.io` を家の 10.0.0.2 に向けているのは、exit ノード越しに家の外向きの IPv4 を引くと折り返しで届かないため。
  `nb.doany.io` だけは外向きのアドレスで例外にしている。アドレスは書かず、2 段の名前 `nb.origin.doany.io` (ゾーンのワイルドカードに当たらず Cloudflare で引かれ、cloudflare-ddns が追従させる) に CNAME で向ける

| 鍵 | どこ | NetBird のサービスユーザー |
| --- | --- | --- |
| `PREVIEW_NB_PAT` | Actions secrets | `gitops-pulumi-preview`(Auditor = 読み取りだけ) |
| `NB_PAT` | Environment `pulumi-apply` | `gitops-pulumi-apply`(Admin) |

トークンの期限は 365 日 (2026-10-07 に作った)。切れる前に作り直して差し替える。provider は環境変数 `NB_PAT` を読むので、
**トークンは state に入らない。**

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
