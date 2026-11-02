# bootstrap

クラスタそのものを組む層。**ここにあるものは全部 machine config に載る**([render.sh](render.sh) が描く)。
ArgoCD はここを見ない(例外は [argocd-repos.yaml](argocd-repos.yaml) だけ。下の「ArgoCD が当てるもの」)。
層の分け方は [docs/decisions.md](../docs/decisions.md)「層の分け方」。

| | 何を | いつ |
| --- | --- | --- |
| **machine config**(このディレクトリ) | Talos の設定、Helm で入れるもの(cilium・cert-manager・argocd・lvm-localpv)、`apiserver-rbac.yaml`、`storage.yaml`、SOPS 済みの Secret 2 つ | `apply.sh` → `upgrade-k8s`([talos.md](talos.md)「当て方」) |
| **ArgoCD**(`deploy/`) | 平文のマニフェスト(`ClusterIssuer`・Gateway・auth など)と SOPS 済みの `SopsSecret`。2026-10 まではここにあって、Application `bootstrap` が当てていた | main へのマージ(prune / selfHeal 付き) |

## ファイル

部品ごとに 1 ファイルを基本にして、ディレクトリを切らない。部品の名前を頭に付ける。

| ファイル | 中身 |
| --- | --- |
| [render.sh](render.sh) | machine config を組む。下のファイルを全部読む |
| [talos.md](talos.md) | Talos の組み立て・書き方・当て方 |
| [talos.sops.yaml](talos.sops.yaml) | 手で書く machine config(`password` の値だけ SOPS)。先頭のコメントに Talos・Kubernetes・Gateway API の版と schematic |
| [talos-secrets.sops.yaml](talos-secrets.sops.yaml) | クラスタの CA 一式(丸ごと SOPS) |
| [cilium-values.yaml](cilium-values.yaml) | chart の値と版(下の「Helm で入れるもの」) |
| [argocd-values.sops.yaml](argocd-values.sops.yaml) | chart の値と版。通知先の URL と GitHub App の鍵だけ SOPS |
| [cert-manager-values.sops.yaml](cert-manager-values.sops.yaml) | chart の値と版。2 つめのドキュメントが DNS-01 の Cloudflare のトークンの Secret(トークンだけ SOPS) |
| [apiserver-rbac.yaml](apiserver-rbac.yaml) / [apiserver-ca.crt](apiserver-ca.crt) | API サーバの入口の RBAC と CA(下の「API サーバの入口」) |
| [lvm-localpv-values.yaml](lvm-localpv-values.yaml) | chart の値と版(OpenEBS LVM LocalPV。PVC の置き場。下の「PVC の置き場」) |
| [storage.yaml](storage.yaml) | StorageClass `local-path`・VolumeSnapshotClass・thin プールを作る DaemonSet(chart が描かないもの) |
| [argocd-repos.yaml](argocd-repos.yaml) | ArgoCD が当てる唯一のファイル(下の「ArgoCD が当てるもの」) |

**SOPS(age)で暗号化したファイルは名前を `*.sops.yaml` で終える**(`.sops.yaml` の規則もその名前にしか一致しないので、
別の名前では暗号化できない)。復号鍵はクラスタにも CI にも渡さない。
鍵は [`recovery/sops-age.key.age`](../recovery/)。
`talos-secrets.sops.yaml` 以外は**秘密のキーの値だけ**を暗号化し(`.sops.yaml` の `encrypted_regex`)、`mac_only_encrypted` で
MAC も暗号化した値だけを見る。なので**平文の部分(コメントの `# version:` も)は sops を通さず直接直してよい**
(Renovate もそうする)。秘密の値を足す・変えるときは `sops edit`。**秘密のキーを新しく足すときは `.sops.yaml` の
`encrypted_regex` にも足す**(当たらないキーは平文のまま書かれる)。`talos-secrets.sops.yaml` は丸ごとなので `sops edit` だけ。

## ArgoCD が当てるもの

**ここで ArgoCD が当てるのは [argocd-repos.yaml](argocd-repos.yaml) だけ。** machine config に載っている
`apps` の Application(`argocd-values.sops.yaml` の `extraObjects`)が拾い、そこから ApplicationSet が `deploy/` を当てる。
場所(`path: bootstrap` と `include: argocd-repos.yaml`)が machine config に焼いてあるので、名前を変えると machine config を当て直すことになる。
そのときは **main にマージしてから当てる**。マージから当てるまでの間、`apps` は古い path が無くて ComparisonError で止まるだけ
(何も消さない)。逆に先に当てると、新しい include が main の何にも当たらず空の描き出しになる(自動同期は空にする
prune を `allowEmpty` 無しでは拒むが、頼らない)。

ArgoCD の平文のマニフェストは `deploy/` にある:
[deploy/gateway/](../deploy/gateway/)(Gateway と http → https)、[deploy/auth/](../deploy/auth/)(SSO の oauth2-proxy)、
[deploy/cert-manager/](../deploy/cert-manager/)(`ClusterIssuer`)、[deploy/argocd/](../deploy/argocd/)(HTTPRoute と OIDC の `SopsSecret`)。
`ClusterIssuer` や Gateway は本体(cert-manager・cilium)が machine config に居ても、書き換えるのは平文のマニフェストなので
ArgoCD に任せる。

## Helm で入れるもの

どれも `render.sh` が `helm template` して machine config に載せる。どれも同じ形で、
**`<name>-values.yaml` の 1 本**(秘密を含むものは `<name>-values.sops.yaml`)に chart・repo・版と値をまとめる。
先頭の 2 行が chart と版:

```yaml
# renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io
# version: 1.20.4
```

`# renovate:` の行から `render.sh` が chart(`depName`)と repo(`registryUrl`)を、次の `# version:` の行から版を読む。
版をコメントにしているのは、値として書くと chart に渡ってしまうから。Renovate も同じ 2 行を見て上げる(`renovate.json` の customManagers)。
Talos・Kubernetes・Gateway API の版も同じ形で、[talos.sops.yaml](talos.sops.yaml) の先頭のコメントにある。
秘密を含む argocd・cert-manager は `<name>-values.sops.yaml` で、秘密の値だけ暗号化してある(上の SOPS の段落)。
`render.sh` が復号してから helm に渡す。**2 つめのドキュメントがあれば、それは chart とは別に machine config に載せる Secret**
(cert-manager の Cloudflare のトークン。ArgoCD は復号できないのでここに置く)で、
`render.sh` が `---` で分けて別の inlineManifest にする。
argocd の版は自動マージしない(`renovate.json` の `bootstrap charts`)。lvm-localpv も(`openebs lvm`。`storage.yaml` の lvm-driver のイメージと同じ PR)。
Namespace は chart が描かないので、`render.sh` が kube-system 以外のものに付ける。

## git と live がずれていないか

**cilium だけは [cilium-drift.yml](../.github/workflows/cilium-drift.yml) が見ている**(下の「cilium」)。**残りは見ていない。**
直したら流す(流し忘れたことは誰も教えてくれない)。描くたびに変わる値は潰してあるので、
`apply-config --dry-run` に出る差分は全部本物([talos.md](talos.md)「machine config と inlineManifests」)。

## cilium

**クラスタの土台。** CNI・kube-proxy の代替・Gateway API を全部これが担う。
決定の経緯は [../docs/decisions.md](../docs/decisions.md)「ルーティングの選定」。

[cilium-values.yaml](cilium-values.yaml) を直したら **`apply.sh` → `upgrade-k8s`**
([talos.md](talos.md)「当て方」)。`helm upgrade` は使わない。値はここが正本で、machine config は
`render.sh` がここから描く派生物(二度書かない。decisions.md「machine config と Cilium の chart をどう連動させるか」)。
**どの設定が何のために要るかは [cilium-values.yaml](cilium-values.yaml) のコメントにある**(ここには写さない)。

**Hubble の証明書はクラスタの中の CronJob が作る**(`hubble.tls.auto.method: cronJob`)。chart の既定(`helm`)は描くたびに
作り直して machine config に秘密鍵が載り、値を変えなくても `upgrade-k8s` の差分に出ていた。

### ズレは CI が見ている

**当て忘れとクラスタ側の直接編集は [cilium-drift.yml](../.github/workflows/cilium-drift.yml) が見つける。**
`cilium-values.yaml` から `cilium-config` の ConfigMap を描いて live と突き合わせるだけで、**読むだけ**(権限は `cilium-config` の `get` 1 つ)。
`cilium-values.yaml` を触ったときと毎週月曜に走る。当てるのは自動化しない(Talos API の os:admin を CI に置かない)。

### 当てたあとに確認すること

```shell
# ホストのポートが張られているか(eBPF なので ss には出ない)
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | grep -i hostport
# Gateway のリスナーが載っているか(住所はノードの IP になる)
kubectl -n kube-system get gateway doany
```

## PVC の置き場

**OpenEBS LVM LocalPV**(thin)。PVC ごとに VG `data` の thin プールから LV を切り、xfs で渡す。
各アプリの PVC が載る土台なので bootstrap 層に居る。選んだ理由と組んだ形は [../docs/decisions.md](../docs/decisions.md)「ストレージを OpenEBS LVM LocalPV に…」。

| 何を | 誰が |
| --- | --- |
| パーティション `r-lvm` と VG `data` | Talos([talos.sops.yaml](talos.sops.yaml) の `RawVolumeConfig` / `LVMVolumeGroupConfig`)。**入れ直したときにしか作られない** |
| thin プール `data_thinpool`(VG の 90%) | [storage.yaml](storage.yaml) の DaemonSet `lvm-thinpool`。出来たらノードに `doany.io/lvm-thinpool=ready` を付ける |
| CSI ドライバ(`local.csi.openebs.io`) | chart([lvm-localpv-values.yaml](lvm-localpv-values.yaml))。ノードの Pod は上のラベルが付いてから動く |
| StorageClass `local-path`(既定)・VolumeSnapshotClass `lvm`(既定) | [storage.yaml](storage.yaml) |
| snapshot-controller と VolumeSnapshot の CRD | `render.sh` が external-snapshotter のタグの URL で(版は [talos.sops.yaml](talos.sops.yaml) の先頭) |

- **PVC の requests が本当の上限。** 足りなくなったら PVC の requests を上げる(`allowVolumeExpansion: true`。スナップショットのある PVC は広げられない)
- **thin プールが溢れると全部の PVC の書き込みが止まる。** `kubectl -n kube-system get pods -l app=lvm-thinpool` が 90% で NotReady になる。
  埋まり具合は `kubectl -n kube-system exec ds/lvm-thinpool -c watch -- lvs data`。足すときは VG の残り(1 割)から
  `kubectl -n kube-system exec ds/lvm-thinpool -c watch -- lvextend -L +10G data/data_thinpool`
- **新しい PVC の直下は root の 0755。** root 以外で書くアプリは Pod に `fsGroup` を付ける

## Secret

平文の Secret はどのリポジトリにもコミットしない。**値は SOPS で暗号化して git に置き**(各リポジトリの `deploy/` の
`SopsSecret`)、クラスタの中の [sops-secrets-operator](../deploy/sops-secrets-operator/) が復号して普通の `Secret` を作る
(理由は [../docs/decisions.md](../docs/decisions.md)「秘密は SOPS で git に置く」。2026-11-02 までは Infisical)。

- **operator が復号に使うクラスタの age の鍵だけがここ**([sops-age.sops.yaml](sops-age.sops.yaml)。machine config が
  `sops-secrets-operator` の namespace ごと入れる)。Argo CD も CI もこの鍵を持たない。
- `SopsSecret` はクラスタの鍵と管理者の鍵の両方で暗号化する([../.sops.yaml](../.sops.yaml) の `deploy/` の規則)ので、手元で `sops edit` できる。
- Secret が変わったときの Pod の入れ替えは [Reloader](../deploy/reloader/)(workload に `reloader.stakater.com/auto: "true"`)。

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
認証設定([talos.sops.yaml](talos.sops.yaml))も [apiserver-rbac.yaml](apiserver-rbac.yaml) も machine config に載せ、
**ArgoCD には当てさせない**(ArgoCD も CI も要らずに効く層なので、締め出されたときに直せる)。
変えたら `render.sh` → `apply-config`(RBAC は inlineManifest なので `upgrade-k8s` まで)。

### アプリ側の書き方

各リポジトリの `deploy/secrets.sops.yaml` に namespace ごと 1 つの `SopsSecret` を置き、`secretTemplates` に Secret を並べる
(例: [../deploy/matrix/secrets.sops.yaml](../deploy/matrix/secrets.sops.yaml))。暗号化するのは `data`・`stringData` の値だけ
(先頭のコメントと名前は平文のまま読める)。各リポジトリの `.sops.yaml` もこのリポジトリの `deploy/` の規則と同じ鍵 2 つにする。

```shell
tools/t.ps1 sops edit deploy/<アプリ>/secrets.sops.yaml   # 直して push すると、Argo CD が当てた時点で Secret が変わる
```

**sync-options の注釈は要らない。** まっさらなクラスタでは `SopsSecret` の CRD がまだ無く、同じ同期の中の CR の
dry-run で同期が丸ごと落ちる。これは ApplicationSet(`argocd-repos.yaml`)の syncOptions の `SkipDryRunOnMissingResource=true` で
全部のアプリに効かせてある。ApplicationSet の外の Application(chart を入れるものなど)で CR を書くときだけ、そちらに付ける。
作られた `Secret` は Argo CD が丸ごと管理の対象から外している(`argocd-values.sops.yaml` の `resource.exclusions`)ので prune されない。
