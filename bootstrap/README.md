# bootstrap

クラスタそのものを組む層。**ここにあるものは全部 machine config に載る**([render.sh](render.sh) が描く)。
ArgoCD はここを見ない(例外は [argocd/repos.yaml](argocd/repos.yaml) だけ。下の「ArgoCD が当てるもの」)。
層の分け方は [docs/decisions.md](../docs/decisions.md)「層の分け方」。

| | 何を | いつ |
| --- | --- | --- |
| **machine config**(このディレクトリ) | Talos の設定、Helm で入れるもの(cilium・cert-manager・argocd・infisical)、`apiserver-rbac.yaml`、`local-path.yaml`、SOPS 済みの Secret 2 つ | `render.sh` → `apply-config` → `upgrade-k8s`([talos.md](talos.md)「上げ方 / 当て直し方」) |
| **ArgoCD**(`apps/`) | 平文のマニフェスト(`ClusterIssuer`・Gateway・auth・`InfisicalSecret` など)。2026-10 まではここにあって、Application `bootstrap` が当てていた | main へのマージ(prune / selfHeal 付き) |

## ファイル

部品ごとに 1 ファイルを基本にして、ディレクトリを切らない。部品の名前を頭に付ける。

| ファイル | 中身 |
| --- | --- |
| [render.sh](render.sh) | machine config を組む。下のファイルを全部読む |
| [talos.md](talos.md) | Talos の組み立てと当て直し方 |
| [talos.sops.yaml](talos.sops.yaml) | 手で書く machine config(`password` の値だけ SOPS) |
| [talos-secrets.sops.yaml](talos-secrets.sops.yaml) | クラスタの CA 一式(丸ごと SOPS) |
| [versions.yaml](versions.yaml) | Talos・Kubernetes・Gateway API の版と schematic |
| `<name>-values.yaml` | chart の値と版(cilium・cert-manager・argocd・infisical。下の「Helm で入れるもの」) |
| `<name>-secret-values.sops.yaml` | chart の値のうち秘密だけ(argocd・infisical。丸ごと SOPS) |
| [infisical-secrets.sops.yaml](infisical-secrets.sops.yaml) | infisical の起動に要る Secret(`ENCRYPTION_KEY` など) |
| [cert-manager-cloudflare-secret.sops.yaml](cert-manager-cloudflare-secret.sops.yaml) | DNS-01 の Cloudflare のトークン |
| [apiserver-rbac.yaml](apiserver-rbac.yaml) / [apiserver-ca.crt](apiserver-ca.crt) | API サーバの入口の RBAC と CA(下の「API サーバの入口」) |
| [local-path.yaml](local-path.yaml) | local-path-provisioner |
| [argocd/repos.yaml](argocd/repos.yaml) | ArgoCD が当てる唯一のファイル(下の「ArgoCD が当てるもの」) |

**SOPS(age)で暗号化したファイルは名前を `*.sops.yaml` で終える**(`.sops.yaml` の規則もその名前にしか一致しないので、
別の名前では暗号化できない)。復号鍵はクラスタにも CI にも渡さない。
鍵は [`recovery/sops-age.key.age`](../recovery/)。**中を編集するときも `sops edit` を通すこと。** MAC は暗号化して
いない値も含めて計算されるので、**平文で 1 行足すだけでも `sops -d` が MAC 不一致で落ちる**
(例外は `talos.sops.yaml` で、`mac_only_encrypted` なので平文の部分は直接直せる)。

## ArgoCD が当てるもの

**ここで ArgoCD が当てるのは [argocd/repos.yaml](argocd/repos.yaml) だけ。** machine config に載っている
`apps` の Application(`argocd-values.yaml` の `extraObjects`)が拾い、そこから ApplicationSet が `apps/` を当てる。
場所が machine config に焼いてあるので、このファイルだけディレクトリに入っている(動かすと machine config を当て直すことになる)。

ArgoCD の平文のマニフェストは `apps/` にある:
[apps/gateway/](../apps/gateway/)(Gateway と http → https)、[apps/auth/](../apps/auth/)(SSO の oauth2-proxy)、
[apps/cert-manager/](../apps/cert-manager/)(`ClusterIssuer`)、[apps/argocd/](../apps/argocd/)(HTTPRoute と OIDC の `InfisicalSecret`)、
[apps/infisical/smtp-secret.yaml](../apps/infisical/smtp-secret.yaml)。
`ClusterIssuer` や Gateway は本体(cert-manager・cilium)が machine config に居ても、書き換えるのは平文のマニフェストなので
ArgoCD に任せる。

## Helm で入れるもの

どれも `render.sh` が `helm template` して machine config に載せる。どれも同じ形で、
**`<name>-values.yaml` の 1 本**に chart・repo・版と値をまとめる。先頭の 2 行が chart と版:

```yaml
# renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io
# version: 1.20.4
```

`# renovate:` の行から `render.sh` が chart(`depName`)と repo(`registryUrl`)を、次の `# version:` の行から版を読む。
版をコメントにしているのは、値として書くと chart に渡ってしまうから。Renovate も同じ 2 行を見て上げる(`renovate.json` の customManagers)。
argocd と infisical は、値のうち秘密だけを `<name>-secret-values.sops.yaml`(SOPS、丸ごと暗号化)に分けて上に重ねる。
argocd・infisical の版は自動マージしない(`renovate.json` の `bootstrap charts`)。
Namespace は chart が描かないので、`render.sh` が kube-system 以外のものに付ける。

## git と live がずれていないか

**cilium は [cilium-drift.yml](../.github/workflows/cilium-drift.yml) が週次で見ている**(値が `cilium-config` という
ConfigMap に出ているので、読むだけの権限で比べられる)。**残りは見ていない。** 当て忘れは `upgrade-k8s` の差分に出るので、
直したら流す(流し忘れたことは誰も教えてくれない)。描くたびに変わる値は潰してあるので、
`apply-config --dry-run` に出る差分は全部本物([talos.md](talos.md)「inlineManifests を直したとき」)。

## cilium

**クラスタの土台。** CNI・kube-proxy の代替・Gateway API を全部これが担う。
決定の経緯は [../docs/decisions.md](../docs/decisions.md)「ルーティングの選定」。

[cilium-values.yaml](cilium-values.yaml) を直したら **`render.sh` → `apply-config` → `upgrade-k8s`**
([talos.md](talos.md)「上げ方 / 当て直し方」)。`helm upgrade` は使わない。値はここが正本で、machine config は
`render.sh` がここから描く派生物(二度書かない。decisions.md「machine config と Cilium の chart をどう連動させるか」)。
**どの設定が何のために要るかは [cilium-values.yaml](cilium-values.yaml) のコメントにある**(ここには写さない)。

### 描き直すたびに Hubble の証明書が入れ替わる

チャートの `hubble/tls-helm/*` は毎回 `genCA` / `genSignedCert` で作り直す
(`cilium.io/helm-template-non-idempotent: "true"`)。**値を 1 行も変えなくても、`hubble-ca-secret` /
`hubble-server-certs` / `hubble-relay-client-certs` の 3 つは `upgrade-k8s` の差分に出る。**
実害は無い(エージェントも Relay もファイルの入れ替わりに追従する。Pod の再起動は要らない)。
`cilium-dbg status` の `Hubble: Ok` と `hubble-relay` の Ready で確かめる。

### ズレは CI が見ている

**当て忘れとクラスタ側の直接編集は [cilium-drift.yml](../.github/workflows/cilium-drift.yml) が見つける。**
`cilium-values.yaml` から ConfigMap を描いて live と突き合わせるだけで、**読むだけ**(権限は `cilium-config` の `get` 1 つ)。
`cilium-values.yaml` を触ったときと毎週月曜に走る。当てるのは自動化しない(Talos API の os:admin を CI に置かない)。

### 当てたあとに確認すること

```shell
# ホストのポートが張られているか(eBPF なので ss には出ない)
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | grep -i hostport
# Gateway のリスナーが載っているか(住所はノードの IP になる)
kubectl -n kube-system get gateway doany
```

## Secret

平文の Secret はアプリのリポジトリにはコミットしない。値は **Infisical**(https://il.doany.io、このクラスタでセルフホスト)が持ち、
**Infisical 純正 operator**(`apps/infisical/operator.yaml`)が各リポジトリの `InfisicalSecret` を見て Infisical から値を取り、普通の `Secret` を作る。
認証は Kubernetes 方式（TokenReview・長命の資格情報なし）。

- `infisical-*` … Infisical 本体(chart + Postgres/Redis)。公開経路は [`apps/infisical/httproute.yaml`](../apps/infisical/httproute.yaml)。
  `infisical-secrets.sops.yaml` の `ENCRYPTION_KEY` が DB の暗号鍵で、これを失うと Infisical の中身が全部読めなくなる
  (クラスタで一番失ってはいけない値)。Postgres の PVC は既定の `local-path` で、`pg_dump` を k8up が日次で取っている。
- **operator と push-bridge はここには無い**(`apps/infisical/operator.yaml`、`apps/infisical/push-bridge.yaml`)。
  ArgoCD 自身は operator に依存しないので、bootstrap に置く理由がない。
  認証は Infisical の Kubernetes auth: operator が SA `infisical-auth` のトークンで Infisical にログインし、
  Infisical がそのトークンで TokenReview を呼んで本物か確かめる(なので SA に `system:auth-delegator` を
  付けてある)。SA と RBAC は `apps/infisical/operator-rbac.yaml`。
  operator 側に長期の資格情報は無い(`identityId` は秘密ではない)。

### API サーバの入口(GitHub Actions と人)

**GitHub Actions は読むだけ。** cilium-drift.yml の OIDC トークンを API サーバが直接受け
([talos.sops.yaml](talos.sops.yaml) の `KubeAuthenticationConfig`)、
権限は `cilium-config` の `get` だけ([apiserver-rbac.yaml](apiserver-rbac.yaml))。
CA は [apiserver-ca.crt](apiserver-ca.crt)(`talos-secrets.sops.yaml` のクラスタ CA。作り直したら替える)。
kubeconfig も age 鍵も GitHub に置いていない。

**同じ認証設定と RBAC が人の入口でもある。** Entra を 2 つめの issuer として足し、
Headlamp が利用者本人の id_token を API サーバへ転送する。アプリロール `admin` を持つ人は
`entra:admin` で cluster-admin、それ以外は `entra:viewer` で読み取り専用(組み込みの `view`
＋ CRD とノードぶんの `readonly-extra`)。**振り分けは CEL で、割り当ては Entra 側で完結する。**
ここに置いたのは、ArgoCD も CI も要らずに効く層だから ── 締め出されたときに直せる。
認証設定([talos.sops.yaml](talos.sops.yaml))も [apiserver-rbac.yaml](apiserver-rbac.yaml) も
machine config に載っているので、変えたら `render.sh` → `apply-config`(RBAC は inlineManifest なので `upgrade-k8s` まで)。
**ArgoCD には当てさせない**(締め出されたときに直せる層に置く)。

### Infisical の中の構成

| | |
| --- | --- |
| Project | `doa`（slug `doa`）、環境は `prod` だけ |
| フォルダ | `/<namespace>/<Secret 名>`(例: `/denpa/denpa-oidc`、`/worklog/ghcr-pull`) |
| シークレット名 | 作られる `Secret` の **キー名そのまま**(`client-id`、`.dockerconfigjson` など) |
| Machine Identity | `infisical-operator`(Kubernetes auth、許可 SA は `infisical/infisical-auth`、project の viewer) |
| 管理者 | 個人アカウント。資格情報はリポジトリに置かない。復旧手順は下の「Infisical の管理者アカウント」 |
| 共有値 | `/shared/entra`(Entra 共用アプリの client-id / client-secret / issuer / role / tenant-id)と `/shared/smtp`(info@doany.io)。各アプリのフォルダは `${prod.shared.entra.client-secret}` のような参照で、ローテーションは shared 側の 1 回で済む(operator が展開する) |
| SMTP | info@doany.io から、クラスタの中の中継 [apps/smtp-relay](../apps/smtp-relay/README.md) 経由(Graph の sendMail)。パスワード(中継のアプリのクライアントシークレット)だけ Infisical の `/infisical/infisical-smtp` に置き、[apps/infisical/smtp-secret.yaml](../apps/infisical/smtp-secret.yaml) が Secret にする |

### Infisical の管理者アカウント

初期化(`POST /api/v1/admin/bootstrap`)で作った `admin@doany.io` は現存しない
(2026-09-02 にログインを試して "Failed to find user")。いまの管理者は個人アカウントで、
資格情報はこのリポジトリに置かない。

ロックアウトしたときの復旧は、SMTP(info@doany.io 経由)が生きていればログイン画面の
パスワードリセット。それも届かない場合は `infisical` ns の PostgreSQL に入って
`users` テーブルから管理者を特定し、Infisical のドキュメントにある手順でリセットする。

初期化で一緒に作られる "Instance Admin Identity"(root 相当の Machine Identity)は
セットアップ後に削除してある。必要なら UI の Organization Settings > Identities で作り直す。

DB は手元の restic から直接戻す(k8up の資格情報が Infisical から来るので)。戻したら operator の
Kubernetes auth の CA も差し替える。手順は [../recovery/README.md](../recovery/README.md) の 6・7。

### `InfisicalSecret` には sync-options を 2 つ付けること

```yaml
argocd.argoproj.io/sync-options: Prune=false,SkipDryRunOnMissingResource=true
```

**`Prune=false`** ── operator は CR の annotation を、作った `Secret` にもコピーする。
ArgoCD の tracking-id までコピーされると、ArgoCD がその `Secret` を「git に無い管理対象」と
見なして sync のたびに prune する。
`Prune=false` も一緒にコピーさせて、prune の対象から外す。

**`SkipDryRunOnMissingResource=true`** ── **まっさらなクラスタでは CRD がまだ無く、`apps/` の同期が丸ごと落ちる**
(CRD を入れる `apps/infisical/operator.yaml` が同じ同期の中にいる)。
仕組みは k8up の `Schedule` と同じで、説明は [apps/k8up/README.md](../apps/k8up/README.md)「CRD がまだ無いクラスタで apps を止めないこと」。

このリポジトリの `InfisicalSecret`(`apps/argocd/oidc-secret.yaml`・`apps/auth/secrets.yaml`・`apps/infisical/smtp-secret.yaml` など)にも付けてある。

### アプリ側の書き方

各リポジトリの `deploy/` に `InfisicalSecret` を置く。フォルダ内のシークレットを全部そのままキーにするので、
Infisical にキーを足せば InfisicalSecret は触らずに済む(push-bridge が数秒で同期、保険のポーリングは既定5分)。

```yaml
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
  name: denpa-oidc
  namespace: denpa
spec:
  hostAPI: http://infisical.infisical.svc:8080/api
  authentication:
    kubernetesAuth:
      identityId: f2bc3416-f196-4626-9bf3-c11693b32cc6
      autoCreateServiceAccountToken: true
      serviceAccountRef:
        name: infisical-auth
        namespace: infisical
      secretsScope:
        projectSlug: doa
        envSlug: prod
        secretsPath: /denpa/denpa-oidc
        recursive: false
  managedKubeSecretReferences:
    - secretName: denpa-oidc
      secretNamespace: denpa
      creationPolicy: Orphan
```

`kubernetes.io/dockerconfigjson` のような型が要るときは `managedKubeSecretReferences` に
`secretType` を足す。ラベル等は `template`(`includeAllSecrets: true` を忘れずに — 無いと中身を捨てる)。

値を変えるときは Infisical の UI(または CLI)で書き換えるだけ。Git には何も入らない。
`secrets.infisical.com/auto-reload: "true"` の注釈がある Deployment は自動で入れ替わる。
注釈が無いもの(Helm チャート系)だけ `kubectl rollout restart` する。
