# gitops

k3s クラスタ上のセルフホストアプリを [Argo CD](https://argo-cd.readthedocs.io/) で管理するマニフェスト群。

## 仕組み

[`bootstrap/argocd/repos.yaml`](bootstrap/argocd/repos.yaml) の ApplicationSet が org 内のリポジトリを走査し、
各リポジトリの `deploy/argocd.yaml` を見つけて Argo CD の Application を生成する。
このリポジトリがどうデプロイされるか(同期対象パス・autoSync 等)もクラスタ側ではなく
[`deploy/argocd.yaml`](deploy/argocd.yaml) で決まる。**Argo CD が同期するのは `apps/` 以下と、
`bootstrap/argocd/repos.yaml` の 1 ファイルだけ**で、`bootstrap/` のほかは同期対象外(下記)。

`repos.yaml` を同期しているのは、Argo CD の chart が自分で作る `apps` という Application
(`bootstrap/argocd/helmchart.yaml` の中。`directory.include: repos.yaml`、prune / selfHeal 付き)。
ApplicationSet は Argo CD がいないと意味を持たないので、chart と一緒に入る ── **まっさらなクラスタでも
CI を待たずに走りはじめる**のはこのため。CI の `bootstrap-apply` も同じファイルを当てるが、
中身が同じなので衝突しない。

## ディレクトリ

| | |
| --- | --- |
| `apps/` | Argo CD が再帰的に同期するアプリのマニフェスト。**`_` で始まるディレクトリ (`apps/_glitchtip/` など) は同期しない** (動かしていないもの。下の表) |
| [`bootstrap/`](bootstrap/) | クラスタそのものを組む層(Argo CD 本体・Infisical・cert-manager・Gateway・auth)。**Argo CD は触らない**(`apps/` の外にある。例外は `argocd/repos.yaml` だけ ── 上の「仕組み」)。**main へのマージで GitHub Actions が当てる**(SOPS 済みの 4 ファイルと `cilium/` だけ手で) |
| [`backup/`](backup/) | ホストのバックアップ(restic → Cloudflare R2)。毎日 04:00 JST |
| [`pulumi/`](pulumi/) | Cloudflare(R2・DNS・ゾーンの設定・通知)・Entra(リダイレクト URI・CI の信頼の設定)・NetBird の設定を Pulumi で持つ。**PR で差分がコメントされ、main に入ると当たる** |
| [`recovery/`](recovery/) | まっさらなホストから戻すための復元スクリプトと、暗号化した鍵 |
| [`talos/`](talos/) | Talos への移行用 machine config(**v1.14 の形**。PR ごとに [talos-validate](.github/workflows/talos-validate.yml) が生成物まで検証する)。**Talos では `bootstrap/` のほぼ全部がここに載る** ── [render.sh](talos/render.sh) が `helm template` して inlineManifest にする |
| [`tools/`](tools/) + `compose.yaml` | **手元の運用のコマンド(cf・sops・infisical・kubectl・talosctl など)は Docker で動かす**。`tools/t <コマンド>`。手元に入れるのは Docker だけ |
| [`docs/`](docs/) | **[移行当日の手順](docs/migration-day.md)**、[決定の記録](docs/decisions.md)、[復元リハーサル](docs/restore-drill.md)、[Talos の実機検証](docs/talos.md)、[Entra ID の認可](docs/entra.md)、[家のルーター](docs/router.md)、[Cloudflare の API トークン](docs/cloudflare-tokens.md) |
| [`ROADMAP.md`](ROADMAP.md) | 暫定構成から Talos までの道筋と進捗(なぜそうしたかは `docs/decisions.md`) |
| `deploy/argocd.yaml` | このリポジトリ自身の Application 定義(他のリポジトリと同じ場所) |
| [`.sops.yaml`](.sops.yaml) | 平文の秘密を SOPS(age)で暗号化する規則(`bootstrap/` の 4 ファイルと `talos/` の 2 つ) |

## 秘密の扱い

**アプリの秘密は Infisical**(https://il.doany.io、このクラスタでセルフホスト)にあり、平文も暗号文も git には入らない。
各アプリの `*-secrets.yaml` は `InfisicalSecret` で、フォルダは `/<namespace>/<Secret 名>`、シークレット名が
そのまま Secret のキーになる。値を変えるのは Infisical の UI だけでよく、`secrets.infisical.com/auto-reload: "true"`
の注釈がある Deployment は Pod ごと入れ替わる。詳しくは [`bootstrap/README.md`](bootstrap/README.md)。

**Infisical より下の層だけは Infisical から取れない**ので、`bootstrap/` の 4 ファイル(Infisical 自身の鍵、
Argo CD が git を読む GitHub App 鍵、cert-manager の Cloudflare トークン)は **SOPS + age** で該当キーだけ暗号化してある。
鍵は [`recovery/sops-age.key.age`](recovery/)(バックアップの `env.age` と同じパスフレーズ)。

```shell
# 鍵はリポジトリの .home/(git に入らない)に置く。コマンドは tools/t で動かす(tools/README.md)
tools/t sh -c 'mkdir -p ~/.config/sops/age && age -d -o ~/.config/sops/age/keys.txt recovery/sops-age.key.age'
tools/t sops -d bootstrap/infisical/secrets.yaml | tools/t kubectl apply -f -
```

## ホスト名の付け方

`*.doany.io` のサブドメインは短く付ける。**規則は 2 つだけ。**

| アプリ名 | 規則 | 結果 |
| --- | --- | --- |
| 2 語以上 | **それぞれの頭文字** | ERPNext → `en`、Mattermost(Matter + most)→ `mm`(どちらも今は無い)、NetBird(Net + Bird)→ `nb`、GlitchTip(Glitch + Tip)→ `gt`、Argo CD → `ac`、AdGuard Home → `ah` |
| 1 語 | **頭文字と最後の子音** | denpa → `dp`、hubble → `hl`、infisical → `il`、tamasagashi → `ts`、yosegaki → `yk`、proxy → `px` |

**1 文字で足りていたものはそのまま。** 先に取ったもの勝ちで、`a`(auth)・`d`(AdGuard)・
`h`(headlamp)・`l`(lgtm)・`w`(worklog)・`x`(xool)・`y`(yuzuriha)・`m`(matrix)・`e`(element)は 1 文字で置いてある。
新しく足すときは上の規則で 2 文字にする(1 文字はもう埋まっているものが多い)。
headlamp が 1 文字なのは、規則どおりだと head + lamp でも hubble の 1 語読みでも `hl` に
なってぶつかるため。

`doany.io` そのものはブログ。`*.s.doany.io` は SSO を通して LAN のホストへ中継する口で、
`dp.l.doany.io` のように途中に段が入るものは**宅内からしか引けない名前**
(Gateway のリスナーが段ごとに分かれている。[bootstrap/gateway/](bootstrap/gateway/))。

## アプリ

| ディレクトリ | 内容 |
| --- | --- |
| [`adguardhome/`](apps/adguardhome/) | AdGuard Home (DNS フィルタ) |
| [`cloudflare-ddns/`](apps/cloudflare-ddns/) | DDNS |
| [`external-dns/`](apps/external-dns/) | ExternalDNS。**Cloudflare を通すアプリの DNS を、アプリの HTTPRoute の注釈から作る**(gitops には書かない)。直接つなぐアプリはワイルドカードで引ける |
| [`mta-sts/`](apps/mta-sts/) | MTA-STS の方針ファイル(`mta-sts.doany.io`)。DANE・TLS-RPT と合わせて、doany.io 宛てのメールのサーバー間の TLS を守る |
| [`matrix/`](apps/matrix/) | Matrix のサーバー一式(`m.doany.io`。Web 版の Element は `e.doany.io`、スマホと PC は公式のアプリ)。Tuwunel + hookshot(通知の受け口)+ LiveKit(通話。`lk.doany.io`、hostPort 8443 をルーターで転送)。**Zulip からの移行先。使い始めは [apps/matrix/README.md](apps/matrix/README.md)** |
| [`forgejo/`](apps/forgejo/) | Forgejo(`fj.doany.io`、git + Actions)+ PostgreSQL + Runner(dind)。GitHub Actions の課金を避けて CI をここで回すため。**使い始めの手順は [apps/forgejo/README.md](apps/forgejo/README.md)** |
| [`netbird/`](apps/netbird/) | NetBird (VPN。combined コンテナ + 内蔵 IdP) |
| [`3proxy/`](apps/3proxy/) | 3proxy (国内IP経由の HTTPS フォワードプロキシ) |
| [`k8up/`](apps/k8up/) | バックアップ(restic → Cloudflare R2)。**Talos でホストのスクリプトが使えなくなる**ぶんの受け皿 |
| [`infisical/`](apps/infisical/) [`infisical-operator/`](apps/infisical-operator/) [`infisical-push-bridge/`](apps/infisical-push-bridge/) | 秘密の配布。本体は `bootstrap/` にあり、ここには公開経路と operator と即時反映のブリッジ |
| [`headlamp/`](apps/headlamp/) | Kubernetes の Web UI(`h.doany.io`、Portainer の置き換え)。認証は Entra、権限は `bootstrap/apiserver/` |
| [`rybbit/`](apps/rybbit/) | Rybbit(`rt.doany.io`、アクセス解析。クッキー無し)+ ClickHouse + PostgreSQL + Redis。トドロクの離脱をファネル・ジャーニー・セッションリプレイで見る。**使い始めは [apps/rybbit/README.md](apps/rybbit/README.md)** |

**動かしていないもの**は `apps/_<name>/` に置いてある。`_` で始まるディレクトリは Argo CD が同期しない
([bootstrap/argocd/repos.yaml](bootstrap/argocd/repos.yaml) の `directory.exclude`。全リポジトリ共通の決まり)ので、
クラスタには何も作らない。動かすときは `git mv apps/_<name> apps/<name>`。

| ディレクトリ | 内容 |
| --- | --- |
| [`_glitchtip/`](apps/_glitchtip/) | GlitchTip(Sentry 互換のエラー収集)+ PostgreSQL。`gt.doany.io` の予定。**動かす手順は [apps/_glitchtip/README.md](apps/_glitchtip/README.md)** |

**アプリの多くはこのリポジトリに無い。** 各アプリのリポジトリの `deploy/` に置いてあり、
`bootstrap/argocd/repos.yaml` の ApplicationSet が拾う(上の「仕組み」)。
`kubectl -n argocd get applications` が実際の一覧。

