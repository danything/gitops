# Talos Linux — イメージと machine config の作法

対象: HP ProLiant DL360 Gen9(UEFI、iLO は 10.0.0.3、Xeon E5-2696 v4、RDIMM は 6 枚中 5 枚で 40 GB、NIC は BCM5719 ×4)。
ディスクは **SATA の SSD(Radeon R7、447 GB)を Smart Array(hpsa)越しに**見ている。Linux からは `/dev/sda`(`TRAN=sas` と出るが SAS ではない)。
版は [bootstrap/versions.yaml](../bootstrap/versions.yaml) が正。
入れ方は [recovery/README.md](../recovery/README.md)、組み立てと当て直しは [bootstrap/talos.md](../bootstrap/talos.md)。

## Image Factory の schematic

Talos は必要な system extension を焼き込んだイメージを https://factory.talos.dev で作る。
組み合わせは **schematic** という YAML で表し、その内容のハッシュが schematic ID になる(同じ YAML なら誰が作っても同じ ID)。

この箱に要る extension は intel-ucode と dvb-pt3(BCM5719 の tg3、bonding、AHCI は Talos のカーネルに入っている)。
dvb-pt3 は PT3 チューナーのドライバ([decisions.md](decisions.md)「PT3 チューナー」)。
**カーネル引数もここに入れる。** v1.14 以降は `machine.install` が `UnattendedInstallConfig` と衝突して machine config 側に
書けないため。

```yaml
# schematic.yaml (本番用)
customization:
  extraKernelArgs:
    - intel_iommu=on      # 元は PT3 を KubeVirt に渡すため。dvb-pt3 が入ったいまは要らないが、パススルーの道として残す
    - iommu=pt
  systemExtensions:
    officialExtensions:
      - siderolabs/dvb-pt3
      - siderolabs/intel-ucode
```

```shell
curl -X POST --data-binary @schematic.yaml https://factory.talos.dev/schematics
# => {"id":"96371c8f956f7f5f9d09925bb49fe096c0cad05c5cf5bdb464790982c0b067ca"}
```

| 用途 | URL |
| --- | --- |
| ISO(Secure Boot オフ) | `https://factory.talos.dev/image/96371c8f…/v1.15.0-alpha.2/metal-amd64.iso`(Secure Boot 用の `metal-amd64-secureboot.iso` は UEFI に鍵登録が要るので使わない) |
| `--install-image` と `talosctl upgrade --image` | `factory.talos.dev/installer/96371c8f…:v1.15.0-alpha.2` |

プレリリース(alpha / beta)も同じ形の URL で取れる。extension を足したくなったら schematic を作り直して ID を差し替え、
`talosctl upgrade` で当てる(ISO を焼き直す必要はない)。

## machine config の作法(v1.14 で確認)

**1.13 以前の書き方は通らない。** `talosctl gen config` は v1alpha1 の 1 枚ではなく**型付きドキュメントの束**を吐き、
同じ項目を v1alpha1 側にも書くと apply が弾かれる(`... is already set in v1alpha1 config`)。

| やりたいこと | 書き場所 |
| --- | --- |
| pod / service の CIDR | `KubeNetworkConfig` の `podSubnets` / `serviceSubnets`。**service の IPv6 は `/108` 以下**(`fd43::/64` は `too large` で弾かれる) |
| インストール先ディスク | `UnattendedInstallConfig` の `provisioning.diskSelector.match`(**CEL 式**。例 `disk.dev_path == "/dev/sda"`) |
| カーネル引数 | `machine.install.extraKernelArgs` は使えない(同じく衝突)。**schematic の `customization.extraKernelArgs`** |
| host DNS | `ResolverConfig`。**既定で有効**なので普通は書かなくてよい |
| bond とそのメンバー | `BondConfig` / `LinkConfig`。v1alpha1 の `machine.network.interfaces` は bond の MAC を指定できない([talos.sops.yaml](../bootstrap/talos.sops.yaml)) |
| PV の置き場 | `UserVolumeConfig`。マウント先(`/var/mnt/<name>`)は kubelet に自動で通るので `extraMounts` は要らない([talos.sops.yaml](../bootstrap/talos.sops.yaml))。ディスク上のラベルは `u-<name>` |
| control-plane への scheduling 許可 | v1alpha1 の `allowSchedulingOnControlPlanes` は弾かれる。**`KubeNodeConfig` を `$patch: delete` して `labels` だけ書き戻す**([talos.sops.yaml](../bootstrap/talos.sops.yaml)) |
| CNI を止める | `KubeFlannelCNIConfig` を `$patch: delete`、`KubeProxyConfig` を `enabled: false`([talos.sops.yaml](../bootstrap/talos.sops.yaml))。**v1alpha1 の `cni.name: none` はもう書けない** |
| カーネルモジュール | `machine.kernel.modules`。**並べた順ではなく名前の順に読まれる**。Talos 1.14 以降は usermode の modprobe helper が無い(`/proc/sys/kernel/modprobe` が空)ので、`request_module` で依存を引くドライバは順番が狂うと失敗する(PT3 で踏んだ。[talos.sops.yaml](../bootstrap/talos.sops.yaml)。上流は並び順ではなく、カーネルが必要な時に読み込む形で直す方針。ROADMAP) |

### PSA のラベル(Pod Security Admission が既定で `baseline`)

`KubeAdmissionControlConfig` に `enforce: baseline`(例外は `kube-system` のみ)が入っている。
**`hostPath` / `privileged` / `hostNetwork` / `hostPort` を使う workload は namespace にラベルが要る**(baseline は hostPort も弾く)。
ラベルが無いと Pod が作られず、local-path のヘルパー Pod なら PVC が Pending のまま止まる。

| namespace | baseline に通らない理由 |
| --- | --- |
| `kube-system` | Cilium(privileged・hostNetwork・hostPath・SYS_ADMIN/NET_ADMIN・hostPort)。**Talos の側で例外にしてある** |
| `local-path-storage` | ヘルパー Pod の hostPath。[`bootstrap/local-path.yaml`](../bootstrap/local-path.yaml) がラベルを付ける |
| `netbird` | hostPort 51820(routing peer の WireGuard)、NET_ADMIN 等、hostPath |
| `denpa` | privileged・hostPath(`/dev/dvb`・`/dev/bus`・`/dev/dri`)。**ラベルは denpa リポジトリの `deploy/namespace.yaml`** にあり、gitops だけを grep すると抜けて見える |
| `adguardhome` | hostPort 53 / 853 |
| `matrix` | hostPort 8443(LiveKit) |
| `3proxy` | hostPort 3129(TLS 終端サイドカー) |
| `cloudflare-ddns` | hostNetwork |
| `forgejo` | Runner の docker(dind)が privileged |

どれも `namespace.yaml` に `enforce: privileged` が入っている。**baseline が足せる capability は `NET_BIND_SERVICE` だけ。**
新しく足すときは Pod の spec を直接数えて洗い出す:

```shell
kubectl get pods -A -o json | jq -r '.items[] | . as $p | [$p.metadata.namespace] +
  (if $p.spec.hostNetwork then ["hostNetwork"] else [] end) +
  ($p.spec.containers[] | (.securityContext.privileged // false | if . then ["privileged"] else [] end) +
   ((.securityContext.capabilities.add // []) | map("cap:"+.)) +
   ((.ports // []) | map(select(.hostPort)) | map("hostPort:"+(.hostPort|tostring)))) +
  (($p.spec.volumes // []) | map(select(.hostPath)) | map("hostPath")) | @tsv' | sort -u
```

## etcd スナップショットからの復旧(VM で検証済み)

```shell
talosctl etcd snapshot ./etcd.snapshot          # 1.8 MB / 394 keys (検証時)
```

復旧は、**同じ `secrets.yaml` で machine config を作り直す**のが肝(PKI が一致しないと復旧できない)。

```shell
# まっさらなディスクに ISO から入れ直したあと
talosctl apply-config --insecure -n <IP> -f controlplane.yaml
talosctl bootstrap --recover-from=./etcd.snapshot     # etcd が上がるまで `bootstrap is not available yet`。数分待って再試行
```

**PV の中身は戻らない**(etcd は「PVC がこの PV に紐づいている」という事実しか持っていない)ので、
このあと PV データを k8up で戻す。順序は etcd が先(PV オブジェクトが無いと戻す先が決まらない)。

**主経路ではない。** 主経路は git から建て直すほう([recovery/README.md](../recovery/README.md)。スナップショットの鮮度に左右されない)。
こちらは git に無い状態(Application の同期状態、発行済みの証明書など)まで一度に戻したいときの近道。
日次で取っているのは [apps/k8up/etcd-snapshot.yaml](../apps/k8up/etcd-snapshot.yaml)(restic の `--host etcd`)。取り出しは:

```shell
restic snapshots --host etcd
restic dump <ID> /work/etcd.snapshot > etcd.snapshot
```

## inlineManifests は「更新できない」ではない(VM で実測)

Sidero のドキュメントの「Talos only creates missing resources from inline manifests」は起動時の適用の話で、
**`talosctl apply-config` では更新も削除もされないが、`talosctl upgrade-k8s`(同じ版でも)を通せば SSA とインベントリで更新も削除もされる**
(prune は既定で有効)。当て直しの手順は [bootstrap/talos.md](../bootstrap/talos.md)「上げ方 / 当て直し方」。

## VM ブートドリル

[.github/workflows/talos-boot.yml](../.github/workflows/talos-boot.yml) が PR ごとに描いた machine config を QEMU で起動して見る。
見つけた穴は直した場所(`bootstrap/talos.sops.yaml`・`bootstrap/render.sh`)に理由を書いてある。

VM では確かめられないもの: PT3 のモジュールの読み順、bond のフェイルオーバーの復旧方向(落とす方向は 8 秒以内で `talosctl` は途切れない)。

- **v1.14 以降の `talosctl` は `--nodes` / `--endpoints` がグローバルフラグではない。** `talosctl get links --insecure -n … -e …` の順で書く。
  `talosctl apply-config -m reboot` は無い(`auto` / `no-reboot` / `staged` / `try`)
- infisical の起動直後の `CreateContainerConfigError: failed to sync secret cache` は optional な Secret の同期待ちで、放っておくと直る
- 所要: `apply-config` → apid 復帰 75 秒 → ノード Ready 200 秒 → bootstrap 層が全部 Running まで 120 秒

Z440 に移すときに変わるもの(NIC の名前・ディスク・AMT・GPU)は [z440-migration.md](z440-migration.md)。

## ネットワークまわりの前提

Talos の既定(Flannel + kube-proxy)を止めて **Cilium に替えてある**(decisions.md「ルーティングの選定」。
CNI の交換は構築時にやる ── 稼働中の差し替えは全 Pod 再起動が前提)。Cilium の値は [bootstrap/cilium-values.yaml](../bootstrap/cilium-values.yaml)。
LoadBalancer とクライアント IP も decisions.md「ルーティングの選定」。

- `NetworkDefaultActionConfig: block` を使うなら、`NetworkRuleConfig` で要るポートを明示的に開ける

## 管理モデル(3 つのレイヤーを混同しない)

| レイヤー | 決めること | 変更手段 |
| --- | --- | --- |
| イメージ | カーネル引数、system extension(GPU ドライバ等) | Image Factory で schematic を作って `talosctl upgrade` |
| machine config | CNI、kube-proxy、ディスク、ネットワーク、`bootstrap/` の chart と SOPS のファイル | `render.sh` → `apply-config`(inlineManifests は `upgrade-k8s` まで) |
| Kubernetes | ワークロード | Argo CD(`apps/`・`bootstrap/` の残りの平文・各リポジトリの `deploy/`) |

SSH もシェルもパッケージマネージャも無く gRPC API だけなので、**障害時は「直さず作り直す」**。
デバッグは `talosctl dmesg` / `logs` / `read`、debug コンテナ。
