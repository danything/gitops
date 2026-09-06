# Talos Linux のインストールメディア

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

移行時にラベルが要る namespace(現構成から): `local-path-storage`、`wireguard`(privileged + hostNetwork)、
`denpa`(`/dev/dvb`・`/dev/bus`・`/dev/dri` の hostPath)。

### 動いたこと

- ISO(Image Factory の schematic `2d61dd07…`)から UEFI で起動、maintenance mode の API はポート 50000
- `apply-config` → 自動でディスクへインストール → 再起動 → `bootstrap` → kubeconfig 取得
- **`cluster.inlineManifests` は期待どおり適用された**(仕込んだ Namespace がラベルごと存在した)。
  `bootstrap/` をここに載せる案([decisions.md](decisions.md))は成立する
- flannel でデュアルスタック、CoreDNS / kube-proxy / scheduler すべて Running
