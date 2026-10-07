# Cloudflare の API トークン

アプリが使う Cloudflare のトークンは **Pulumi で作らず、画面(か `cf`)で作って手で Infisical に入れる**。
Pulumi で作ると値を Infisical に書く鍵が CI に要る。その鍵は prod 全体の読み書き・削除ができる Member になる
(Infisical の最小権限のカスタムロール・追加権限は Enterprise 限定)。漏れたときの範囲に見合わない(2026-10-07 に決めた)。

## 一覧(2026-10-07)

| トークン | 種類 | 権限 | 置き場所 | 使うもの |
| --- | --- | --- | --- | --- |
| `external-dns (doany.io DNS write)` | アカウント | `doany.io` の Zone Read + DNS Write | Infisical `/external-dns/external-dns` の `cloudflare-api-token` | apps/external-dns |
| `doany-restic` | アカウント | R2 バケット `doany-restic` だけの Object Read & Write | Infisical `/k8up/k8up-global`、ホストの `/etc/k3s-backup/env`、`recovery/env.age` | k8up、ホストの restic、復元 |
| cloudflare-ddns | ユーザー(アカウントの一覧に無い) | 画面で確かめる(DNS Write が要る) | Infisical `/cloudflare-ddns/cloudflare-ddns-secrets` の `CLOUDFLARE_API_TOKEN` | apps/cloudflare-ddns |
| cert-manager | ユーザー(アカウントの一覧に無い) | 画面で確かめる(DNS Write が要る) | SOPS の `bootstrap/cert-manager/cloudflare-secret.yaml` | cert-manager(DNS-01) |
| `todoroku-pulumi (state)` | アカウント | R2 バケット `todoroku-pulumi` だけの Object Read & Write | Forgejo `doa/todoroku` の secrets `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`(ID と値の SHA-256) | todoroku の `infra/`(Pulumi の state) |
| `gitops pulumi apply` / `preview` | アカウント | pulumi/README.md「鍵と state」 | GitHub の secrets | gitops の Pulumi |

アカウントのトークンは `tools/t.ps1 cf accounts tokens list`、ユーザーのトークンは画面の **My Profile → API Tokens** で見る。
**どれも期限を付けていない。** 期限の監視(`.github/workflows/expiry.yml`)が見るのは Pulumi 用だけ。

## 作り直す

権限は上の表のとおりに、**ゾーンやバケットを 1 つに絞って**作る。作ったら古いものを消す。

- **external-dns / cloudflare-ddns:** Infisical の値を差し替える。operator が Secret を書き換え、
  push-bridge が同期させる。Deployment の `secrets.infisical.com/auto-reload` 注釈で入れ替わる。
- **todoroku-pulumi (state):** Forgejo の 2 つの secrets を差し替える(S3 の鍵の導き方は下の doany-restic と同じ)。
- **cert-manager:** `tools/t.ps1 sops bootstrap/cert-manager/cloudflare-secret.yaml` で書き換えてコミットする。
- **doany-restic(R2):** S3 の鍵はトークンから導く。アクセスキー ID はトークンの ID、シークレットはトークンの値の
  SHA-256(16 進)。**3 か所を全部変える**。どれかが古いとバックアップが落ちる(落ちれば k8up の通知で気づく)。
  1. Infisical `/k8up/k8up-global` の `accessKeyId` / `secretAccessKey`
  2. ホストの `/etc/k3s-backup/env`
  3. `recovery/env.age`(作り直しは recovery/README.md)
