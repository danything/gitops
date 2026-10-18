# talos

ノード `main`(HP ProLiant DL360 Gen9)の machine config。**v1.14 以降の型付きドキュメントの形で書いてある**
(版は [versions.yaml](versions.yaml)。1.13 以前とは別物。作法は [../docs/talos.md](../docs/talos.md))。
**入れ方(まっさらから建てる手順)は [../recovery/README.md](../recovery/README.md)。** ここは組み立てと当て直し。

**版と schematic の出どころは [versions.yaml](versions.yaml)。** Renovate がそこを見て、
新しい Talos が出たら PR を作る。**適用は自動化しない**(下の「適用は CI にやらせない」)。
コマンドに埋めてある版と schematic も、変えるときは versions.yaml と揃えること。talhelper は使わない。

**組み立ては [render.sh](render.sh) が全部やる。** 手で書く部分(`patches/`)と、
他から描いてくる部分(Cilium・cert-manager・argocd・infisical は `bootstrap/<name>/` の version.yaml と values.yaml から、
local-path-provisioner は `manifests/` から)を 1 か所で組む。**値をどこにも二度書かない**のが目的。
CI([talos-boot](../.github/workflows/talos-boot.yml))も同じ `render.sh` を使う
(別の作り方をすると「CI は通るが実機では通らない」が起きる)。

```shell
./talos/render.sh talos/clusterconfig     # 出力先は丸ごと消して作り直す(.gitignore 済み)
```

**秘密は 2 つともコミット済み** ── [secrets.yaml](secrets.yaml) はクラスタの CA 一式、
[registries.yaml](registries.yaml) は fj.doany.io のイメージ取得の資格情報。
**`secrets.yaml` を作り直すと別のクラスタになる**(`bootstrap/apiserver/ca.crt` と Infisical の Kubernetes auth の CA も
替えることになる)ので触らない。まっさらから組むときだけ:

```shell
talosctl gen secrets -o talos/secrets.yaml && sops -e -i talos/secrets.yaml
```

## fj.doany.io の資格情報

ノード単位で持つので **namespace ごとの `imagePullSecrets` が要らない**(`machine.registries`)。
持つのは **fj.doany.io**(Forgejo のコンテナレジストリ)だけで、Forgejo のユーザー `yui` の
`read:package` だけのトークン(全リポジトリ。Forgejo の名前は `talos-registry-pull`)。
`username` は Forgejo が見ない(トークンの持ち主で決まる。`info` のままにしてあるが、何でも通る)。無いと非公開のリポジトリの
イメージが引けない。ghcr.io に残るイメージは全部公開。SOPS で暗号化してある(**平文は git に入れない**。規則は [`../.sops.yaml`](../.sops.yaml)):

```yaml
# talos/registries.yaml (暗号化前)
machine:
  registries:
    config:
      fj.doany.io:
        auth:
          username: info
          password: …
```

**fj.doany.io はこれだけでは取れない。** 公開 DNS の A(WAN 側)にはノードから届かないので、
ノードの名前解決で fj.doany.io をノード自身(10.0.0.2 の Gateway)に向ける([patches/cluster.yaml](patches/cluster.yaml) の `StaticHostConfig`)。

`render.sh` はこのファイルを復号して `--config-patch` に足す(**無ければ止まる**)。
CI には age の鍵を渡さないので、`REGISTRIES` にダミーを入れて経路だけ通している。

**パッチは PR ごとに CI が検証する。** 使い捨ての秘密で `render.sh` を通す。`render.sh` は `talosctl validate --mode metal` に加えて、
生成物に想定の設定(`ks.doany.io`・OIDC の issuer・bond の `balance-alb` など)が実際に入っているかまで見る
── **`gen config` は知らないキーを警告なく捨てることがある**ので、通ったことだけでは足りない。
needle は `render.sh` の末尾の 1 か所だけに置く。

**適用は CI にやらせない。** machine config の適用は再起動を伴うことがあり、1 ノードでは
マージが即停止になる。Talos API は mTLS のみで OIDC を受けないため、CI に渡すには
`os:admin` のクライアント証明書を置くことになる。**検出は自動、適用は手動**。

## 上げ方 / 当て直し方

**3 つの経路があり、混ぜない。** どれを使うかは「何を変えたか」で決まる。下のコマンドは `tools/t.ps1 --admin` のシェルで打つ
(talosctl / kubectl の資格情報と行き先 10.10.0.4 は t.ps1 が用意する。[../tools/README.md](../tools/README.md)「クラスタの資格情報」)。

| 変えたもの | やること | 停止 |
| --- | --- | --- |
| `versions.yaml` の `talos:`(または schematic) | `talosctl upgrade --image factory.talos.dev/installer/<schematic>:<版>` | **再起動** |
| `versions.yaml` の `kubernetes:` | `render.sh` → `apply-config` → `talosctl upgrade-k8s --to <版>` | 無し |
| `patches/` / `manifests/` / `bootstrap/` のほぼ全部(cilium・cert-manager・apiserver/rbac.yaml・{argocd,infisical}/ の values・SOPS の Secret 2 つ) | `render.sh` → `apply-config` → `talosctl upgrade-k8s` | 場合による |

### inlineManifests を直したとき

**Cilium・local-path・`apiserver/rbac.yaml`・ArgoCD・infisical・
cert-manager と、SOPS 済みの Secret 2 つは machine config の中にいる。**
だから**マニフェストを直しただけでは何も起きない。** 描き直して当てる:

```shell
./talos/render.sh talos/clusterconfig
talosctl apply-config -f talos/clusterconfig/controlplane.yaml
talosctl upgrade-k8s --endpoint https://10.10.0.4:6443    # ← これが inlineManifests を reconcile する
```

`render.sh` は出力先を丸ごと消すので、`talos/clusterconfig/` に置いたものは消える。

- **`apply-config` だけでは inlineManifests は動かない。** 起動時にしか読まれない
- **`upgrade-k8s` は版を上げなくても reconcile する。** SSA とインベントリで**更新も削除も**する
  ([../docs/talos.md](../docs/talos.md)「inlineManifests は「更新できない」ではない」)
- **したがって `upgrade-k8s` の前には必ず `render.sh` → `apply-config`。** 古い machine config のまま流すと**走っている Cilium が巻き戻る**
- **`timeout waiting for: [Job/argocd/argocd-redis-secret-init status: 'NotFound']` で終わったら、もう一度流す。**
  この Job は終わると 60 秒で消える(`ttlSecondsAfterFinished`)ので、待っている間に消えて時間切れになり、
  その後ろの Deployment まで当たらないことがある。
  当て終わったら `kubectl -n argocd get deploy -o wide` でイメージの版を見る
- **何も変えていなければ `apply-config --dry-run` の差分は出ない。** 描くたびに変わる値は潰してある
  (Hubble の証明書はクラスタの中で作る、infisical の `postgres-password` は secret-values.sops.yaml に固定、`updatedAt` は `render.sh` が落とす)。
  差分が出たら、それは本当に変わったもの

### Talos 本体

```shell
talosctl upgrade --image factory.talos.dev/installer/<schematic>:<版>
```

**A/B なので失敗すれば前のイメージに戻る。** ノードが 1 台なので再起動 = 全停止で、だから自動化しない
(tuppr / system-upgrade-controller はどちらも自分が乗っているノードは上げないので 1 台では成立しない)。
**schematic を変えたとき(拡張やカーネル引数)も同じコマンド。** ISO を焼き直す必要はない。

### 当てても効かないもの

- **ディスクの割り方**(`patches/volumes.yaml`)。ボリュームは**まだ確保されていないときにしか
  効かない**ので、あとから `apply-config` しても黙って無視される。変えるには入れ直し
- **`talosctl upgrade-k8s` は Kubernetes の API に直接繋ぎに行く。** 既定ではクラスタの endpoint(10.0.0.2)へ行き、
  作業用 PC からは届かないので `--endpoint https://10.10.0.4:6443` を渡す
