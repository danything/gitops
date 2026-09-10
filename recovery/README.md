# recovery

サーバをまっさらな状態から戻すためのもの。**秘密は暗号化してあるので、この repo は公開のままでよい。**

| | |
| --- | --- |
| `restore.sh` | 復元スクリプト。Cloudflare R2 の restic バックアップから k3s ホストを丸ごと戻す。**k3s 期だけ**(下記) |
| `env.age` | バックアップ先の資格情報(R2 の鍵、restic のパスワード)。age のパスフレーズで暗号化 |
| `sops-age.key.age` | `../bootstrap/` の SOPS ファイルを復号する age 秘密鍵。**同じパスフレーズ**で暗号化 |

手で持つのは **age のパスフレーズ 1 つだけ**。GitHub へのログインは要らない。
置き場の考え方は [../docs/decisions.md](../docs/decisions.md)「そのパスフレーズをどこに置くか」。

**Talos の秘密はここには無い。** `talos/secrets.yaml`(SOPS 済み)にあり、上の age 鍵で開く。
**`talosconfig` はどこにも保存していない** ── `secrets.yaml` から `talosctl gen config` で毎回出る
派生物なので、使い捨てにする([../talos/README.md](../talos/README.md))。

**この 2 ファイルは紙にも刷っておくこと。** 上の手順は「GitHub にログインしなくてよい」だけで、
**リポジトリが読めることは前提にしている**。base64 で `env.age` が 12 行、`sops-age.key.age` が 7 行。

```shell
base64 recovery/env.age recovery/sops-age.key.age   # 印刷して封筒へ
```

```shell
curl -fsSLO https://raw.githubusercontent.com/danything/gitops/main/recovery/restore.sh
sudo sh restore.sh          # パスフレーズを聞かれる
```

SOPS の鍵を使うとき:

```shell
mkdir -p ~/.config/sops/age
age -d -o ~/.config/sops/age/keys.txt sops-age.key.age
sops -d bootstrap/infisical/secrets.yaml | kubectl apply -f -
```

値を入れ替えたら作り直してコミットする。

```shell
age -p -o recovery/env.age /etc/k3s-backup/env
```

リハーサルの手順と結果は [`../docs/restore-drill.md`](../docs/restore-drill.md)。

## Talos に移ったあと

**`restore.sh` は使えない。** ホストを戻すスクリプトで、Talos には戻す先のホストが無い
(シェルも `/etc/k3s-backup/env` も無い)。代わりに層ごとに戻す。

| 層 | 何で戻すか |
| --- | --- |
| ホストの設定 | **machine config**。`talos/render.sh` が repo から描き直す。戻すものは無い |
| k8s オブジェクト | **git から ArgoCD で再構築**。etcd スナップショットは使わない |
| **PV データ** | **k8up の `Restore`**([../apps/k8up/README.md](../apps/k8up/README.md)「戻し方」) |

順番は [`../docs/migration-day.md`](../docs/migration-day.md) がそのまま使える。あれは
「k3s から移る」手順だが、**3 以降は「まっさらな実機から建てる」手順と同じ**。

**要る道具**(移行後は**ノードにシェルが無い**ので、全部手元から叩く):

| | いつ |
| --- | --- |
| `age` / `sops` | 最初。`sops-age.key.age` を開いて repo の秘密を読めるようにする |
| `talosctl` | `render.sh` → `apply-config` → `bootstrap` → `kubeconfig` |
| **`kubectl`** | **そこから先は全部。** PV の復元は k8up の CR を作る操作なので、これが無いと 1 バイトも戻らない |
| `restic` | 戻すスナップショットの ID を選ぶ |
| `helm` | `render.sh` が中で使う |

**`env.age` は Talos 期も要る。** Infisical がまだ空の段階で `k8up-global` の Secret を
手で作る必要があり、その値の出どころがこれ
([../apps/k8up/k8up-secrets.yaml](../apps/k8up/k8up-secrets.yaml))。
`/etc/k3s-backup/env` は消えるが、**中身(R2 の鍵と restic のパスフレーズ)は変わらない**。
