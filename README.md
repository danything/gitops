# gitops

k3s クラスタ上のセルフホストアプリを [Argo CD](https://argo-cd.readthedocs.io/) で管理するマニフェスト群。

## 仕組み

[`bootstrap/argocd/repos.yaml`](bootstrap/argocd/repos.yaml) の ApplicationSet が org 内のリポジトリを走査し、
各リポジトリの `deploy/argocd.yaml` を見つけて Argo CD の Application を生成する。
このリポジトリがどうデプロイされるか(同期対象パス・autoSync 等)もクラスタ側ではなく
[`deploy/argocd.yaml`](deploy/argocd.yaml) で決まる。**Argo CD が同期するのは `apps/` 以下だけ**で、
`bootstrap/` は同期対象外(下記)。

## ディレクトリ

| | |
| --- | --- |
| `apps/` | Argo CD が再帰的に同期するアプリのマニフェスト |
| `bootstrap/` | クラスタそのものを組む層(Argo CD 本体・Infisical・Traefik・auth)と、ホストのバックアップ・Talos 移行の資料。**Argo CD は触らない**(`apps/` の外にある)。手で `kubectl apply` する |
| `recovery/` | まっさらなホストから戻すための復元スクリプトと、暗号化した鍵(公開して構わないもの) |
| `deploy/argocd.yaml` | このリポジトリ自身の Application 定義 |
| `.sops.yaml` | `bootstrap/` にある平文の秘密を SOPS(age)で暗号化する規則 |

## 秘密の扱い

`bootstrap/` の 4 ファイルだけは Infisical より下の層(Infisical 自身の鍵、Argo CD が git を読むための GitHub App 鍵、
Traefik の Cloudflare トークン)なので Infisical から取れない。これらは **SOPS + age** で暗号化してコミットしてある。
鍵は [`recovery/sops-age.key.age`](recovery/) (バックアップの `env.age` と同じパスフレーズ)。

```shell
mkdir -p ~/.config/sops/age
age -d -o ~/.config/sops/age/keys.txt recovery/sops-age.key.age
sops -d bootstrap/infisical/secrets.yaml | kubectl apply -f -
```

それ以外の秘密は Infisical にあり、`InfisicalSecret` から Secret が作られる(平文は git に無い)。

## アプリ

| ディレクトリ | 内容 |
| --- | --- |
| [`adguardhome/`](adguardhome/) | AdGuard Home (DNS フィルタ) |
| [`cloudflare-ddns/`](cloudflare-ddns/) | DDNS |
| [`erpnext/`](erpnext/) | ERPNext (Helm chart + OIDC セットアップ) |
| [`mattermost/`](mattermost/) | Mattermost + PostgreSQL |
| [`portainer/`](portainer/) | Portainer |
| [`wireguard/`](wireguard/) | wg-easy (WireGuard VPN) |
| [`3proxy/`](3proxy/) | 3proxy (国内IP経由の HTTPS フォワードプロキシ) |

## Secret

各アプリの `*-secrets.yaml` は [Infisical 純正 operator](https://infisical.com/docs/integrations/platforms/kubernetes/overview) の `InfisicalSecret`。
値は Infisical（https://il.doany.io、[`bootstrap/README.md`](bootstrap/README.md) 参照）のフォルダ
`/<namespace>/<Secret 名>`（例: `/erpnext/erpnext`、`/mattermost/mattermost`）にあり、
シークレット名がそのまま Secret のキーになる。平文の Secret も暗号化した Secret もコミットしない。

値を変えるときは Infisical の UI で書き換えるだけ。push-bridge が数秒で同期させ（保険で5分ごとのポーリングもある）、
Deployment に `secrets.infisical.com/auto-reload: "true"` の注釈があれば **Pod も自動で入れ替わる**
（mattermost・blog 等は注釈済み。無いもの＝Helm チャート系は従来どおり `kubectl rollout restart`）。
