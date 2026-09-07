# bootstrap

クラスタそのものを組む層。**Argo CD は同期しない**(`apps/` の外にあるため)。手で `kubectl apply` する。
秘密を含む 4 ファイル(`infisical/secrets.yaml`、`infisical/helmchart.yaml`、`argocd/helmchart.yaml`、
`cert-manager/cloudflare-secret.yaml`)は SOPS(age)で暗号化してあるので、適用は `sops -d <file> | kubectl apply -f -`。
鍵は [`recovery/sops-age.key.age`](../recovery/)。

いま動いているのは Ubuntu 26.04(NetworkManager、netplan バックエンド、TZ は UTC)の暫定構成で、
最終形は Talos Linux。進捗は [ROADMAP.md](../ROADMAP.md)、なぜそうしたかは [docs/decisions.md](../docs/decisions.md)。
Talos では**この層は machine config の `inlineManifests` に載る**ので、手で apply する工程自体が無くなる。

## Secret

平文の Secret はアプリのリポジトリにはコミットしない。値は **Infisical**(https://il.doany.io、このクラスタでセルフホスト)が持ち、
**Infisical 純正 operator**（`infisical/operator.yaml`）が各リポジトリの `InfisicalSecret` を見て Infisical から値を取り、普通の `Secret` を作る。
`secrets.infisical.com/auto-reload` 注釈のある Deployment は Secret 更新時に自動で入れ替わる。
認証は Kubernetes 方式（TokenReview・長命の資格情報なし）。

- `infisical/` … Infisical 本体(HelmChart + Postgres/Redis)。公開は `apps/gateway-routes/` の HTTPRoute。
  `secrets.yaml` の `ENCRYPTION_KEY` が DB の暗号鍵で、これを失うと Infisical の中身が全部読めなくなる
  (クラスタで一番失ってはいけない値)。Postgres の PVC は `local-path-retain` で、バックアップ対象に入っている。
- **operator と push-bridge はここには無い。** ArgoCD の Application に移した(`apps/infisical-operator/`、
  `apps/infisical-push-bridge/`)。ArgoCD 自身は operator に依存しないので、bootstrap に置く理由がない。
  認証は Infisical の Kubernetes auth: operator が SA `infisical-auth` のトークンで Infisical にログインし、
  Infisical がそのトークンで TokenReview を呼んで本物か確かめる(なので SA に `system:auth-delegator` を
  付けてある)。SA と RBAC は `apps/infisical-operator/rbac.yaml`。
  operator 側に長期の資格情報は無い(`identityId` は秘密ではない)。

このディレクトリは手で apply する(復元時はバックアップから丸ごと戻るので通常は不要):

```shell
kubectl apply -f infisical/
sops -d infisical/secrets.yaml | kubectl apply -f -   # 暗号化してあるものはこの形で
```

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
