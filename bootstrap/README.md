# bootstrap

クラスタそのものを組む層。2 つの経路で当たる([docs/decisions.md](../docs/decisions.md)「層の分け方」):

| | 何を | いつ |
| --- | --- | --- |
| **machine config**([../talos/render.sh](../talos/render.sh) が描く) | Helm で入れるもの(cilium・cert-manager・argocd・infisical)、`apiserver/rbac.yaml`、SOPS 済みの Secret 2 つ | `render.sh` → `apply-config` → `upgrade-k8s`([../talos/README.md](../talos/README.md)「上げ方 / 当て直し方」) |
| **ArgoCD**(Application `bootstrap`。[argocd/repos.yaml](argocd/repos.yaml)) | 残りの平文のマニフェスト(`ClusterIssuer`・Gateway・auth・`InfisicalSecret` など) | main へのマージ(prune / selfHeal 付き) |

`InfisicalSecret` の CRD だけは `apps/infisical/operator.yaml` が入れるので、まっさらなクラスタでは `bootstrap` の同期が
最初の何回か落ちて retry で戻る。

**SOPS(age)で暗号化したファイルは ArgoCD が当てない** ── 復号鍵をクラスタにも CI にも渡さないため。
**名前を `*.sops.yaml` で終える**と `bootstrap` の `exclude` が外す(`.sops.yaml` の規則も
その名前にしか一致しないので、別の名前では暗号化できない)。
`infisical/secrets.sops.yaml`、`cert-manager/cloudflare-secret.sops.yaml`、`{argocd,infisical}/secret-values.sops.yaml`。
鍵は [`recovery/sops-age.key.age`](../recovery/)。**中を編集するときも `sops edit` を通すこと。** MAC は暗号化して
いない値も含めて計算されるので、**平文で 1 行足すだけでも `sops -d` が MAC 不一致で落ちる。**

## Helm で入れるもの

どれも `render.sh` が `helm template` して machine config に載せる。どれも同じ形で、
`<name>/version.yaml`(chart・repo・版。Renovate が上げる)と `<name>/values.yaml`(値)。
argocd と infisical は、値のうち秘密だけを `<name>/secret-values.sops.yaml`(SOPS、丸ごと暗号化)に分けて上に重ねる。
argocd・infisical の版は自動マージしない(`renovate.json` の `bootstrap charts`)。

## git と live がずれていないか

**cilium は [cilium-drift.yml](../.github/workflows/cilium-drift.yml) が週次で見ている**(値が `cilium-config` という
ConfigMap に出ているので、読むだけの権限で比べられる)。**残りは見ていない。** 当て忘れは `upgrade-k8s` の差分に出るので、
直したら流す(流し忘れたことは誰も教えてくれない)。描くたびに変わる値は潰してあるので、
`apply-config --dry-run` に出る差分は全部本物([../talos/README.md](../talos/README.md)「inlineManifests を直したとき」)。

## Secret

平文の Secret はアプリのリポジトリにはコミットしない。値は **Infisical**(https://il.doany.io、このクラスタでセルフホスト)が持ち、
**Infisical 純正 operator**(`apps/infisical/operator.yaml`)が各リポジトリの `InfisicalSecret` を見て Infisical から値を取り、普通の `Secret` を作る。
認証は Kubernetes 方式（TokenReview・長命の資格情報なし）。

- `infisical/` … Infisical 本体(chart + Postgres/Redis)。公開経路は [`apps/infisical/httproute.yaml`](../apps/infisical/httproute.yaml)。
  `secrets.sops.yaml` の `ENCRYPTION_KEY` が DB の暗号鍵で、これを失うと Infisical の中身が全部読めなくなる
  (クラスタで一番失ってはいけない値)。Postgres の PVC は既定の `local-path` で、`pg_dump` を k8up が日次で取っている。
- **operator と push-bridge はここには無い**(`apps/infisical/operator.yaml`、`apps/infisical/push-bridge.yaml`)。
  ArgoCD 自身は operator に依存しないので、bootstrap に置く理由がない。
  認証は Infisical の Kubernetes auth: operator が SA `infisical-auth` のトークンで Infisical にログインし、
  Infisical がそのトークンで TokenReview を呼んで本物か確かめる(なので SA に `system:auth-delegator` を
  付けてある)。SA と RBAC は `apps/infisical/operator-rbac.yaml`。
  operator 側に長期の資格情報は無い(`identityId` は秘密ではない)。

### API サーバの入口(GitHub Actions と人)

**GitHub Actions は読むだけ。** cilium-drift.yml の OIDC トークンを API サーバが直接受け
([../talos/controlplane.yaml](../talos/controlplane.yaml) の `KubeAuthenticationConfig`)、
権限は `cilium-config` の `get` だけ([apiserver/rbac.yaml](apiserver/rbac.yaml))。
CA は [apiserver/ca.crt](apiserver/ca.crt)(`talos/secrets.yaml` のクラスタ CA。作り直したら替える)。
kubeconfig も age 鍵も GitHub に置いていない。

**同じ認証設定と RBAC が人の入口でもある。** Entra を 2 つめの issuer として足し、
Headlamp が利用者本人の id_token を API サーバへ転送する。アプリロール `admin` を持つ人は
`entra:admin` で cluster-admin、それ以外は `entra:viewer` で読み取り専用(組み込みの `view`
＋ CRD とノードぶんの `readonly-extra`)。**振り分けは CEL で、割り当ては Entra 側で完結する。**
ここに置いたのは、ArgoCD も CI も要らずに効く層だから ── 締め出されたときに直せる。
認証設定([../talos/controlplane.yaml](../talos/controlplane.yaml))も [apiserver/rbac.yaml](apiserver/rbac.yaml) も
machine config に載っているので、変えたら `render.sh` → `apply-config`(RBAC は inlineManifest なので `upgrade-k8s` まで)。
**ArgoCD には当てさせない**(`bootstrap` の exclude に `apiserver/`。締め出されたときに直せる層に置く)。

### 公開経路(HTTPRoute)もここにある

`argocd` と `auth` の HTTPRoute と `gateway/redirect-https.yaml` はここ
([docs/decisions.md](../docs/decisions.md)「公開経路(HTTPRoute)をどこに置くか」)。

### Infisical の中の構成

| | |
| --- | --- |
| Project | `doa`（slug `doa`）、環境は `prod` だけ |
| フォルダ | `/<namespace>/<Secret 名>`(例: `/denpa/denpa-oidc`、`/worklog/ghcr-pull`) |
| シークレット名 | 作られる `Secret` の **キー名そのまま**(`client-id`、`.dockerconfigjson` など) |
| Machine Identity | `infisical-operator`(Kubernetes auth、許可 SA は `infisical/infisical-auth`、project の viewer) |
| 管理者 | 個人アカウント。資格情報はリポジトリに置かない。復旧手順は `infisical/README.md` |
| 共有値 | `/shared/entra`(Entra 共用アプリの client-id / client-secret / issuer / role / tenant-id)と `/shared/smtp`(info@doany.io)。各アプリのフォルダは `${prod.shared.entra.client-secret}` のような参照で、ローテーションは shared 側の 1 回で済む(operator が展開する) |
| SMTP | info@doany.io(Exchange Online)。パスワードだけ Infisical の `/infisical/infisical-smtp` に置き、`infisical/smtp-secret.yaml` が Secret にする |

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

`bootstrap/` の `InfisicalSecret`(`argocd/oidc-secret.yaml`・`auth/secrets.yaml`・`infisical/smtp-secret.yaml`)にも付けてある。

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
