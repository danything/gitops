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
| [`bootstrap/`](bootstrap/) | クラスタそのものを組む層(Argo CD 本体・Infisical・cert-manager・Gateway・auth)。**Argo CD は触らない**(`apps/` の外にある)。手で `kubectl apply` する |
| [`backup/`](backup/) | ホストのバックアップ(restic → Cloudflare R2)。毎日 04:00 JST |
| [`recovery/`](recovery/) | まっさらなホストから戻すための復元スクリプトと、暗号化した鍵 |
| `talos/` | Talos への移行用 machine config(検証中。1.14 の形に書き直しが要る) |
| [`docs/`](docs/) | [決定の記録](docs/decisions.md)、[復元リハーサル](docs/restore-drill.md)、[Talos のインストールメディアと machine config](docs/talos.md)、[Entra ID のトークンを小さくする](docs/entra.md) |
| [`ROADMAP.md`](ROADMAP.md) | 暫定構成から Talos までの道筋と、決定の記録 |
| `deploy/argocd.yaml` | このリポジトリ自身の Application 定義(他のリポジトリと同じ場所) |
| `.sops.yaml` | `bootstrap/` にある平文の秘密を SOPS(age)で暗号化する規則 |

## 秘密の扱い

**アプリの秘密は Infisical**(https://il.doany.io、このクラスタでセルフホスト)にあり、平文も暗号文も git には入らない。
各アプリの `*-secrets.yaml` は `InfisicalSecret` で、フォルダは `/<namespace>/<Secret 名>`、シークレット名が
そのまま Secret のキーになる。値を変えるのは Infisical の UI だけでよく、`secrets.infisical.com/auto-reload: "true"`
の注釈がある Deployment は Pod ごと入れ替わる。詳しくは [`bootstrap/README.md`](bootstrap/README.md)。

**Infisical より下の層だけは Infisical から取れない**ので、`bootstrap/` の 4 ファイル(Infisical 自身の鍵、
Argo CD が git を読む GitHub App 鍵、cert-manager の Cloudflare トークン)は **SOPS + age** で該当キーだけ暗号化してある。
鍵は [`recovery/sops-age.key.age`](recovery/)(バックアップの `env.age` と同じパスフレーズ)。

```shell
mkdir -p ~/.config/sops/age
age -d -o ~/.config/sops/age/keys.txt recovery/sops-age.key.age
sops -d bootstrap/infisical/secrets.yaml | kubectl apply -f -
```

## ホスト名の付け方

`*.doany.io` のサブドメインは短く付ける。**規則は 2 つだけ。**

| アプリ名 | 規則 | 結果 |
| --- | --- | --- |
| 2 語以上 | **それぞれの頭文字** | ERPNext → `en`、Mattermost(Matter + most)→ `mm`、Argo CD → `ac`、wg-easy → `wg` |
| 1 語 | **頭文字と最後の子音** | denpa → `dp`、hubble → `hl`、infisical → `il`、netbird → `nd`、tamasagashi → `ts`、yosegaki → `yk`、proxy → `px` |

**1 文字で足りていたものはそのまま。** 先に取ったもの勝ちで、`a`(auth)・`d`(AdGuard)・
`l`(lgtm)・`p`(portainer)・`w`(worklog)・`x`(xool)・`y`(yuzuriha)は 1 文字で置いてある。
新しく足すときは上の規則で 2 文字にする(1 文字はもう埋まっているものが多い)。

`doany.io` そのものはブログ。`*.s.doany.io` は SSO を通して LAN のホストへ中継する口で、
`dp.l.doany.io` のように途中に段が入るものは**宅内からしか引けない名前**
(Gateway のリスナーが段ごとに分かれている。[bootstrap/gateway/](bootstrap/gateway/))。

## アプリ

| ディレクトリ | 内容 |
| --- | --- |
| [`adguardhome/`](apps/adguardhome/) | AdGuard Home (DNS フィルタ) |
| [`cloudflare-ddns/`](apps/cloudflare-ddns/) | DDNS |
| [`erpnext/`](apps/erpnext/) | ERPNext (Helm chart + OIDC セットアップ) |
| [`mattermost/`](apps/mattermost/) | Mattermost + PostgreSQL |
| [`netbird/`](apps/netbird/) | NetBird (VPN。combined コンテナ + 内蔵 IdP) |
| [`portainer/`](apps/portainer/) | Portainer |
| [`wireguard/`](apps/wireguard/) | wg-easy (WireGuard VPN) |
| [`3proxy/`](apps/3proxy/) | 3proxy (国内IP経由の HTTPS フォワードプロキシ) |

