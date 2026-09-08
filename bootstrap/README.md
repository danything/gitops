# bootstrap

クラスタそのものを組む層。**Argo CD は同期しない**(`apps/` の外にあるため)。
代わりに **main へのマージで GitHub Actions が当てる**(下の「適用は GitHub Actions がやる」)。

**SOPS(age)で暗号化した 4 ファイルだけは手で当てる** ── CI に復号鍵を渡さないため。
**中を編集するときも sops を通すこと**(下の「Helm で入れるもの」に手順)。MAC は暗号化して
いない値も含めて計算されるので、**平文で 1 行足すだけでも `sops -d` が MAC 不一致で落ちる。**
`infisical/secrets.yaml`、`infisical/helmchart.yaml`、`argocd/helmchart.yaml`、
`cert-manager/cloudflare-secret.yaml`。鍵は [`recovery/sops-age.key.age`](../recovery/)。

いま動いているのは Ubuntu 26.04(NetworkManager、netplan バックエンド、TZ は UTC)の暫定構成で、
最終形は Talos Linux。進捗は [ROADMAP.md](../ROADMAP.md)、なぜそうしたかは [docs/decisions.md](../docs/decisions.md)。
Talos では**この層は machine config の `inlineManifests` に載る**ので、手で apply する工程自体が無くなる。

## Helm で入れるもの

`bootstrap/` には Helm で入れるものが 3 つある。**版と値をどこに置くかが揃っていなかったので、
2026-09-08 に整理した。**

| | 版 | 値 |
| --- | --- | --- |
| cilium | [cilium/version.yaml](cilium/version.yaml) | [cilium/values.yaml](cilium/values.yaml) |
| **cert-manager** | [cert-manager/version.yaml](cert-manager/version.yaml) | [cert-manager/values.yaml](cert-manager/values.yaml) |
| argocd / infisical | CR の `spec.version` | CR の `spec.values` |

**cert-manager は版も値も git に無かった**(2026-09-08 に出した)。経緯は
[cert-manager/values.yaml](cert-manager/values.yaml) の冒頭 ── ここには写さない。

**argocd と infisical の版は 2026-09-08 に固定した**(argo-cd 10.8.1 /
infisical-standalone 1.10.0)。それまでは `HelmChart` CR に `version:` が無く、
コントローラが**そのときの最新**を入れていた ── 作り直すと別の版になるし、Renovate も追えない。
**`chart:` `repo:` `version:` は連続 3 行**にしてある(`renovate.json` の customManager が
その並びを見る)。

**中を触るときは平文で書き足さないこと** ── MAC は暗号化していない値も含めて計算されるので、
1 行足すだけで `sops -d` が壊れる。位置を選びたいので `sops set` ではなくこの順でやった:

```shell
sops decrypt --in-place bootstrap/argocd/helmchart.yaml
# repo: の次の行に version: を足す
sops encrypt --in-place bootstrap/argocd/helmchart.yaml
sops -d bootstrap/argocd/helmchart.yaml | diff - <復号したもの>   # 差分が 1 行だけか見る
```

## git と live がずれていないか(2026-09-08 に確認)

**machine config は git の値で描く**ので、git と実機がずれていると、移行した瞬間に
別物が入る。cilium は [cilium-drift.yml](../.github/workflows/cilium-drift.yml) が
毎日見ているが、**残りは見ていない**ので手で突き合わせた。

```shell
helm get values <release> -n <ns>     # ← 実機
# ↑と bootstrap/<name>/values.yaml(cert-manager)または
#   HelmChart CR の spec.values(argocd / infisical)を比べる
```

| | 結果 |
| --- | --- |
| cert-manager | **一致**(`config.enableGatewayAPI: true` / `crds.enabled: true`) |
| argocd | **一致**(88 行、秘密を伏せて比較) |
| infisical | **一致**(51 行、同上) |

**CI では自動化できない。** helm の値は**リリースの Secret の中**にあり、
`bootstrap-applier` の ClusterRole には**意図的に Secret の権限が無い**
([apiserver/rbac.yaml](apiserver/rbac.yaml))。cilium が自動化できているのは、
値が `cilium-config` という **ConfigMap** に出ているから。
**権限を広げるより、移行前に手で見るほうが安い**と判断した。

**比べるときは値を伏せること。** `helm get values` は平文を吐く。
秘密のキー(`password` / `githubAppPrivateKey` / `service.webhook.mattermost` など)を
`<SECRET>` に置き換えてから diff する ── **画面に出した時点で漏れたのと同じ。**

## Secret

平文の Secret はアプリのリポジトリにはコミットしない。値は **Infisical**(https://il.doany.io、このクラスタでセルフホスト)が持ち、
**Infisical 純正 operator**（`infisical/operator.yaml`）が各リポジトリの `InfisicalSecret` を見て Infisical から値を取り、普通の `Secret` を作る。
`secrets.infisical.com/auto-reload` 注釈のある Deployment は Secret 更新時に自動で入れ替わる。
認証は Kubernetes 方式（TokenReview・長命の資格情報なし）。

- `infisical/` … Infisical 本体(HelmChart + Postgres/Redis)。公開経路は [`apps/infisical/httproute.yaml`](../apps/infisical/httproute.yaml)。
  `secrets.yaml` の `ENCRYPTION_KEY` が DB の暗号鍵で、これを失うと Infisical の中身が全部読めなくなる
  (クラスタで一番失ってはいけない値)。Postgres の PVC は `local-path-retain` で、バックアップ対象に入っている。
- **operator と push-bridge はここには無い。** ArgoCD の Application に移した(`apps/infisical-operator/`、
  `apps/infisical-push-bridge/`)。ArgoCD 自身は operator に依存しないので、bootstrap に置く理由がない。
  認証は Infisical の Kubernetes auth: operator が SA `infisical-auth` のトークンで Infisical にログインし、
  Infisical がそのトークンで TokenReview を呼んで本物か確かめる(なので SA に `system:auth-delegator` を
  付けてある)。SA と RBAC は `apps/infisical-operator/rbac.yaml`。
  operator 側に長期の資格情報は無い(`identityId` は秘密ではない)。

### 適用は GitHub Actions がやる(2026-09-07)

**main にマージすると [`.github/workflows/bootstrap-apply.yml`](../.github/workflows/bootstrap-apply.yml)
がこの層を当てる。** 手で `kubectl apply` する必要は無くなった。

**保存している秘密はゼロ。** GitHub Actions の OIDC トークンを API サーバが直接受ける
([apiserver/authentication-config.yaml](apiserver/authentication-config.yaml))。
kubeconfig も age 鍵も GitHub に置いていない。トークンは実行のたびに発行され数分で切れ、
`danything/gitops` の `main` の `bootstrap-apply.yml` からのものだけが通る(CEL で固定)。

権限も cluster-admin ではなく、この層で実際に使う種類だけ([apiserver/rbac.yaml](apiserver/rbac.yaml))。
**Secret は含まれていない**ので、GitHub 側が落ちても Secret は読まれない。`delete` も渡していない。

**設定を変えるときの手順**(2026-09-07 に実地で確認):

| 変えるもの | 必要なこと |
| --- | --- |
| [apiserver/authentication-config.yaml](apiserver/authentication-config.yaml) | ホストの `/etc/rancher/k3s/` に置き直すだけ。**API サーバが自動で読み直す**(k8s 1.32+ の structured authn の再読み込み)。k3s の再起動は要らない |
| [apiserver/rbac.yaml](apiserver/rbac.yaml) | **手で `kubectl apply`。** ワークフローには ClusterRole を作る権限を渡していない(自分の権限を書き換えられないように) |
| `kube-apiserver-arg` / `tls-san`(`/etc/rancher/k3s/config.yaml`) | **k3s の再起動が要る。** 失敗すると API サーバが上がらないので、必ず `config.yaml.pre-oidc` のような退避を取ってから |

**当たらないもの:**

| | 理由 |
| --- | --- |
| SOPS で暗号化した 4 ファイル | 復号鍵(age)を GitHub に置かないため。**手で当てる**(下記)。判定はファイルの中身を見ているので、暗号化ファイルが増えても自動で除外される |
| `cilium/values.yaml` | Helm の値でマニフェストではない。`helm upgrade` で当てる(ファイル冒頭を読むこと) |

暗号化してあるものは今までどおり:

```shell
sops -d infisical/secrets.yaml | kubectl apply -f -
```

### 公開経路(HTTPRoute)もここにある

**`httproute.yaml` は ArgoCD が同期しない。** 変更したら手で apply すること。

`argocd` と `auth` の HTTPRoute は元は `apps/gateway-routes/` にあり、ArgoCD が同期していた。
**が、それは「ArgoCD が ArgoCD 自身を公開している経路を握っている」状態で、層が逆**だった
(ArgoCD が壊れているときに、その経路を ArgoCD 経由でしか直せない)。2026-09-07 に、
公開される当のものと同じ場所へ移した。`gateway/redirect-https.yaml` も Gateway そのものの
設定なのでここ。

アプリ側の経路は逆に**アプリと同じ場所**に置いてある(`apps/<name>/httproute.yaml`、
または各アプリのリポジトリの `deploy/httproute.yaml`)。

### Infisical の中の構成

| | |
| --- | --- |
| Project | `doa`（slug `doa`）、環境は `prod` だけ |
| フォルダ | `/<namespace>/<Secret 名>`(例: `/denpa/denpa-oidc`、`/worklog/ghcr-pull`) |
| シークレット名 | 作られる `Secret` の **キー名そのまま**(`client-id`、`.dockerconfigjson` など) |
| Machine Identity | `infisical-operator`(Kubernetes auth、許可 SA は `infisical/infisical-auth`、project の viewer) |
| 管理者 | 個人アカウント。資格情報はリポジトリに置かない。復旧手順は `infisical/README.md` |
| 共有値 | `/shared/entra`(Entra 共用アプリの client-id / client-secret / issuer / admins-group)と `/shared/smtp`(info@doany.io)。各アプリのフォルダは `${prod.shared.entra.client-secret}` のような参照で、ローテーションは shared 側の 1 回で済む(operator が展開する) |
| SMTP | info@doany.io(Exchange Online、mattermost/erpnext と同じ)。パスワードだけ Infisical の `/infisical/infisical-smtp` に置き、`infisical/smtp-secret.yaml` が Secret にする |

### `Prune=false` を必ず付けること

`InfisicalSecret` には `argocd.argoproj.io/sync-options: Prune=false` を付ける。

**operator は CR の annotation を、作った `Secret` にもコピーする。** ArgoCD の
tracking-id までコピーされると、ArgoCD がその `Secret` を「git に無い管理対象」と
見なして sync のたびに prune する(復元リハーサル 2026-09-06 で発覚)。
`Prune=false` も一緒にコピーさせて、prune の対象から外す。

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
