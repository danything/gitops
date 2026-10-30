# talos

ノード `main`(HP ProLiant DL360 Gen9)の machine config。**v1.14 以降の型付きドキュメントの形で書いてある**
(版は [talos.sops.yaml](talos.sops.yaml) の先頭のコメント。1.13 以前とは別物。作法は [../docs/talos.md](../docs/talos.md))。
**入れ方(まっさらから建てる手順)は [../recovery/README.md](../recovery/README.md)。** ここは組み立てと当て直し。

**版と schematic の出どころは [talos.sops.yaml](talos.sops.yaml) の先頭のコメント(`# version:` と `# schematic:`)。** Renovate がそこを見て、
新しい Talos が出たら PR を作る。**適用は自動化しない**(下の「適用は CI にやらせない」)。
コマンドに埋めてある版と schematic も、変えるときはそこと揃えること。talhelper は使わない。

**組み立ては [render.sh](render.sh) が全部やる。** 手で書く部分は [talos.sops.yaml](talos.sops.yaml) の 1 本だけで、
他から描いてくる部分(Cilium・cert-manager・argocd・infisical は `<name>-values(.sops).yaml` から、
local-path-provisioner は [local-path.yaml](local-path.yaml) から)と 1 か所で組む。**値をどこにも二度書かない**のが目的。
CI([talos-boot](../.github/workflows/talos-boot.yml))も同じ `render.sh` を使う
(別の作り方をすると「CI は通るが実機では通らない」が起きる)。

```shell
./bootstrap/render.sh bootstrap/clusterconfig     # 出力先は丸ごと消して作り直す(.gitignore 済み)
```

**描いた machine config(`clusterconfig/controlplane.yaml`)を丸ごとコミットしないのは**、生成物の 9 割が chart を描いたもの(約 300 KB の 1 行文字列)で、
読めず、chart や Kubernetes の版を上げるたびに描き直しのコミットが要るから。
**inlineManifest をファイルで指す仕組みは Talos に無い**(machine config はノードが読むので手元のパスは書けない。
外を指せるのは URL の `KubeExternalManifestConfig` だけで、CRD はそれで渡している)。ファイルを包むのは render.sh の `inline`。

**秘密は 2 か所、どちらも SOPS でコミット済み**(規則は [`../.sops.yaml`](../.sops.yaml)。**平文は git に入れない**)。

- [talos-secrets.sops.yaml](talos-secrets.sops.yaml): クラスタの CA 一式(`talosctl gen secrets` の形)。丸ごと暗号化
- [talos.sops.yaml](talos.sops.yaml): `password` の値(下の fj.doany.io の資格情報)**だけ**をその場で暗号化。
  ほかは平文のまま読めて、`sops` を通さず直接直せる(`mac_only_encrypted`)。パスワードを変えるときだけ `sops edit bootstrap/talos.sops.yaml`。
  SOPS は**ドキュメントごとに `sops:` のメタデータを付け、インデントを 4 にする**(触らない)。render.sh は `sops -d` してから渡す

**`talos-secrets.sops.yaml` を作り直すと別のクラスタになる**(`apiserver-ca.crt` と Infisical の Kubernetes auth の CA も
替えることになる)ので触らない。まっさらから組むときだけ:

```shell
talosctl gen secrets -o bootstrap/talos-secrets.sops.yaml && sops -e -i bootstrap/talos-secrets.sops.yaml
```

## fj.doany.io の資格情報

ノード単位で持つので **namespace ごとの `imagePullSecrets` が要らない**(talos.sops.yaml の `machine.registries`)。
持つのは **fj.doany.io**(Forgejo のコンテナレジストリ)だけで、Forgejo のユーザー `yui` の
`read:package` だけのトークン(全リポジトリ。Forgejo の名前は `talos-registry-pull`)。値は talos.sops.yaml の中で暗号化してある。
`username` は Forgejo が見ない(トークンの持ち主で決まる。`info` のままにしてあるが、何でも通る)。無いと非公開のリポジトリの
イメージが引けない。ghcr.io に残るイメージは全部公開。

**fj.doany.io はこれだけでは取れない。** 公開 DNS の A(WAN 側)にはノードから届かないので、
ノードの名前解決で fj.doany.io をノード自身(10.0.0.2 の Gateway)に向ける(talos.sops.yaml の `StaticHostConfig`)。

CI には age の鍵を渡さないので、talos.sops.yaml の `ENC[…]` を `ci-dummy` に置き換えて経路だけ通している(`<name>-values.sops.yaml` も同じやり方)。

**talos.sops.yaml は PR ごとに CI が検証する。** 使い捨ての秘密で `render.sh` を通す。`render.sh` は `talosctl validate --mode metal` に加えて、
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
| `talos.sops.yaml` の先頭の Talos の `# version:`(または `# schematic:`) | `talosctl upgrade --image factory.talos.dev/installer/<schematic>:<版> --k8s-endpoint https://10.10.0.4:6443` | **再起動** |
| `talos.sops.yaml` の先頭の Kubernetes の `# version:` | `render.sh` → `apply-config` → `talosctl upgrade-k8s --to <版>` | 無し |
| `talos.sops.yaml` の本文と、`bootstrap/` の残りの全部(`*-values.yaml`・`*-values.sops.yaml`(2 つめのドキュメントの Secret も)・`apiserver-rbac.yaml`・`local-path.yaml`) | `render.sh` → `apply-config` → `talosctl upgrade-k8s` | 場合による |

### inlineManifests を直したとき

**Cilium・local-path・`apiserver-rbac.yaml`・ArgoCD・infisical・
cert-manager と、SOPS 済みの Secret 2 つは machine config の中にいる。**
だから**マニフェストを直しただけでは何も起きない。** 描き直して当てる:

```shell
./bootstrap/render.sh bootstrap/clusterconfig
talosctl apply-config --mode=no-reboot -f bootstrap/clusterconfig/controlplane.yaml   # 再起動が要るなら当てずに止まる
talosctl get manifests -o yaml | grep -c '<新しくなるはずの版(例: cilium:v1.20.4)>'      # 反映を待つ(下)
talosctl upgrade-k8s --to <talos.sops.yaml の先頭の kubernetes の版> --endpoint https://10.10.0.4:6443    # ← これが inlineManifests を reconcile する
```

`render.sh` は出力先を丸ごと消すので、`bootstrap/clusterconfig/` に置いたものは消える。

- **`upgrade-k8s` には必ず `--to` を付ける。** 省くと talosctl の既定の版に上がる(Talos の alpha の talosctl なら Kubernetes も alpha)。
  版を変えないなら `talos.sops.yaml` の先頭の今の版を渡す
- **`apply-config` の直後に流さない。** machine config から `manifests` の資源が作り直されるまで少しかかり、その前に流すと**古いマニフェストで
  「変更なし」のまま終わる**(2026-10-23 に Cilium 1.20.4 で踏んだ)。`talosctl get manifests` に新しい版が出てから流す

- **`apply-config` だけでは inlineManifests は動かない。** 起動時にしか読まれない
- **`upgrade-k8s` は版を上げなくても reconcile する。** SSA とインベントリで**更新も削除も**する
  ([../docs/talos.md](../docs/talos.md)「inlineManifests は「更新できない」ではない」)
- **したがって `upgrade-k8s` の前には必ず `render.sh` → `apply-config`。** 古い machine config のまま流すと**走っている Cilium が巻き戻る**
- **`timeout waiting for: [Job/argocd/argocd-redis-secret-init status: 'NotFound']` で終わったら、もう一度流す。** 逆に `argocd-redis-secret-init` が `field is immutable` で落ちたら、前の回の Job が残っている。完了済みなので `kubectl -n argocd delete job argocd-redis-secret-init` してから流し直す。
  cert-manager を上げたときの `cert-manager-startupapicheck` も同じ(`kubectl -n cert-manager delete job cert-manager-startupapicheck`。2026-10-24 に 1.21.3 で踏んだ)。
  この Job は終わると 60 秒で消える(`ttlSecondsAfterFinished`)ので、待っている間に消えて時間切れになり、
  その後ろの Deployment まで当たらないことがある。
  当て終わったら `kubectl -n argocd get deploy -o wide` でイメージの版を見る
- **何も変えていなければ `apply-config --dry-run` の差分は出ない。** 描くたびに変わる値は潰してある
  (Hubble の証明書はクラスタの中で作る、infisical の `postgres-password` は infisical-values.sops.yaml に固定、`updatedAt` は `render.sh` が落とす)。
  差分が出たら、それは本当に変わったもの

### Talos 本体

```shell
talosctl upgrade --image factory.talos.dev/installer/<schematic>:<版> --k8s-endpoint https://10.10.0.4:6443
```

**`--k8s-endpoint` を必ず付ける。** 再起動の前にノードを cordon するが、既定では kubeconfig の endpoint(10.0.0.2)へ行き、
作業用 PC からは届かない。付け忘れると `error cordoning node … i/o timeout` で**再起動せずに止まる**(書き込みは済んでいるので、付けて打ち直せばよい。
2026-10-29 に alpha.2 で踏んだ。このフラグは v1.15.0-alpha.2 の talosctl から)。再起動の待ちは長いので、Claude Code の `!` では裏に回る。

**A/B なので失敗すれば前のイメージに戻る。** ノードが 1 台なので再起動 = 全停止で、だから自動化しない
(tuppr / system-upgrade-controller はどちらも自分が乗っているノードは上げないので 1 台では成立しない)。
**schematic を変えたとき(拡張やカーネル引数)も同じコマンド。** ISO を焼き直す必要はない。

### 当てても効かないもの

- **ディスクの割り方**(talos.sops.yaml の `VolumeConfig` / `UserVolumeConfig`)。ボリュームは**まだ確保されていないときにしか
  効かない**ので、あとから `apply-config` しても黙って無視される。変えるには入れ直し
- **`talosctl upgrade-k8s` は Kubernetes の API に直接繋ぎに行く。** 既定ではクラスタの endpoint(10.0.0.2)へ行き、
  作業用 PC からは届かないので `--endpoint https://10.10.0.4:6443` を渡す
