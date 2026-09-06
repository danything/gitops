# bootstrap

クラスタそのものを組む層。**Argo CD は同期しない**(`apps/` の外にあるため)。手で `kubectl apply` する。
秘密を含む 4 ファイル(`infisical/secrets.yaml`、`infisical/helmchart.yaml`、`argocd/helmchart.yaml`、
`traefik/cloudflare-secret.yaml`)は SOPS(age)で暗号化してあるので、適用は `sops -d <file> | kubectl apply -f -`。
鍵は [`gitops の recovery/`](https://github.com/gitops の recovery/) の `sops-age.key.age`。

このホストの構成は暫定(最終形は Talos Linux)。方針と手順は [ROADMAP.md](../ROADMAP.md)。
いま動いているのは Ubuntu 26.04(NetworkManager、netplan バックエンド、TZ は UTC)。README 冒頭の dnf の手順は
Fedora に載せ替える予定だった頃のもので、旧方式と一緒に消す。

## バックアップと復元(restic)

ホストに repo は置かない。秘密は `/etc/k3s-backup/env` の 4 行(restic のリポジトリ URL とパスフレーズ、R2 の鍵)だけ。
これを age のパスフレーズ暗号化した `env.age` として、復元スクリプトと一緒に **公開 repo
[gitops の recovery/](https://github.com/gitops の recovery/)** に置いてある(この repo は private なので、復元のときに
GitHub ログインが要らないように別に出した)。覚えるのは age のパスフレーズ 1 つで、それは Edge のパスワードマネージャーと紙に 1 部。

```shell
age -p -o env.age /etc/k3s-backup/env   # 値を変えたら recovery repo で作り直してコミット
```

**バックアップ**(毎日 04:00、`backup/`): 対象 namespace を scale down → state.db を sqlite でホットバックアップ →
PVC データ・k3s の証明書・k3s と NetworkManager の設定・timer 一式を restic へ → scale up → `forget --prune` → `check`。
稼働中ホストへの導入は 1 回だけ clone して:

```shell
sudo ./backup/install.sh   # env を埋めて再実行 → restic init と timer 有効化
rm -rf bootstrap                      # 以後ホストに repo は要らない
```

**復元**(まっさらな Ubuntu ホスト。スクリプトも env.age も公開 repo から取る):

```shell
curl -fsSLO https://raw.githubusercontent.com/danything/gitops/main/recovery/restore.sh
sudo sh restore.sh       # age のパスフレーズを聞かれる
# 最後にネットワーク設定を当てて k3s を起動するので SSH が切れる。10.0.0.2 か 10.10.0.4 に入り直す。
```

### 旧方式(復元リハーサルが通ったら削除)

`backup.sh` / `init.sh` / `setup-network.sh` / `k3s-server-config.yaml` は tar + rclone の旧方式。
init.sh は clone 先へ symlink するのでホストに repo が要る。新方式ではこれらの内容は全部スナップショットに入る。

```shell
gh auth login -s read:packages && gh repo clone bootstrap
./bootstrap/setup-network.sh   # ネットが切れるので入りなおす
./bootstrap/init.sh
```

## Secret

平文の Secret はアプリのリポジトリにはコミットしない。値は **Infisical**(https://il.doany.io、このクラスタでセルフホスト)が持ち、
**Infisical 純正 operator**（`infisical/operator.yaml`）が各リポジトリの `InfisicalSecret` を見て Infisical から値を取り、普通の `Secret` を作る。
`secrets.infisical.com/auto-reload` 注釈のある Deployment は Secret 更新時に自動で入れ替わる。
認証は Kubernetes 方式（TokenReview・長命の資格情報なし）。

- `infisical/` … Infisical 本体(HelmChart + Postgres/Redis)と Ingress。
  `secrets.yaml` の `ENCRYPTION_KEY` が DB の暗号鍵で、これを失うと Infisical の中身が全部読めなくなる
  (クラスタで一番失ってはいけない値)。Postgres の PVC は `local-path-retain`、`backup.sh` の対象にも入れてある。
- `infisical/operator.yaml` … 純正 operator の HelmChart と、認証用の SA `infisical-auth` + RBAC。
  認証は Infisical の Kubernetes auth: operator が SA のトークンで Infisical にログインし、Infisical が
  そのトークンで TokenReview を呼んで本物か確かめる(なので SA に `system:auth-delegator` を付けてある)。
  operator 側に長期の資格情報は無い(`identityId` は秘密ではない)。

argocd/ と同じく、このディレクトリは手で apply する(init.sh はバックアップから丸ごと復元するので通常は不要):

```shell
kubectl apply -f infisical/
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

各リポジトリの `k3s/` に `InfisicalSecret` を置く。フォルダ内のシークレットを全部そのままキーにするので、
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
