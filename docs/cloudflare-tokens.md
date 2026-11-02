# Cloudflare の API トークン

アプリが使う Cloudflare のトークンは **Pulumi で作らず、画面(か `cf`)で作って手で SOPS のファイルに入れる**
(`tools/t.ps1 sops edit <ファイル>` してコミット)。Pulumi で作ると、値を書き込む先(git の SOPS のファイル)まで CI に触らせることになる。

## 一覧

| トークン | 種類 | 権限 | 置き場所 | 使うもの |
| --- | --- | --- | --- | --- |
| `external-dns (doany.io DNS write)` | アカウント | `doany.io` の Zone Read + DNS Write | `deploy/external-dns/secrets.sops.yaml` の `cloudflare-api-token` | deploy/external-dns |
| `doany-restic` | アカウント | R2 バケット `doany-restic` だけの Object Read & Write | `deploy/backup/secrets.sops.yaml`、各 namespace の `secrets.sops.yaml` の `volsync-<pvc>`、`recovery/env.age` | VolSync・etcd のスナップショット、復元(手元の restic) |
| cloudflare-ddns | ユーザー(アカウントの一覧に無い) | 画面で確かめる(DNS Write が要る) | `deploy/cloudflare-ddns/secrets.sops.yaml` の `CLOUDFLARE_API_TOKEN` | deploy/cloudflare-ddns |
| cert-manager | ユーザー(アカウントの一覧に無い) | 画面で確かめる(DNS Write が要る) | SOPS の `bootstrap/cert-manager-values.sops.yaml`(2 つめのドキュメント) | cert-manager(DNS-01) |
| `todoroku-pulumi (state)` | アカウント | R2 バケット `todoroku-pulumi` だけの Object Read & Write | Forgejo `doa/todoroku` の secrets `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`(ID と値の SHA-256) | todoroku の `infra/`(Pulumi の state) |
| `gitops pulumi apply` / `preview` | アカウント | pulumi/README.md「鍵と state」 | GitHub の secrets | gitops の Pulumi |

アカウントのトークンは `tools/t.ps1 cf accounts tokens list`、ユーザーのトークンは画面の **My Profile → API Tokens** で見る。
**どれも期限を付けていない。** 期限の監視(`.github/workflows/pulumi.yml` の `expiry`、`pulumi/expiry.sh`)が見るのは Pulumi 用だけ。

## 作り直す

権限は上の表のとおりに、**ゾーンやバケットを 1 つに絞って**作る。作ったら古いものを消す。

- **external-dns / cloudflare-ddns:** `secrets.sops.yaml` の値を差し替えてコミットする。Argo CD が当てると sops-secrets-operator が Secret を書き換え、
  external-dns は Reloader の注釈で入れ替わる。cloudflare-ddns は注釈が無いので `kubectl -n cloudflare-ddns rollout restart deploy` する。
- **todoroku-pulumi (state):** Forgejo の 2 つの secrets を差し替える(S3 の鍵の導き方は下の doany-restic と同じ)。
- **cert-manager:** `tools/t.ps1 sops edit bootstrap/cert-manager-values.sops.yaml` で書き換えてコミットする。
- **doany-restic(R2):** S3 の鍵はトークンから導く。アクセスキー ID はトークンの ID、シークレットはトークンの値の
  SHA-256(16 進)。**全部の置き場を変える**。SOPS のほうが古いとバックアップが落ち(バックアップの通知で気づく)、`env.age` が古いと手元の restic で R2 を読めない(こちらは誰も気づかない)。
  1. `deploy/backup/secrets.sops.yaml` の `accessKeyId` / `secretAccessKey` と、各 namespace の `volsync-<pvc>`(ほかのリポジトリの `deploy/secrets.sops.yaml` も)
  2. `recovery/env.age`(作り直しは recovery/README.md)
