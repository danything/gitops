# gitops

自宅の Kubernetes クラスタ(Talos Linux の 1 ノード)上のセルフホストアプリを [Argo CD](https://argo-cd.readthedocs.io/) で管理するマニフェスト群。

## 仕組み

[`bootstrap/argocd-repos.yaml`](bootstrap/argocd-repos.yaml) の ApplicationSet が org 内のリポジトリを走査し、
各リポジトリの `deploy/argocd.yaml` を見つけて Argo CD の Application を生成する。
このリポジトリがどうデプロイされるか(同期対象パス・autoSync 等)もクラスタ側ではなく
[`deploy/argocd.yaml`](deploy/argocd.yaml) で決まる。**Argo CD が同期するのは `apps/` 以下だけ**
(`bootstrap/` は machine config 側。Argo CD が見るのは `bootstrap/argocd-repos.yaml` の 1 本だけ)。

`argocd-repos.yaml` は Argo CD の chart が作る `apps` Application が拾うので、**まっさらなクラスタでも CI を待たずに走りはじめる**
(詳しくは [`bootstrap/README.md`](bootstrap/README.md))。

## ディレクトリ

| | |
| --- | --- |
| `apps/` | Argo CD が再帰的に同期するアプリのマニフェスト。**`_` で始まるディレクトリは同期しない** (動かしていないものの置き場。下の「動かしていないもの」) |
| [`bootstrap/`](bootstrap/) | クラスタそのものを組む層。**ここにあるものは全部 machine config に載る**([render.sh](bootstrap/render.sh) が `helm template` して inlineManifest にする)。ノードの Talos の設定(**v1.14 以降の形**。手で書くのは [talos.sops.yaml](bootstrap/talos.sops.yaml) の 1 本。PR ごとに [talos-boot](.github/workflows/talos-boot.yml) が生成物を検証して VM で起動する)、Helm で入れるもの(Cilium・Argo CD 本体・Infisical・cert-manager。部品ごとに `<name>-values.yaml` 1 本。秘密を含むものは `<name>-values.sops.yaml` で、秘密の値だけ SOPS)、RBAC、SOPS 済みのもの |
| [`pulumi/`](pulumi/) | Cloudflare(R2・DNS・ゾーンの設定・通知)・Entra(リダイレクト URI・CI の信頼の設定)・NetBird の設定を Pulumi で持つ。**PR で差分がコメントされ、main に入ると当たる** |
| [`mado/`](mado/) | **`main` が落ちたときの入口**。JCOM 側の PC(10.10.0.2)で [mado](https://github.com/danything/mado)(OIDC でログインしてブラウザから RDP する exe)を動かす(`md.doany.io`。クラスタの外) |
| [`recovery/`](recovery/) | **まっさらから建て直す入口**(手順・PV を戻す道具・暗号化した鍵)。git と restic だけで戻す |
| [`tools/`](tools/) + `compose.yaml` | **手元の運用のコマンド(cf・sops・infisical・kubectl・talosctl など)はコンテナで動かす**。`tools/t.ps1 <コマンド>`(Windows の WSL コンテナ。wslc-compose)。手元にコマンドは入れない |
| [`docs/`](docs/) | [決定の記録](docs/decisions.md)、[Talos の作法と検証](docs/talos.md)、[Entra ID の認可](docs/entra.md)、[家のルーター](docs/router.md)、[Z440 への移行](docs/z440-migration.md)、[Cloudflare の API トークン](docs/cloudflare-tokens.md) |
| [`ROADMAP.md`](ROADMAP.md) | やることと進捗(なぜそうしたかは `docs/decisions.md`) |
| `deploy/argocd.yaml` | このリポジトリ自身の Application 定義(他のリポジトリと同じ場所) |
| [`.sops.yaml`](.sops.yaml) | 平文の秘密を SOPS(age)で暗号化する規則(`bootstrap/` の `*.sops.yaml` の 6 つ) |

## 秘密の扱い

**アプリの秘密は Infisical**(https://il.doany.io、このクラスタでセルフホスト)にあり、平文も暗号文も git には入らない。
各アプリの `*-secrets.yaml` は `InfisicalSecret` で、フォルダは `/<namespace>/<Secret 名>`、シークレット名が
そのまま Secret のキーになる。値を変えるのは Infisical の UI だけでよく、`secrets.infisical.com/auto-reload: "true"`
の注釈がある Deployment は Pod ごと入れ替わる。詳しくは [`bootstrap/README.md`](bootstrap/README.md)。

**Infisical より下の層だけは Infisical から取れない**ので、`bootstrap/` の 4 ファイル(Infisical 自身の鍵、
Argo CD が git を読む GitHub App 鍵、cert-manager の Cloudflare トークン)は **SOPS + age** で該当キーだけ暗号化してある。
鍵は [`recovery/sops-age.key.age`](recovery/)(バックアップの `env.age` と同じパスフレーズ)。
当てるのは machine config(`bootstrap/render.sh` が復号して載せる)。

```shell
# 鍵はリポジトリの .home/(git に入らない)に置く。コマンドは tools/t.ps1 で動かす(tools/README.md)
tools/t.ps1 sh -c 'mkdir -p ~/.config/sops/age && age -d -o ~/.config/sops/age/keys.txt recovery/sops-age.key.age'
tools/t.ps1 sops -d bootstrap/infisical-values.sops.yaml      # 中を見る(画面に出すと平文になるので注意)
```

## ホスト名の付け方

`*.doany.io` のサブドメインは短く付ける。**規則は 2 つだけ。**

| アプリ名 | 規則 | 結果 |
| --- | --- | --- |
| 2 語以上 | **それぞれの頭文字** | NetBird(Net + Bird)→ `nb`、Argo CD → `ac`、AdGuard Home → `ah` |
| 1 語 | **頭文字と最後の子音** | denpa → `dp`、hubble → `hl`、infisical → `il`、tamasagashi → `ts`、yosegaki → `yk`、proxy → `px` |

**1 文字で足りていたものはそのまま。** 先に取ったもの勝ちで、`a`(auth)・`d`(AdGuard)・
`h`(headlamp)・`l`(lgtm)・`w`(worklog)・`x`(xool)・`y`(yuzuriha)・`m`(matrix)・`e`(element)は 1 文字で置いてある。
新しく足すときは上の規則で 2 文字にする(1 文字はもう埋まっているものが多い)。
headlamp が 1 文字なのは、規則どおりだと head + lamp でも hubble の 1 語読みでも `hl` に
なってぶつかるため。

`doany.io` そのものはブログ。`*.s.doany.io` は SSO を通して LAN のホストへ中継する口で、
`dp.l.doany.io` のように途中に段が入るものは**宅内からしか引けない名前**
(Gateway のリスナーが段ごとに分かれている。[apps/gateway/](apps/gateway/))。

## アプリ

| ディレクトリ | 内容 |
| --- | --- |
| [`gateway/`](apps/gateway/) | 公開の入口の Gateway(ワイルドカードの証明書付き)と http → https。Cilium 本体は `bootstrap/` |
| [`auth/`](apps/auth/) | SSO(`a.doany.io`)。oauth2-proxy で、SSO を持たない UI(AdGuard Home・Hubble)と `*.s.doany.io` の前に立つ |
| [`cert-manager/`](apps/cert-manager/) | `ClusterIssuer`(Let's Encrypt、DNS-01)。cert-manager 本体と Cloudflare のトークンは `bootstrap/` |
| [`argocd/`](apps/argocd/) | Argo CD の公開経路(`ac.doany.io`)と OIDC の client secret。本体は `bootstrap/` |
| [`adguardhome/`](apps/adguardhome/) | AdGuard Home (DNS フィルタ) |
| [`cloudflare-ddns/`](apps/cloudflare-ddns/) | DDNS |
| [`external-dns/`](apps/external-dns/) | ExternalDNS。**Cloudflare を通すアプリの DNS を、アプリの HTTPRoute の注釈から作る**(gitops には書かない)。直接つなぐアプリはワイルドカードで引ける |
| [`mta-sts/`](apps/mta-sts/) | MTA-STS の方針ファイル(`mta-sts.doany.io`)。DANE・TLS-RPT と合わせて、doany.io 宛てのメールのサーバー間の TLS を守る |
| [`matrix/`](apps/matrix/) | Matrix のサーバー一式(`m.doany.io`。Web 版の Element は `e.doany.io`、スマホと PC は公式のアプリ)。Tuwunel + hookshot(通知の受け口)+ LiveKit(通話。`lk.doany.io`、hostPort 8443 をルーターで転送)。**使い始めは [apps/matrix/README.md](apps/matrix/README.md)** |
| [`forgejo/`](apps/forgejo/) | Forgejo(`fj.doany.io`、git + Actions)+ PostgreSQL + Runner(dind)。GitHub Actions の課金を避けて CI をここで回すため。**使い始めの手順は [apps/forgejo/README.md](apps/forgejo/README.md)** |
| [`netbird/`](apps/netbird/) | NetBird (VPN。combined コンテナ + 内蔵 IdP) |
| [`3proxy/`](apps/3proxy/) | 3proxy (国内IP経由の HTTPS フォワードプロキシ) |
| [`k8up/`](apps/k8up/) | バックアップ(restic → Cloudflare R2)。PVC・DB のダンプ・etcd のスナップショット |
| [`infisical/`](apps/infisical/) | 秘密の配布。本体は `bootstrap/` にあり、ここには公開経路と operator と即時反映のブリッジと SMTP のパスワード |
| [`cluster/`](apps/cluster/) | ノードまわりの小物。metrics-server(Talos に無い。`kubectl top` と各 UI の使用量表示)と、PT3 をドライバに付け直す DaemonSet |
| [`smtp-relay/`](apps/smtp-relay/) | メールの中継。アプリの SMTP を受けて Microsoft 365 へ Graph で送る(Exchange Online の SMTP AUTH の Basic 認証の廃止に備えて)。**送る側の設定は [apps/smtp-relay/README.md](apps/smtp-relay/README.md)** |
| [`renovate/`](apps/renovate/) | Renovate(GitHub の danything・5ym と Forgejo の doa の全リポジトリの依存を上げる PR)。CronJob で 15 分おき。**秘密の入れ方は [apps/renovate/README.md](apps/renovate/README.md)** |
| [`headlamp/`](apps/headlamp/) | Kubernetes の Web UI(`h.doany.io`)。認証は Entra、権限は `bootstrap/apiserver-rbac.yaml` |
| [`rybbit/`](apps/rybbit/) | Rybbit(`rt.doany.io`、アクセス解析。クッキー無し)+ ClickHouse + PostgreSQL + Redis。トドロクの離脱をファネル・ジャーニー・セッションリプレイで見る。**使い始めは [apps/rybbit/README.md](apps/rybbit/README.md)** |

**動かしていないもの**は `apps/_<name>/` に置いてある。`_` で始まるディレクトリは Argo CD が同期しない
([bootstrap/argocd-repos.yaml](bootstrap/argocd-repos.yaml) の `directory.exclude`。全リポジトリ共通の決まり)ので、
クラスタには何も作らない。動かすときは `git mv apps/_<name> apps/<name>`。いまは無い。

**アプリの多くはこのリポジトリに無い。** 各アプリのリポジトリの `deploy/` に置いてあり、
`bootstrap/argocd-repos.yaml` の ApplicationSet が拾う(上の「仕組み」)。
`kubectl -n argocd get applications` が実際の一覧。

