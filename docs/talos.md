# Talos Linux — メディア作成と machine config

対象: HP ProLiant DL360 Gen9(UEFI、iLO は 10.0.0.3、Xeon E5-2696 v4、NIC は BCM5719 ×4、ディスクは SAS の SSD 447 GB)。
検証用に Hyper-V でも同じ ISO を使う。2026-09-06 時点の最新は Talos v1.14.0(v1.13.10 も可)。

## 1. Image Factory で ISO を作る

Talos は「素の ISO」ではなく、必要な system extension を焼き込んだ ISO を https://factory.talos.dev で作る。
組み合わせは **schematic** という YAML で表し、その内容のハッシュが schematic ID になる(同じ YAML なら誰が作っても同じ ID)。

この箱に要る extension は intel-ucode だけ(BCM5719 の tg3、bonding、AHCI は Talos のカーネルに入っている)。
**カーネル引数もここに入れる。** v1.14 では `machine.install` が `UnattendedInstallConfig` と衝突して machine config 側に
書けないため、IOMMU の引数は schematic に持たせる。

```yaml
# schematic.yaml (本番用)
customization:
  extraKernelArgs:
    - intel_iommu=on      # PT3 を KubeVirt に渡すため
    - iommu=pt
  systemExtensions:
    officialExtensions:
      - siderolabs/intel-ucode
```

```shell
curl -X POST --data-binary @schematic.yaml https://factory.talos.dev/schematics
# => {"id":"2d61dd07b20062062ea671b4d01873506103b67c0f7a4c3fb6cf4ee85585dcb8"}
```

実際に発行した ID は 2 つある。

| 用途 | schematic ID |
| --- | --- |
| **本番**(intel-ucode + IOMMU の引数) | `32820716ca2384dc3cefbb672e6be929c67636e93e556d7740c312efb6538302` |
| 検証用(intel-ucode のみ) | `2d61dd07b20062062ea671b4d01873506103b67c0f7a4c3fb6cf4ee85585dcb8` |

Web UI(factory.talos.dev → Bare-metal Machine → amd64 → version → extensions)でも同じ ID が出る。

| 用途 | URL |
| --- | --- |
| ISO(通常、Secure Boot オフ) | `https://factory.talos.dev/image/32820716ca2384dc3cefbb672e6be929c67636e93e556d7740c312efb6538302/v1.14.0/metal-amd64.iso` |
| ISO(Secure Boot 用、Sidero の鍵で署名。UEFI に鍵登録が要るので今回は使わない) | 同じ URL で `metal-amd64-secureboot.iso` |
| `--install-image` と `talosctl upgrade --image` | `factory.talos.dev/installer/32820716ca2384dc3cefbb672e6be929c67636e93e556d7740c312efb6538302:v1.14.0` |

ISO は約 400 MB。extension を足したくなったら schematic を作り直して ID を差し替え、`talosctl upgrade` で当てる(ISO を焼き直す必要はない)。

## 2. メディアに載せる

**実機は iLO の Virtual Media が一番楽**(USB を作らなくてよい)。

1. https://10.0.0.3 に入り、Remote Console(HTML5)を開く。
2. Virtual Drives → Image File CD-ROM/DVD → 手元の ISO を選ぶ(URL 指定なら上の factory の URL をそのまま貼ってもよい)。
3. Power → Reset。POST 中に F11(Boot Menu)→ "iLO Virtual USB 3 : iLO Virtual CD-ROM" を選ぶ。
   Secure Boot は RBSU(F9)→ Server Security → Secure Boot Settings で **Disabled** にしておく(通常 ISO は署名されていない)。
   Boot Mode は UEFI のまま。

USB で作る場合は、ISO をそのまま書けばよい(ハイブリッド ISO)。

```shell
# Linux / WSL から(USB が /dev/sdX として見えている前提。WSL では usbipd で持ってくる必要があるので Windows 側の方が早い)
sudo dd if=metal-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Windows なら Rufus で ISO を選び、書き込みモードを聞かれたら **DD イメージモード**を選ぶ。balenaEtcher でもよい。

**Hyper-V(検証用)**: 第 2 世代 VM、Secure Boot **オフ**、メモリ 4 GB 以上、CPU 2 以上、ディスク 40 GB 以上、
DVD ドライブに ISO を接続、ネットワークは外部スイッチ(LAN の DHCP で IP が付く)。第 1 世代でも動くが UEFI にならないので実機と条件が変わる。

## 3. 起動したあと

ISO から起動すると Talos は **maintenance mode** で立ち上がり、コンソールに IP が出る。まだ何もインストールされていない。
ここから先は手元の PC の `talosctl` で行う(ホストには一切ログインしない)。

```shell
# 1) 手元で秘密と設定を作る(secrets.yaml は age で暗号化して repo に置く。ROADMAP 参照)
talosctl gen secrets -o secrets.yaml
talosctl gen config doany https://10.0.0.2:6443 --with-secrets secrets.yaml \
  --install-image factory.talos.dev/installer/2d61dd07b20062062ea671b4d01873506103b67c0f7a4c3fb6cf4ee85585dcb8:v1.14.0 \
  --config-patch @patches/doany.yaml      # bond0 / eno4 / dual-stack / allowSchedulingOnControlPlanes などのパッチ

# 2) maintenance mode のノードに流し込む(この時点でディスクに書かれ、再起動する)
talosctl apply-config --insecure -n <コンソールに出た IP> -f controlplane.yaml

# 3) 再起動後、etcd を初期化(単一ノードなので 1 回だけ)
talosctl -n 10.0.0.2 -e 10.0.0.2 --talosconfig talosconfig bootstrap
talosctl -n 10.0.0.2 -e 10.0.0.2 --talosconfig talosconfig kubeconfig
```

バックアップからの復元なら 3) の `bootstrap` に `--recover-from=etcd.snapshot` を付ける。

## 4. この箱で先に潰しておくこと

- **PT3(Earthsoft、`earth_pt3`)が Talos のカーネルに入っていない。** `siderolabs/pkgs` の `kernel/build/config-amd64` は
  `CONFIG_DVB_PT3 is not set`。`siderolabs/extensions` の dvb 配下にあるのは cx23885 と m88ds3103 だけで、PT3 の extension は無い。
  denpa の tuner-agent は `/dev/dvb` と `/dev/bus`(B-CAS リーダー)を hostDevices で掴むので、今のままだと Talos 上では動かない。
  選択肢は ROADMAP の未決事項を参照。
- Secure Boot を切る(上記)。
- iLO の IP(10.0.0.3)と管理者パスワードを手元に。ISO 起動も再インストールも全部ここからできる。

## machine config の作法(v1.14 で確認)

2026-09-06 に QEMU/KVM で v1.14.0 を実際に起動して確かめたこと。**1.13 以前の書き方は通らない。**

### 設定が複数ドキュメントに分かれた

`talosctl gen config` は v1alpha1 の 1 枚ではなく、`KubeNetworkConfig` / `KubeletConfig` /
`UnattendedInstallConfig` / `ResolverConfig` / `KubeNodeConfig` … という**型付きドキュメントの束**を吐く。
同じ項目を v1alpha1 側にも書くと apply が弾かれる(`... is already set in v1alpha1 config`)。

| やりたいこと | 1.14 での書き場所 |
| --- | --- |
| pod / service の CIDR | `KubeNetworkConfig` の `podSubnets` / `serviceSubnets` |
| インストール先ディスク | `UnattendedInstallConfig` の `provisioning.diskSelector.match`(**CEL 式**。例 `disk.dev_path == "/dev/sda"`) |
| カーネル引数 | `machine.install.extraKernelArgs` は使えない(同じく衝突)。**Image Factory の schematic の `customization.extraKernelArgs`** に入れる |
| host DNS | `ResolverConfig`。**既定で有効**なので普通は書かなくてよい |
| kubelet の `extraMounts` | `KubeletConfig` には無い。**`KubeletConfig` を `$patch: delete` してから** v1alpha1 の `machine.kubelet` に書く |
| control-plane への scheduling 許可 | v1alpha1 の `allowSchedulingOnControlPlanes` は弾かれる。`KubeNodeConfig` の `taints` を消す必要があるが、**strategic merge の空マップ(`taints: {}`)では消えなかった**。talhelper 経由か、起動後に `kubectl taint nodes --all node-role.kubernetes.io/control-plane-` |

### service の IPv6 CIDR は `/108` 以下

`fd43::/64` は `service subnets: invalid subnet: fd43::/64 is too large, it must be at least /108` で弾かれる。
k3s はこれを許していたので、**移行時に `fd43::/108` へ変更が要る**(ClusterIP が振り直しになる)。
pod 側の `fd42::/64` はそのままでよい。検証では `10.43.0.10` と `fd43::a` の両方が付いた。

### Pod Security Admission が既定で `baseline`

`KubeAdmissionControlConfig` に `enforce: baseline`(例外は `kube-system` のみ)が入っている。k3s には無かった制限で、
**`hostPath` / `privileged` / `hostNetwork` を使う workload は namespace にラベルが要る**。

```shell
kubectl label ns <ns> pod-security.kubernetes.io/enforce=privileged
```

実際に local-path-provisioner はこれで詰まった(ヘルパー Pod が `hostPath` を使うため PVC が Pending のまま)。
ラベルを付けたら PVC が Bound になり、Pod から書いた内容がディスク上の
`/var/local-path-provisioner/pvc-…_<ns>_<pvc>` に残ることまで確認した。

**baseline は hostPort も弾く。** ここを見落としやすい。実際に走っている Pod を数えると、
ラベルが要る namespace は次のとおり(2026-09-07 時点。`namespace.yaml` に書き込み済み):

| namespace | baseline に通らない理由 |
| --- | --- |
| `kube-system` | Cilium(privileged・hostNetwork・hostPath・SYS_ADMIN/NET_ADMIN・hostPort 4244/9234/9879/9963/9964)。Talos は既定でラベル済み |
| `local-path-storage` | ヘルパー Pod の hostPath。**Talos で local-path-provisioner を入れるなら必須** |
| `netbird` | hostPort 3478(内蔵 STUN。UDP なのでゲートウェイを通せない) |
| `denpa` | privileged・hostPath(`/dev/dvb`・`/dev/bus`・`/dev/dri`) |
| `adguardhome` | hostPort 53 / 853 |
| `mattermost` | hostPort 8443(calls の WebRTC) |
| `3proxy` | hostPort 8444(TLS 終端サイドカー) |
| `cloudflare-ddns` | hostNetwork |
| `erpnext` | `CAP_CHOWN` の追加(baseline が足せるのは `NET_BIND_SERVICE` だけ) |

残りの namespace は baseline のままでよい。洗い出しは Pod の spec を直接数えて出す:

```shell
kubectl get pods -A -o json | jq -r '.items[] | . as $p | [$p.metadata.namespace] +
  (if $p.spec.hostNetwork then ["hostNetwork"] else [] end) +
  ($p.spec.containers[] | (.securityContext.privileged // false | if . then ["privileged"] else [] end) +
   ((.securityContext.capabilities.add // []) | map("cap:"+.)) +
   ((.ports // []) | map(select(.hostPort)) | map("hostPort:"+(.hostPort|tostring)))) +
  (($p.spec.volumes // []) | map(select(.hostPath)) | map("hostPath")) | @tsv' | sort -u
```

### 動いたこと

- ISO(Image Factory の schematic `2d61dd07…`)から UEFI で起動、maintenance mode の API はポート 50000
- `apply-config` → 自動でディスクへインストール → 再起動 → `bootstrap` → kubeconfig 取得
- **`cluster.inlineManifests` は期待どおり適用された**(仕込んだ Namespace がラベルごと存在した)。
  `bootstrap/` をここに載せる案([decisions.md](decisions.md))は成立する
- flannel でデュアルスタック、CoreDNS / kube-proxy / scheduler すべて Running

## etcd スナップショットからの復旧(検証済み)

Talos 期のバックアップは **etcd(k8s オブジェクト)と PV データで別経路**になる。両方を試した。

```shell
talosctl etcd snapshot ./etcd.snapshot          # 1.8 MB / 394 keys (検証時)
```

復旧は、**同じ `secrets.yaml` で machine config を作り直す**のが肝(PKI が一致しないと復旧できない)。

```shell
# まっさらなディスクに ISO から入れ直したあと
talosctl apply-config --insecure -n <IP> -f controlplane.yaml
# 再起動を待って
talosctl bootstrap --recover-from=./etcd.snapshot
```

2026-09-06 に空のディスクから実際に通した結果:

- Node が**同じ名前・同じ作成時刻**で Ready に戻り、Namespace・Deployment・PVC/PV の紐付け・
  PSA のラベルまでスナップショット時点の状態が復元された
- **PV の中身は戻らない。** `/var/local-path-provisioner` は空のままだった。
  etcd は「PVC がこの PV に紐づいている」という事実しか持っていない
- したがって Talos 期の復元は **etcd スナップショット → PV データを restic(k8up)から戻す** の 2 段になる。
  順序は etcd が先(PV オブジェクトが無いと戻す先が決まらない)

`bootstrap --recover-from` は etcd サービスが上がるまで `bootstrap is not available yet` を返すので、
数分待って再試行する。

## inlineManifests は「更新できない」ではない(2026-09-08、VM で実測)

**`talosctl upgrade-k8s` を通せば更新も削除もされる。** Sidero のドキュメントには

> Talos only creates missing resources from inline manifests — it never deletes or updates them.

とある一方で「更新するには machine config を直して `talosctl upgrade-k8s`」とも書いてあり、
どちらが効くのか読んでも分からなかったので、QEMU で確かめた。**前者は Talos 自身の
起動時の適用の話で、`upgrade-k8s` は別の経路**だった。

プローブ用の `ConfigMap` を `inlineManifests` に載せ、値を `BEFORE` → `AFTER` に書き換えて試した。

| 操作 | 値の更新 | config から消したとき |
| --- | --- | --- |
| `talosctl apply-config` | **されない**(`BEFORE` のまま) | 消えない |
| `talosctl upgrade-k8s --to <いまと同じ版>` | **される**(`AFTER` になる) | **オブジェクトも消える** |

`upgrade-k8s` の出力は差分つきで、SSA とインベントリで**完全な reconcile** をしている。

```
 < configured ConfigMap/default/drill-probe
-  value: BEFORE
+  value: AFTER

 < deleted ConfigMap/default/drill-probe     # config から消したあと
```

フラグにも表れている ── `--manifests-inventory-policy`(既定 `AdoptIfNoInventory`)、
`--manifests-no-prune`、`--manifests-force`。**prune は既定で有効**。

### 何が言えるか

**`inlineManifests` + `upgrade-k8s` は、Cilium を machine config だけで回せる本物の経路。**
「初回だけ入れて以後は触れない」ではない。ただし採るかどうかは別の話で、

- 値が SOPS 済みの machine config の中に入るので、**Renovate が追えずレビューもしにくい**
- `helm template` の出力を丸ごと埋めることになる(数千行)

いまは `bootstrap/cilium/values.yaml` + `helm upgrade` + ズレ検出(cilium-drift.yml)を採っている。
**選択肢として存在することが確かめられた**、というのがこの記録の意味。

### VM の組み方で詰まった点(前回の記録への追記)

- **ISO ではなく `metal-amd64.raw.zst` を焼く。** ISO 経由だと
  「ISO で起動 → `apply-config` → 再起動 → **ISO 側がインストール** → 再起動 → ディスク」
  という段取りになり、ISO を外す時機を間違えると PXE ブートに落ちる(実際に踏んだ)。
  raw を焼けば最初から maintenance mode で上がる
- **NIC は 1 本にする。** bond の検証を兼ねて 3 本挿すと、**maintenance mode では
  全部に DHCP が走る**ので SLIRP 越しの応答が不安定になり、`apply-config` が
  `authentication handshake failed` で落ち続ける。ネットワークの検証と混ぜない
- `talosctl upgrade-k8s` は **k8s の API に直接繋ぎに行く**ので、SLIRP のときは
  `--endpoint https://127.0.0.1:<hostfwd>` を渡す。`kubeconfig` の書き換えだけでは足りない

## Talos ブートドリル 2 回目(2026-09-07、`apiserver.yaml` を足して実際に bootstrap まで)

1 回目はネットワークだけを見た。2 回目は **API サーバの設定(`patches/apiserver.yaml`)を足して
`bootstrap` まで通し、コントロールプレーンが上がるところまで**確かめた。

**確かめられたこと:**

- **`KubeAuthenticationConfig` を入れてもコントロールプレーンは上がる。**
  `configuration` は既定を置き換えるので `anonymous` を書き忘れるとヘルスチェックが
  匿名で通らなくなる ── と書いていたが、**明示して書けば正しく上がる**ことを実地で確認した。
  `kube-apiserver` / `kube-controller-manager` / `kube-scheduler` の 3 つとも `CONTAINER_RUNNING`
- **`certExtraSANs` は効く。** 6443 に繋いで証明書を見ると `DNS:ks.doany.io` が入っている
- ネットワークは 1 回目と同じ(bond0 に `10.0.0.2/24` と静的 IPv6 `::2`、`enp0s4` に `10.10.0.4/24`)

**見つかった問題: `versions.yaml` の Kubernetes 版が使われていなかった。**

```
生成物:        kube-apiserver:v1.37.0     ← Talos v1.14.0 の既定
versions.yaml: kubernetes v1.36.2         ← 宣言しているだけ
```

`talosctl gen config` は `versions.yaml` を読まないので、**`--kubernetes-version` で渡さないと
Talos の既定になる**。移行当日に意図せず 1.36 → 1.37 の飛び級をするところだった。
README の手順と `talos-validate` のワークフローに `--kubernetes-version` を足し、
**生成物に宣言どおりの版が入っているかも CI で見る**ようにした。

**VM 側の読み替え**: NIC は `enp0s2`/`enp0s3`(bond)と `enp0s4`。1 回目の記録は
`enp0s3`/`enp0s4`/`enp0s5` になっているが、**起動ごとに変わりうる**ので毎回 `talosctl get links` で見ること。
KVM を使うので **qemu は sudo で起動する**(前回の記録に抜けていた)。

## VM ブートドリル(2026-09-07、`talos/patches/` をそのまま起動した)

`talosctl validate` が通るだけで一度も起動していなかった `talos/patches/cluster.yaml` /
`main.yaml` を、**本番サーバ上の QEMU で実際に起動して**確かめた。ホストのネットワークには一切触っていない。

### tap/bridge は要らない。QEMU の内部ハブで足りる

「bond は user-mode ネットワークでは試せない」というのは誤りだった。`-netdev hubport` で
**QEMU の中だけに L2 セグメントを作れる**ので、ホストに tap も bridge も作らずに 2 本の NIC を
同じセグメントに挿せる。SLIRP(`-netdev user`)は `ipv6=on` で **RA を送ってくる**ので、
RA 由来のデフォルトルートもここで試せる。

```shell
# hub 1 = bond のメンバー 2 本 + SLIRP(IPv6 あり)、hub 2 = eno4 相当の別 LAN
qemu-system-x86_64 -machine q35,accel=kvm -cpu host -smp 4 -m 8192 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=OVMF_VARS.fd \
  -drive file=disk.qcow2,if=virtio,format=qcow2 \
  -drive file=metal-amd64.iso,media=cdrom,readonly=on -boot order=dc \
  -netdev 'user,id=n0,ipv4=on,net=10.0.0.0/24,host=10.0.0.1,dhcpstart=10.0.0.15,ipv6=on,ipv6-net=240f:6d:842b:1::/64,ipv6-host=240f:6d:842b:1::1,hostfwd=tcp:127.0.0.1:50001-10.0.0.15:50000,hostfwd=tcp:127.0.0.1:50011-10.0.0.2:50000,hostfwd=tcp:127.0.0.1:50021-10.0.0.2:6443' \
  -netdev hubport,id=hp0,hubid=1,netdev=n0 \
  -netdev hubport,id=hp1,hubid=1 -device virtio-net-pci,netdev=hp1,mac=52:54:00:aa:00:01 \
  -netdev hubport,id=hp2,hubid=1 -device virtio-net-pci,netdev=hp2,mac=52:54:00:aa:00:02 \
  -netdev 'user,id=n1,ipv4=on,ipv6=off,net=10.10.0.0/24,host=10.10.0.1' \
  -netdev hubport,id=hp3,hubid=2,netdev=n1 \
  -netdev hubport,id=hp4,hubid=2 -device virtio-net-pci,netdev=hp4,mac=52:54:00:bb:00:04 \
  -display none -serial file:serial.log -monitor unix:monitor.sock,server,nowait
```

つまずいた点:

- `ipv6=on` を付けると **`ipv4=on` を明示しないと** `IPv4 disabled but netmask/host/dns provided` で起動しない。
- ISO は kernel コンソールを `console=tty0` にしか出さないので `-serial` にはブートメニューまでしか流れてこない。
  **診断は全部 `talosctl` 側でやる**(`hostfwd` で 50000 番を借り出す)。
- **v1.14 の `talosctl` は `--nodes` / `--endpoints` がグローバルフラグではない。**
  `talosctl --insecure -n … get links` は `unknown command` になる。`talosctl get links --insecure -n … -e …` の順で書く。
- maintenance mode は `-e 127.0.0.1:50001 -n 127.0.0.1:50001`。設定投入後は apid 経由になるので
  **`-n` はノードの実アドレス**(`-n 10.0.0.2 -e 127.0.0.1:50011`)。`-n 127.0.0.1:50011` は `invalid target` になる。
- `talosctl apply-config -m reboot` は無い(`auto` / `no-reboot` / `staged` / `try`)。
- ハブの構成は monitor の `info network` で確認できる。

`patches/*.yaml` からの読み替えは **インタフェース名とディスクだけ**にした
(`eno1→enp0s3` `eno2→enp0s4` `eno4→enp0s5` `/dev/sda→/dev/vda`)。
`mode: balance-alb`、`miimon: 100`、静的 IPv6 `240f:6d:842b:1::2/64`、
アドレスとゲートウェイ、**v6 のデフォルトルートを書かないこと**はそのまま。

### 1. bond0 は上がる

```shell
talosctl read /proc/net/bonding/bond0 -n 10.0.0.2 -e 127.0.0.1:50011
```

```
Bonding Mode: adaptive load balancing      # = balance-alb
Currently Active Slave: enp0s3
MII Status: up
MII Polling Interval (ms): 100             # = miimon
Slave Interface: enp0s3 / MII Status: up / Link Failure Count: 0
Slave Interface: enp0s4 / MII Status: up / Link Failure Count: 0
```

monitor から片方の carrier を落とす(`set_link virtio-net-pci.0 off`)と **8 秒以内に**
`MII Status: down` / `Link Failure Count: 1` になり、`Currently Active Slave` が enp0s4 に移って
`talosctl` の応答は途切れなかった。balance-alb らしく **メンバー間で MAC が入れ替わる**
(`get links` で enp0s3 が `…aa:00:02`、enp0s4 が `…aa:00:01` になる)のも見えた。
なお QEMU の `set_link … on` ではゲスト側の carrier が戻らないので、**復旧方向は確かめられていない**。

### 2. 静的 IPv6 は載る。だが **`accept_ra: "2"` が無いと既定経路が消える**

静的アドレスと SLAAC は素直に並ぶ。

```
bond0/10.0.0.2/24
bond0/240f:6d:842b:1::2/64                      # patches に書いた静的アドレス
bond0/240f:6d:842b:1:9f48:ba23:fcbb:1cd0/64     # SLAAC
bond0/fe80::8628:e278:4977:732/64
```

問題は既定経路のほうで、**Kubernetes が上がった瞬間に IPv6 の default route が消えた**。

| 時点 | `net.ipv6.conf.bond0.forwarding` | `accept_ra` | `protocol: ra` の default route |
| --- | --- | --- | --- |
| maintenance mode | 0 | 1(既定) | **あり** |
| クラスタ起動後 | 1 | 1(既定) | **無い** |
| クラスタ起動後 | 1 | **2** | **あり** |

`accept_ra=1` は「forwarding が有効なら RA を無視する」という意味で、flannel / kube-proxy が
`net.ipv6.conf.all.forwarding=1` にした時点でカーネルが RA 由来の経路を落とす。
**Ubuntu 期にこれが問題にならなかったのは NetworkManager が userspace で RA を処理していたから**で、
実機は現在 `bond0/accept_ra = 0` のまま `default via fe80::… proto ra metric 300` が載っている。
Talos には RA を代行するものが無いので、カーネルに任せる = `accept_ra: "2"` が必須。

`patches/cluster.yaml` に足した:

```yaml
net.ipv6.conf.bond0.accept_ra: "2"
```

入れたあとの確認(**クラスタが Ready になってから**見ること):

```shell
talosctl get routes -o yaml -n 10.0.0.2 -e … | grep -B10 'protocol: ra'
#     id: bond0/inet6/fe80::2//1024
#     dst: ""
#     gateway: fe80::2
#     outLinkName: bond0
#     protocol: ra
```

### `addr_gen_mode: "2"` は書いても効かない(黙って失敗し続ける)

同時に見つかった。`net.ipv6.conf.bond0.addr_gen_mode: "2"`(stable-privacy)は
**`stable_secret` が未設定だとカーネルが EINVAL を返す**ので、一度も適用されない。
`talosctl get addresses` は EUI-64 のまま(`240f:6d:842b:1:5054:ff:feaa:1`)で、
`KernelParamSpecController` が数秒おきにこれを吐き続ける:

```
ERROR controller failed {"controller": "runtime.KernelParamSpecController",
  "error": "write /proc/sys/net/ipv6/conf/bond0/addr_gen_mode: invalid argument"}
```

**`"3"`(random)に変えたら通った。** 書き込みが成功し、link-local も SLAAC も MAC 由来でなくなる
(`fe80::8628:e278:4977:732` / `240f:6d:842b:1:9f48:ba23:fcbb:1cd0`)。
実機の NetworkManager も同じ見た目(`240f:6d:842b:1:a096:1754:8738:2ede`)なので状態としては揃う。
違いは **3 は再起動ごとに IID が変わる**こと。ブート間で固定したければ `stable_secret` を足して 2 に戻す
(cloudflare-ddns の `local.iface.stable:bond0` が ::2 ではなく SLAAC 側を拾っていた場合はそれが要る)。

### 3. wireguard はカーネル組み込み。AppArmor 相当の回避は要らない

`/proc/modules` にも `/lib/modules/…/kernel/` にも wireguard は出てこない。**`=y` で組み込まれている**からで、

```shell
talosctl read /sys/module/wireguard/version -n 10.0.0.2 -e …   # => 1.0.0
```

実際に privileged + hostNetwork の Pod(namespace に `pod-security.kubernetes.io/enforce=privileged`)から
`wg-quick up wg0` を通した:

```
[#] ip link add dev wg0 type wireguard
[#] wg setconf wg0 /dev/fd/63
[#] ip -4 address add 10.99.99.1/24 dev wg0
[#] ip link set mtu 1420 up dev wg0
interface: wg0 / listening port: 51820
UNCONN 0 0 0.0.0.0:51820 0.0.0.0:*
UNCONN 0 0    [::]:51820    [::]:*
```

ホスト側の `talosctl get links` にも `wg0 … KIND wireguard` が現れる。
**Ubuntu で必要だった AppArmor プロファイルの無効化は Talos には存在しない**(そもそも LSM が SELinux)。

### ついでに確認できたこと

- `UnattendedInstallConfig` の CEL diskSelector で実際にインストールされた(`EPHEMERAL` が `/dev/vda4`)
- schematic のカーネル引数が載る: `/proc/cmdline` に `intel_iommu=on iommu=pt`
- `patches/main.yaml` の `vfio_pci` / `vfio_iommu_type1` が `/proc/modules` に出る
- `net.ipv6.conf.eno4.disable_ipv6: "1"` は効く(相当インタフェースに v6 アドレスが一切付かない)
- `bond0` は Talos が作ったあとに sysctl が適用される(存在しないパスなら ENOENT のはずが EINVAL だった)

### VM では確かめられていないこと

読み替えたぶんと、SLIRP が本物でないぶんは未検証のまま:

- **インタフェース名**は `enp0s3/enp0s4/enp0s5`。実機は `eno1/eno2/eno4`(tg3)。
  名前が違えば `machine.sysctls` のキーも `interfaces` も当たらないので、実機では
  `talosctl get links` で名前を確認してから流すこと
- **ディスクは `/dev/vda`** で試した。実機は `/dev/sda`(`talosctl get disks` で確定させる)
- **相手が SLIRP**なので、balance-alb の ARP ネゴシエーションを本物のスイッチ相手に試したことにはならない。
  ハブなので送ったフレームが相方の NIC にも返ってくるが、それで bond が壊れることは無かった
- **RA も SLIRP のもの**(`fe80::2`、プレフィックス `240f:6d:842b:1::/64` は手で合わせた)。
  ISP のルータの RA(MTU オプション、RDNSS、valid/preferred lifetime)は別物
- carrier の**復旧**方向、PT3 の vfio パススルー本体

## ネットワークまわりの前提(移行前に押さえておくこと)

### 既定は Flannel + kube-proxy のまま

Talos 1.14.0 のイメージにも Flannel 0.28.9 と kube-proxy が入っている。**CNI を替える必然性は無い。**

- kube-proxy は Kubernetes 1.31 以降 **nftables バックエンドが既定**。「iptables で遅い」という話はもう当てはまらない
- **Talos 1.13 から Flannel が NetworkPolicy に対応**(実体は上流の `kube-network-policies`)。machine config で有効にする:

  ```yaml
  cluster:
    network:
      cni:
        name: flannel
        flannel:
          kubeNetworkPoliciesEnabled: true
  ```

  ただし L3/L4 まで。FQDN ベースの egress 制御はできない。

Cilium に替える場合は machine config 側で CNI と kube-proxy を止める(`cni.name: none`、`proxy.disabled: true`)。
Cilium 側は `kubeProxyReplacement: true`、`k8sServiceHost: localhost`、`k8sServicePort: 7445`(KubePrism)、
`cgroup.autoMount.enabled: false` + `hostRoot: /sys/fs/cgroup` が Talos 固有。
**CNI の交換は構築時にやる。** 稼働中クラスタでの差し替えは全 Pod 再起動が前提で、後からやるとコストが一桁変わる。

### LoadBalancer の実体が無い

k3s の ServiceLB(Klipper)に相当するものは Talos に無い。**MetalLB か Cilium の LB-IPAM が要る**。
単一ノードなら、Envoy Gateway を `EnvoyProxy` CRD で hostNetwork にして LB コントローラ自体を省く手もある。

### クライアント IP の保持を先に決める

`externalTrafficPolicy: Cluster` だと SNAT されて送信元 IP が消え、レート制限や IP 制限が壊れる。
`Local` にするか PROXY protocol を使うかを**最初に**決める。後から変えると挙動が変わる。

### Ingress Firewall

`NetworkDefaultActionConfig: block` を使うなら、`NetworkRuleConfig` で必要なポートを明示的に開ける。

## 管理モデル(3 つのレイヤーを混同しない)

| レイヤー | 決めること | 変更手段 |
| --- | --- | --- |
| イメージ | カーネル引数、system extension(GPU ドライバ等) | Image Factory で schematic を作って `talosctl upgrade` |
| machine config | CNI、kube-proxy、ディスク、ネットワーク、ファイアウォール | `talosctl apply-config` |
| Kubernetes | ワークロード、Envoy Gateway、Cilium 本体 | `kubectl` / Helm / GitOps |

SSH もシェルもパッケージマネージャも無く gRPC API だけなので、**障害時は「直さず作り直す」**。
machine config は必ず git に置く(唯一の真実になる)。デバッグは `talosctl dmesg` / `logs` / `read`、1.13 以降は debug コンテナ。
