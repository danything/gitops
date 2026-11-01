# talos

ノード `main`(HP Z440。箱の中身は [../ROADMAP.md](../ROADMAP.md)「ノード main(HP Z440)」)の machine config の組み立てと当て直し。
**入れ方(まっさらから建てる手順)は [../recovery/README.md](../recovery/README.md)。**
SSH もシェルも無く gRPC API だけなので、**障害時は「直さず作り直す」**。調べるのは `talosctl dmesg` / `logs` / `read` / `pcap`、debug コンテナ。

## 3 つの層と、変えたときにやること

**3 つの経路があり、混ぜない。** どれを使うかは「何を変えたか」で決まる。コマンドは `tools/t --admin …`(PowerShell からは `tools/t.ps1 --admin …`)で打つ
(資格情報と行き先は t が用意する。[../tools/README.md](../tools/README.md)「クラスタの資格情報」)。

| 層 | 変えたもの | やること | 停止 |
| --- | --- | --- | --- |
| イメージ | `talos.sops.yaml` の先頭の Talos の `# version:` か `# schematic:`(拡張・カーネル引数) | `talosctl upgrade`(下の「Talos 本体」) | **再起動** |
| machine config | `talos.sops.yaml` の本文と、`bootstrap/` の残りの全部(`*-values(.sops).yaml`・`apiserver-rbac.yaml`・`storage.yaml`) | `bootstrap/apply.sh` → `talosctl upgrade-k8s --to <今の版>`(下の「machine config と inlineManifests」) | 場合による |
| | `talos.sops.yaml` の先頭の Kubernetes の `# version:` | `bootstrap/apply.sh` → `talosctl upgrade-k8s --to <新しい版>` | 無し |
| Kubernetes | ワークロード | Argo CD(`deploy/`・各リポジトリの `deploy/`) | — |

**版と schematic の正は [talos.sops.yaml](talos.sops.yaml) の先頭のコメント。** Renovate がそこを見て PR を作る。**適用は自動化しない**
(1 ノードではマージが即停止になる。Talos API は mTLS だけで OIDC を受けないので、CI に `os:admin` の証明書を置くことになる)。
**検出は自動、適用は手動。** talhelper は使わない。

## 組み立て

**組み立ては [render.sh](render.sh) が全部やる。** 手で書くのは [talos.sops.yaml](talos.sops.yaml) の 1 本だけで、ほかから描いてくる部分
(Cilium・cert-manager・argocd・infisical・lvm-localpv は `<name>-values(.sops).yaml` から、StorageClass と thin プールは [storage.yaml](storage.yaml) から)と
1 か所で組む。**値をどこにも二度書かない**のが目的。CI([talos-boot](../.github/workflows/talos-boot.yml))も同じ `render.sh` を使う。

**描いたものは秘密を平文で含むので、手元に置かない。** [apply.sh](apply.sh) がコンテナの `/dev/shm` に描いて当て、終わったら消す。
引数は `talosctl apply-config` に渡る(`--dry-run` で差分だけ見られる。何も変えていなければ差分は出ない。描くたびに変わる値は潰してある)。
描いたものはコミットしない([../docs/decisions.md](../docs/decisions.md)「machine config と Cilium の chart をどう連動させるか」)。

**Talos の秘密は 2 か所、どちらも SOPS でコミット済み。** [talos-secrets.sops.yaml](talos-secrets.sops.yaml) はクラスタの CA 一式で丸ごと、
[talos.sops.yaml](talos.sops.yaml) は `password` の値(下の fj.doany.io)**だけ**。**`talos-secrets.sops.yaml` を作り直すと別のクラスタになる**
(`apiserver-ca.crt` と Infisical の Kubernetes auth の CA も替わる)ので触らない。まっさらから組むときだけ
`talosctl gen secrets -o bootstrap/talos-secrets.sops.yaml && sops -e -i bootstrap/talos-secrets.sops.yaml`。

**CI は PR ごとに使い捨ての秘密で `render.sh` を通し、QEMU で起動する**(talos-boot。`ENC[…]` は `ci-dummy` に置き換える)。
`render.sh` は `talosctl validate --mode metal` に加えて、生成物に想定の設定が入っているかまで見る
(**`gen config` は知らないキーを警告なく捨てることがある**。needle は `render.sh` の末尾の 1 か所)。
VM で確かめられないのは PT3 と bond の復旧方向。所要は apply → apid 75 秒 → Ready 200 秒 → bootstrap 層 120 秒。

### machine config の書き方(v1.14 以降)

`talosctl gen config` は **型付きドキュメントの束**を吐き、同じ項目を v1alpha1 側にも書くと弾かれる(`... is already set in v1alpha1 config`)。

| やりたいこと | 書き場所 |
| --- | --- |
| pod / service の CIDR | `KubeNetworkConfig`。**service の IPv6 は `/108` 以下** |
| インストール先ディスク | `UnattendedInstallConfig` の `provisioning.diskSelector.match`(CEL 式) |
| カーネル引数 | **schematic の `customization.extraKernelArgs`**(`machine.install.extraKernelArgs` は衝突する) |
| bond とそのメンバー | `BondConfig` / `LinkConfig`。NIC は名前でなく元の MAC で `LinkAliasConfig` の別名を付ける。**別名を別の NIC に付け替えると古い NIC の住所が残る**([../ROADMAP.md](../ROADMAP.md)「AMT」) |
| PV の置き場 | `RawVolumeConfig` を `LVMVolumeGroupConfig` で VG に(thin の LV は Talos では作れない。[README.md](README.md)「PVC の置き場」)。**ボリュームは未割り当ての領域にしか作られず、あとから `apply-config` しても黙って無視される** |
| control-plane への scheduling | `KubeNodeConfig` を `$patch: delete` して `labels` だけ書き戻す |
| CNI を止める | `KubeFlannelCNIConfig` を `$patch: delete`、`KubeProxyConfig` を `enabled: false`(Cilium に替えてある。[../docs/decisions.md](../docs/decisions.md)「ルーティングの選定」) |
| カーネルモジュール | `machine.kernel.modules`。名前の順に読まれる。v1.15.0-alpha.2 からはカーネルの要求でも読むので、書くのは自分からは読まれないものだけ |
| sysctl | **カーネルの名前で書く**(別名は使えない)。**無い名前の行を残さない**(`KernelParamSpecController` が止まり、後の sysctl が当たらない) |

- `talosctl` の `--nodes` / `--endpoints` はグローバルフラグではない(`talosctl get links --insecure -n … -e …` の順)。`apply-config -m reboot` は無い
- 受信の防火壁は Talos(`NetworkDefaultActionConfig`)ではなく **Cilium の Host Firewall**(`cilium-values.yaml` の `hostFirewall` と
  `../deploy/cluster/host-firewall.yaml`)。Talos の防火壁は conntrack の invalid を捨てる規則を必ず入れ、Cilium は Envoy から Pod への帰りを
  NOTRACK にするので、Pod からノードの IP の Gateway(fj.doany.io)への 2 つ目以降のパケットが捨てられた(#646 → #652 → #658)。
  talos-boot が「外から 10250 は通らない」「Pod からノードの IP の Gateway に届く」を見ている

### PSA のラベル

`KubeAdmissionControlConfig` は `enforce: baseline`(例外は `kube-system`)。**`hostPath` / `privileged` / `hostNetwork` / `hostPort` を使う namespace は
`namespace.yaml` に `enforce: privileged` が要る。** 無いと Pod が作られず、ReplicaSet や DaemonSet の events に出るだけ。
今あるのは netbird・denpa(**ラベルは denpa リポジトリの `deploy/namespace.yaml`**)・adguardhome・matrix・3proxy・cloudflare-ddns・forgejo。
新しく足すときは `kubectl get pods -A -o json` で hostNetwork・privileged・capabilities・hostPort・hostPath を数えて洗い出す。

## 当て方

### machine config と inlineManifests

**Cilium・OpenEBS LVM・`apiserver-rbac.yaml`・ArgoCD・infisical・cert-manager と SOPS 済みの Secret 2 つは machine config の中にいる**ので、
直しただけでは何も起きない。`apply-config` は起動時にしか inlineManifests を読まず、**`upgrade-k8s`(同じ版でも)が SSA とインベントリで更新も削除もする**:

```shell
tools/t --admin bootstrap/apply.sh --dry-run          # 差分を見る
tools/t --admin bootstrap/apply.sh --mode=no-reboot   # 再起動が要るなら当てずに止まる
tools/t --admin talosctl get manifests -o yaml | grep -c '<新しくなるはずの版(例: cilium:v1.20.4)>'   # 反映を待つ
tools/t --admin talosctl upgrade-k8s --to <talos.sops.yaml の先頭の kubernetes の版> --endpoint https://10.10.0.4:6443
```

- **`upgrade-k8s` には `--to` と `--endpoint` を付ける。** `--to` を省くと talosctl の既定の版に上がり、`--endpoint` を省くと 10.0.0.2 に行く
- **`apply-config` の直後に流さない。** `talosctl get manifests` に新しい版が出る前に流すと、古いマニフェストで「変更なし」で終わる
- **`upgrade-k8s` の前には必ず `apply.sh`。** 古い machine config のまま流すと、走っている Cilium が巻き戻る
- `argocd-redis-secret-init`(argocd)や `cert-manager-startupapicheck` の Job で時間切れ・`field is immutable` になったら、
  その Job を消して流し直す(終わると 60 秒で消えるので、待っている間に消えて後ろの Deployment まで当たらないことがある)

### ネットワークを変えたとき

**`BondConfig`・`LinkConfig`・`LinkAliasConfig` などを変えたら `--mode=try` で当てる。** 間違えると API ごと届かなくなるが、時間が来れば元に戻る:

```shell
tools/t --admin bootstrap/apply.sh --mode=try --timeout 10m
# 時間内に確かめる(talosctl get links・kubectl get nodes・外からの Web・DoT・NetBird)→ 確定
tools/t --admin bootstrap/apply.sh --mode=no-reboot
```

- 10.10.0.4 に届かなくなったら、Wi-Fi などで 10.0 側につなぐ。t は 10.10.0.4 に届かなければ 10.0.0.2 に繋ぐ
- 確定で `Apply was skipped: no changes detected` と出たら、**ディスクには残らずに元に戻す時計だけが止まっている**(2026-10-31 に踏んだ。
  2026-11-01 の NIC の付け替えでは skip されずに確定した)。そのときは元に戻るのを待ってから当て直すか、動いている設定に害の無い
  ドキュメントを 1 つ足して当て、足す前のものをもう一度当てる

### Talos 本体

```shell
tools/t --admin talosctl upgrade --image factory.talos.dev/installer/<schematic>:<版> --k8s-endpoint https://10.10.0.4:6443
```

- **`--k8s-endpoint` を必ず付ける。** 付け忘れると cordon が 10.0.0.2 に行って `i/o timeout` で**再起動せずに止まる**(書き込みは済んでいるので、付けて打ち直す)
- 再起動の前に drain する。denpa は録画やエンコードが終わるまで止まらない(猶予 6 時間)ので、時間切れになったら Pod を消して進める
- **A/B なので失敗すれば前のイメージに戻る。** ノードが 1 台なので再起動 = 全停止で、だから自動化しない
- 再起動の待ちは長いので、Claude Code の `!` では裏に回る

### schematic(イメージ)

Talos は拡張とカーネル引数を焼き込んだイメージを https://factory.talos.dev で作る。中身(**schematic**)は YAML で、その内容のハッシュが ID になる。
今の中身は [talos.sops.yaml](talos.sops.yaml) の先頭のコメントに書いてある(`https://factory.talos.dev/schematics/<ID>` でも引ける)。変えるときは:

```shell
curl -X POST --data-binary @schematic.yaml https://factory.talos.dev/schematics   # => {"id":"…"}。ID を talos.sops.yaml の `# schematic:` に
```

ISO は `https://factory.talos.dev/image/<schematic>/<版>/metal-amd64.iso`(Secure Boot 用は使わない)、`upgrade` と `--install-image` は
`factory.talos.dev/installer/<schematic>:<版>`。プレリリースも同じ形。schematic を変えても ISO を焼き直す必要はない。

## fj.doany.io の資格情報

ノード単位で持つので **namespace ごとの `imagePullSecrets` が要らない**(`machine.registries`)。持つのは fj.doany.io(Forgejo のレジストリ)だけで、
Forgejo のユーザー `yui` の `read:package` だけのトークン(名前は `talos-registry-pull`。`username` は見られない)。ghcr.io に残るイメージは全部公開。
公開 DNS の A(WAN 側)にはノードから届かないので、ノードの名前解決で fj.doany.io をノード自身に向けている(`StaticHostConfig`)。

## etcd スナップショットから戻す(近道)

主経路は git から建て直すほう([../recovery/README.md](../recovery/README.md))。git に無い状態(Application の同期状態、発行済みの証明書など)まで
一度に戻したいときだけ。日次で [../deploy/backup/etcd-snapshot.yaml](../deploy/backup/etcd-snapshot.yaml) が `<bucket>/etcd` に取っている
(`restic snapshots --host etcd` → `restic dump <ID> /work/etcd.snapshot > etcd.snapshot`)。

```shell
# 同じ talos-secrets.sops.yaml で描いた machine config を ISO のノードに当てたあと(PKI が一致しないと戻せない)
talosctl bootstrap --recover-from=./etcd.snapshot     # etcd が上がるまで `bootstrap is not available yet`。数分待って再試行
```

PV の中身は戻らないので、そのあと VolSync で戻す(etcd が先。PV オブジェクトが無いと戻す先が決まらない)。
