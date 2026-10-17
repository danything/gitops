# Talos Linux — イメージと machine config の作法

対象: HP ProLiant DL360 Gen9(UEFI、iLO は 10.0.0.3、Xeon E5-2696 v4、RDIMM は 6 枚中 5 枚で 40 GB、NIC は BCM5719 ×4)。
ディスクは **SATA の SSD(Radeon R7、447 GB)を Smart Array(hpsa)越しに**見ている。Linux からは `/dev/sda`(`TRAN=sas` と出るが SAS ではない)。
版は [talos/versions.yaml](../talos/versions.yaml) が正(2026-10-17 時点で v1.15.0-alpha.1 / Kubernetes v1.37.1)。
入れ方は [recovery/README.md](../recovery/README.md)、組み立てと当て直しは [talos/README.md](../talos/README.md)。

## Image Factory の schematic

Talos は必要な system extension を焼き込んだイメージを https://factory.talos.dev で作る。
組み合わせは **schematic** という YAML で表し、その内容のハッシュが schematic ID になる(同じ YAML なら誰が作っても同じ ID)。

この箱に要る extension は intel-ucode と dvb-pt3(BCM5719 の tg3、bonding、AHCI は Talos のカーネルに入っている)。
dvb-pt3 は PT3 チューナーのドライバで、**v1.15.0-alpha.1 から**ある([decisions.md](decisions.md)「PT3 チューナー」)。
PT3 のために本番を alpha に乗せている。
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
| ISO(Secure Boot オフ) | `https://factory.talos.dev/image/96371c8f…/v1.15.0-alpha.1/metal-amd64.iso`(Secure Boot 用の `metal-amd64-secureboot.iso` は UEFI に鍵登録が要るので使わない) |
| `--install-image` と `talosctl upgrade --image` | `factory.talos.dev/installer/96371c8f…:v1.15.0-alpha.1` |

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
| bond とそのメンバー | `BondConfig` / `LinkConfig`。v1alpha1 の `machine.network.interfaces` は bond の MAC を指定できない([patches/cluster.yaml](../talos/patches/cluster.yaml)) |
| PV の置き場 | `UserVolumeConfig`。マウント先(`/var/mnt/<name>`)は kubelet に自動で通るので `extraMounts` は要らない([patches/volumes.yaml](../talos/patches/volumes.yaml))。ディスク上のラベルは `u-<name>` |
| control-plane への scheduling 許可 | v1alpha1 の `allowSchedulingOnControlPlanes` は弾かれる。**`KubeNodeConfig` を `$patch: delete` して `labels` だけ書き戻す**([patches/cluster.yaml](../talos/patches/cluster.yaml)) |
| CNI を止める | `KubeFlannelCNIConfig` を `$patch: delete`、`KubeProxyConfig` を `enabled: false`([patches/cni.yaml](../talos/patches/cni.yaml))。**v1alpha1 の `cni.name: none` はもう書けない** |
| カーネルモジュール | `machine.kernel.modules`。**並べた順ではなく名前の順に読まれる**。Talos 1.14 以降は usermode の modprobe helper が無い(`/proc/sys/kernel/modprobe` が空)ので、`request_module` で依存を引くドライバは順番が狂うと失敗する(PT3 で踏んだ。[patches/main.yaml](../talos/patches/main.yaml)、上流に PR 中) |

### PSA のラベル(Pod Security Admission が既定で `baseline`)

`KubeAdmissionControlConfig` に `enforce: baseline`(例外は `kube-system` のみ)が入っている。
**`hostPath` / `privileged` / `hostNetwork` / `hostPort` を使う workload は namespace にラベルが要る**(baseline は hostPort も弾く)。
ラベルが無いと Pod が作られず、local-path のヘルパー Pod なら PVC が Pending のまま止まる。

| namespace | baseline に通らない理由 |
| --- | --- |
| `kube-system` | Cilium(privileged・hostNetwork・hostPath・SYS_ADMIN/NET_ADMIN・hostPort)。**Talos の側で例外にしてある** |
| `local-path-storage` | ヘルパー Pod の hostPath。[`talos/manifests/local-path.yaml`](../talos/manifests/local-path.yaml) がラベルを付ける |
| `netbird` | hostPort 3478(内蔵 STUN。UDP なのでゲートウェイを通せない)・51822、NET_ADMIN 等、hostPath |
| `denpa` | privileged・hostPath(`/dev/dvb`・`/dev/bus`・`/dev/dri`)、PT3 を付け直す DaemonSet([apps/pt3/](../apps/pt3/))。**ラベルは denpa リポジトリの `deploy/namespace.yaml`** にあり、gitops だけを grep すると抜けて見える |
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

2026-09-06 に空のディスクから通した: Node が同じ名前・同じ作成時刻で Ready に戻り、Namespace・Deployment・PVC/PV の紐付け・
PSA のラベルまで戻った。**PV の中身は戻らない**(etcd は「PVC がこの PV に紐づいている」という事実しか持っていない)ので、
このあと PV データを k8up で戻す。順序は etcd が先(PV オブジェクトが無いと戻す先が決まらない)。

**主経路ではない。** 主経路は git から建て直すほう([recovery/README.md](../recovery/README.md)。スナップショットの鮮度に左右されない)。
こちらは git に無い状態(Application の同期状態、発行済みの証明書、API サーバが割り当てた nodePort など)まで一度に戻したいときの近道。
日次で取っているのは [apps/k8up/etcd-snapshot.yaml](../apps/k8up/etcd-snapshot.yaml)(restic の `--host etcd`)。取り出しは:

```shell
restic snapshots --host etcd
restic dump <ID> /work/etcd.snapshot > etcd.snapshot
```

## inlineManifests は「更新できない」ではない(2026-09-08、VM で実測)

**`talosctl upgrade-k8s` を通せば更新も削除もされる。** Sidero のドキュメントの
「Talos only creates missing resources from inline manifests — it never deletes or updates them.」は
Talos 自身の起動時の適用の話で、`upgrade-k8s` は別の経路だった。プローブ用の `ConfigMap` で確かめた:

| 操作 | 値の更新 | config から消したとき |
| --- | --- | --- |
| `talosctl apply-config` | **されない** | 消えない |
| `talosctl upgrade-k8s --to <いまと同じ版>` | **される** | **オブジェクトも消える** |

出力は差分つき(`< configured ConfigMap/…` と diff)で、SSA とインベントリで完全な reconcile をしている
(`--manifests-inventory-policy`・`--manifests-no-prune`・`--manifests-force`。**prune は既定で有効**)。
**この実測を根拠に、`bootstrap/` をまるごと inlineManifests に載せた**([decisions.md](decisions.md)「machine config と Cilium の chart をどう連動させるか」)。

## VM ブートドリル(2026-09-06〜10-17、7 回)

`talos/patches/` を QEMU で起動して確かめた記録。**直したものは直した場所に理由を書いてある**ので、ここは索引。

| 日付 | 確かめたこと | 見つけた穴 → 直した場所 |
| --- | --- | --- |
| 09-06 | v1.14.0 の作法、etcd スナップショットからの復旧 | 型付きドキュメントとの衝突 → 上の「machine config の作法」 |
| 09-07(1 回目) | `patches/` だけで起動。bond0(balance-alb)・静的 IPv6・wireguard | IPv6 の既定経路が消える → [cluster.yaml](../talos/patches/cluster.yaml) の `accept_ra: "2"`。`addr_gen_mode: "2"` が黙って失敗 → 同 `"3"` |
| 09-07(2 回目) | `apiserver.yaml` を足して bootstrap まで。`KubeAuthenticationConfig`・`certExtraSANs` が効く | `versions.yaml` の Kubernetes 版が使われず Talos の既定になる → [render.sh](../talos/render.sh) の `--kubernetes-version` と needle |
| 09-08(3 回目) | `render.sh` の出力を丸ごと。Cilium(KPR・vxlan・BPF masq)・nodePort 80・dual-stack の `kube-dns` | control-plane の taint で全部 Pending → [cluster.yaml](../talos/patches/cluster.yaml)。EPHEMERAL がディスク全部 → [volumes.yaml](../talos/patches/volumes.yaml) |
| 09-08(4 回目) | 本物の値で ArgoCD・cert-manager・infisical まで | chart が `metadata.namespace` を書かず `default` に落ちる → [add-namespace.awk](../talos/add-namespace.awk) |
| 09-08(5 回目) | app-of-apps まで同期 | `InfisicalSecret` の CRD が無くて `apps/` が丸ごと止まる → `SkipDryRunOnMissingResource`([apps/k8up/README.md](../apps/k8up/README.md))。5 回失敗した Application は自動では戻らない → ArgoCD の `retry` |
| 09-09(6 回目) | ディスク 140 GB・本番と同じ値で。Entra の issuer と groups の CEL、RBAC、`EPHEMERAL` ちょうど 64.0 GiB、`u-local-path` 72 GiB | 無し |
| 10-17(7 回目) | v1.15.0-alpha.1 と型付きの `BondConfig` / `LinkConfig`。`bond0` の MAC が `hardwareAddr` になる。`autoconf=0` で SLAAC が付かず、forwarding=1 になっても RA の既定経路が残る | 無し |

**VM では確かめられず実機で踏んだもの(2026-10-17)**: `render.sh` が GatewayClass を描いていなかった(`helm template` は
クラスタを見ないので `--api-versions` が要る。[render.sh](../talos/render.sh))、PT3 のモジュールの読み順(上の表)。

ほかに残しておくこと:

- **bond のフェイルオーバーは 8 秒以内**(片方の carrier を落とすと `Currently Active Slave` が移り、`talosctl` は途切れない)。
  **復旧方向は QEMU では確かめられていない**
- **wireguard はカーネル組み込み**。privileged + hostNetwork の Pod から `wg-quick up` が通る(LSM は SELinux)
- `net.ipv6.conf.eno4.disable_ipv6: "1"` は効く。`bond0` の sysctl は Talos が bond を作ったあとに当たる
- infisical は SMTP が無くても上がる。起動直後の `CreateContainerConfigError: failed to sync secret cache` は
  optional な Secret の同期待ちで、放っておくと直る
- 所要: `apply-config` → apid 復帰 75 秒 → ノード Ready 200 秒 → bootstrap 層が全部 Running まで 120 秒
- **v1.14 以降の `talosctl` は `--nodes` / `--endpoints` がグローバルフラグではない。** `talosctl get links --insecure -n … -e …` の順で書く。
  `talosctl apply-config -m reboot` は無い(`auto` / `no-reboot` / `staged` / `try`)

## Z440 に移すときに変わるもの

同じ Talos のまま HP Z440 に載せ替える。計画は [z440-migration.md](z440-migration.md)。

- **NIC の名前が変わる。** `LinkAliasConfig` で `mac(link.permanent_addr)` を selector にして名前を付け、bond のメンバーはその別名で指す。
  **bond0 の MAC は `hardwareAddr` で固定してあるので変わらない**
- **ディスクはオンボードの SATA(AHCI)につながる。** `talosctl get disks` で見て [patches/main.yaml](../talos/patches/main.yaml) の `diskSelector` を合わせる
- **iLO が無い。** Intel AMT 9.x(10.0.0.5)で電源と Serial-over-LAN だけ。SOL に出すには schematic の
  `extraKernelArgs` に `console=ttyS<n>,115200n8` が要る
- **GPU を挿さないと POST しない。** Intel Arc A310 を常設する。schematic に `siderolabs/i915`(**要確認**)を足す

## ネットワークまわりの前提

Talos の既定(Flannel + kube-proxy)を止めて **Cilium に替えてある**(decisions.md「ルーティングの選定」。
CNI の交換は構築時にやる ── 稼働中の差し替えは全 Pod 再起動が前提)。Cilium の値は [bootstrap/cilium/values.yaml](../bootstrap/cilium/values.yaml)。

- **LoadBalancer の実体は無い。** hostPort と Gateway の hostNetwork で済ませた(decisions.md「LoadBalancer をどう置き換えるか」)
- **クライアント IP**: 単一ノードなので `externalTrafficPolicy: Cluster` のままで保たれる(decisions.md「クライアント IP」)
- `NetworkDefaultActionConfig: block` を使うなら、`NetworkRuleConfig` で要るポートを明示的に開ける

## 管理モデル(3 つのレイヤーを混同しない)

| レイヤー | 決めること | 変更手段 |
| --- | --- | --- |
| イメージ | カーネル引数、system extension(GPU ドライバ等) | Image Factory で schematic を作って `talosctl upgrade` |
| machine config | CNI、kube-proxy、ディスク、ネットワーク、`bootstrap/` の大半 | `render.sh` → `apply-config`(inlineManifests は `upgrade-k8s` まで) |
| Kubernetes | ワークロード | Argo CD(`apps/` と各リポジトリの `deploy/`) |

SSH もシェルもパッケージマネージャも無く gRPC API だけなので、**障害時は「直さず作り直す」**。
デバッグは `talosctl dmesg` / `logs` / `read`、debug コンテナ。
