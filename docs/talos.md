# Talos Linux — メディア作成と machine config

対象: HP ProLiant DL360 Gen9(UEFI、iLO は 10.0.0.3、Xeon E5-2696 v4、RDIMM は 6 枚中 5 枚で 40 GB、NIC は BCM5719 ×4)。
ディスクは **SATA の SSD(Radeon R7、447 GB)を Smart Array(hpsa)越しに**見ている。Linux からは `/dev/sda`(`TRAN=sas` と出るが SAS ではない)。
**Talos への移行はこの DL360 で先にやり、Z440 へ移すのはそのあと**(下の「Z440 に移すときに変わるもの」)。
いま使う版は [talos/versions.yaml](../talos/versions.yaml) が正(2026-10-13 時点で v1.15.0-alpha.1)。下の URL の版もそれに合わせる。

## 1. Image Factory で ISO を作る

Talos は「素の ISO」ではなく、必要な system extension を焼き込んだ ISO を https://factory.talos.dev で作る。
組み合わせは **schematic** という YAML で表し、その内容のハッシュが schematic ID になる(同じ YAML なら誰が作っても同じ ID)。

この箱に要る extension は intel-ucode と dvb-pt3(BCM5719 の tg3、bonding、AHCI は Talos のカーネルに入っている)。
dvb-pt3 は PT3 チューナーのドライバで、**v1.15.0-alpha.1 から**ある([decisions.md](decisions.md)「PT3 チューナー」)。
PT3 のために本番を alpha に乗せている。
**カーネル引数もここに入れる。** v1.14 では `machine.install` が `UnattendedInstallConfig` と衝突して machine config 側に
書けないため、IOMMU の引数は schematic に持たせる。

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

**本番の schematic ID は `96371c8f956f7f5f9d09925bb49fe096c0cad05c5cf5bdb464790982c0b067ca`**(上の YAML。2026-10-13 から)。
それ以前は `32820716…`(intel-ucode + IOMMU の引数、PT3 なし)、ドリルは `2d61dd07…`(intel-ucode のみ)を使っていた。
Web UI(factory.talos.dev → Bare-metal Machine → amd64 → version → extensions)でも同じ ID が出る。

| 用途 | URL |
| --- | --- |
| ISO(通常、Secure Boot オフ) | `https://factory.talos.dev/image/96371c8f956f7f5f9d09925bb49fe096c0cad05c5cf5bdb464790982c0b067ca/v1.15.0-alpha.1/metal-amd64.iso` |
| ISO(Secure Boot 用、Sidero の鍵で署名。UEFI に鍵登録が要るので今回は使わない) | 同じ URL で `metal-amd64-secureboot.iso` |
| `--install-image` と `talosctl upgrade --image` | `factory.talos.dev/installer/96371c8f956f7f5f9d09925bb49fe096c0cad05c5cf5bdb464790982c0b067ca:v1.15.0-alpha.1` |

**プレリリース(alpha / beta)も同じ形の URL で取れる**(版を差し替えるだけ。Web UI では pre-release を表示するチェックを入れる)。
2026-10-13 に本番 schematic の ISO(約 409 MB)と installer が 200 を返すのを確かめた。1.15.0 の正式版が出たら Renovate の PR で乗り換える。

extension を足したくなったら schematic を作り直して ID を差し替え、`talosctl upgrade` で当てる(ISO を焼き直す必要はない)。

## 2. メディアに載せる

**本番は USB でやる**(2026-09-09 の判断。iLO の Virtual Media は USB を作らなくて済むが、挙動が怪しいことがあったため)。
ISO はハイブリッドなのでそのまま書けばよい。書き方・起動のしかた(Secure Boot、F11、USB を抜く時機)・Virtual Media を使う場合は
[migration-day.md](migration-day.md) の 4 にまとめてある。

**コンソールは iLO の Remote Console(HTML5)でよい** ── 実機の前に立たなくてもブートメニューも maintenance mode の IP も見える。USB だけ物理で挿す。

## 3. 起動したあと

ISO から起動すると Talos は **maintenance mode** で立ち上がり、コンソールに IP が出る。まだ何もインストールされていない。
ここから先は手元の PC の `talosctl` で行う(ホストには一切ログインしない)。手順は
[../talos/README.md](../talos/README.md)(`render.sh` → `apply-config` → `bootstrap` → `kubeconfig`)、
当日の順番は [migration-day.md](migration-day.md)。
バックアップからの復元なら `bootstrap` に `--recover-from=etcd.snapshot` を付ける(下の「etcd スナップショットからの復旧」)。

## 4. この箱で先に潰しておくこと

- **PT3 は dvb-pt3 extension(v1.15.0-alpha.1 から)で動く見込み。** extension は `earth_pt3` を blacklist して配るので
  [patches/main.yaml](../talos/patches/main.yaml) で読ませている。denpa の tuner-agent は `/dev/dvb` と `/dev/bus`(B-CAS リーダー)を
  hostDevices で掴む。**実機で `/dev/dvb/adapter*` と B-CAS リーダーが見えるかは当日確かめる**([migration-day.md](migration-day.md) の 9)。
  経緯は [decisions.md](decisions.md)「PT3 チューナー」
- Secure Boot を切る([migration-day.md](migration-day.md) の 4)。
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
| bond とそのメンバー | `BondConfig` / `LinkConfig`。v1alpha1 の `machine.network.interfaces` は bond の MAC を指定できない([patches/cluster.yaml](../talos/patches/cluster.yaml)) |
| PV の置き場 | `UserVolumeConfig`。マウント先(`/var/mnt/<name>`)は kubelet に自動で通るので `extraMounts` は要らない([patches/volumes.yaml](../talos/patches/volumes.yaml))。名前はトップレベルの `name`(1〜34 文字の英数字とハイフン)、ディスク上のラベルは `u-<name>` |
| control-plane への scheduling 許可 | v1alpha1 の `allowSchedulingOnControlPlanes` は弾かれる。**`KubeNodeConfig` を `$patch: delete` して `labels` だけ書き戻す**(`HostnameConfig` も同じ手。理由は [patches/cluster.yaml](../talos/patches/cluster.yaml)) |

### service の IPv6 CIDR は `/108` 以下

`fd43::/64` は `service subnets: invalid subnet: fd43::/64 is too large, it must be at least /108` で弾かれる。
k3s はこれを許していたので、**移行時に `fd43::/108` へ変更が要る**(ClusterIP が振り直しになる)。
pod 側の `fd42::/64` はそのままでよい。検証では `10.43.0.10` と `fd43::a` の両方が付いた。

### PSA のラベル(Pod Security Admission が既定で `baseline`)

`KubeAdmissionControlConfig` に `enforce: baseline`(例外は `kube-system` のみ)が入っている。k3s には無かった制限で、
**`hostPath` / `privileged` / `hostNetwork` を使う workload は namespace にラベルが要る**。

```shell
kubectl label ns <ns> pod-security.kubernetes.io/enforce=privileged
```

実際に local-path-provisioner はこれで詰まった(ヘルパー Pod が `hostPath` を使うため PVC が Pending のまま)。
ラベルを付けたら PVC が Bound になり、Pod から書いた内容がディスクに残ることまで確認した。

**baseline は hostPort も弾く。** ここを見落としやすい。走っている Pod を全部数えて(2026-09-07、09-08 に数え直し)、
ラベルが要る namespace は次のとおり。どれも `namespace.yaml` に `enforce: privileged` が入っていて、実機でも確認した:

| namespace | baseline に通らない理由 |
| --- | --- |
| `kube-system` | Cilium(privileged・hostNetwork・hostPath・SYS_ADMIN/NET_ADMIN・hostPort)。**Talos の側で例外にしてある**(下の設定) |
| `local-path-storage` | ヘルパー Pod の hostPath。[`talos/manifests/local-path.yaml`](../talos/manifests/local-path.yaml) がラベルを付ける |
| `netbird` | hostPort 3478(内蔵 STUN。UDP なのでゲートウェイを通せない)・51822、NET_ADMIN 等、hostPath |
| `denpa` | privileged・hostPath(`/dev/dvb`・`/dev/bus`・`/dev/dri`)。**ラベルは denpa リポジトリの `deploy/namespace.yaml`** にあり、gitops だけを grep すると抜けて見える |
| `adguardhome` | hostPort 53 / 853 |
| `matrix` | hostPort 8443(LiveKit。2026-10-06 に Mattermost Calls から同じ番号を引き継いだ) |
| `3proxy` | hostPort 3129(TLS 終端サイドカー) |
| `cloudflare-ddns` | hostNetwork |
| `forgejo` | Runner の docker(dind)が privileged |

(当時は `erpnext` の `CAP_CHOWN`(**baseline が足せる capability は `NET_BIND_SERVICE` だけ**)と `mattermost` の hostPort 8443 もあった。どちらも 2026-10-06 に撤去)

残りの namespace は baseline のままでよい。**argocd / cert-manager / infisical はラベル無しで上がった**(ドリル 4 回目)。
洗い出しは Pod の spec を直接数えて出す:

```shell
kubectl get pods -A -o json | jq -r '.items[] | . as $p | [$p.metadata.namespace] +
  (if $p.spec.hostNetwork then ["hostNetwork"] else [] end) +
  ($p.spec.containers[] | (.securityContext.privileged // false | if . then ["privileged"] else [] end) +
   ((.securityContext.capabilities.add // []) | map("cap:"+.)) +
   ((.ports // []) | map(select(.hostPort)) | map("hostPort:"+(.hostPort|tostring)))) +
  (($p.spec.volumes // []) | map(select(.hostPath)) | map("hostPath")) | @tsv' | sort -u
```

`kube-system` の例外は Talos の設定:

```yaml
kind: KubeAdmissionControlConfig
name: PodSecurity
configuration:
  defaults: {enforce: baseline, audit: restricted, warn: restricted}
  exemptions:
    namespaces: [kube-system]
```

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
- **PV の中身は戻らない。** `/var/local-path-provisioner`(**当時のパス。いまは `/var/mnt/local-path`**)は空のままだった。
  etcd は「PVC がこの PV に紐づいている」という事実しか持っていない
- したがって Talos 期の復元は **etcd スナップショット → PV データを restic(k8up)から戻す** の 2 段になる。
  順序は etcd が先(PV オブジェクトが無いと戻す先が決まらない)

`bootstrap --recover-from` は etcd サービスが上がるまで `bootstrap is not available yet` を返すので、
数分待って再試行する。

**どちらで戻すか(2026-10-05 に揃えた)。** 主経路は **git から建て直す**ほう
(docs/migration-day.md の 3 以降。ドリルで通してあり、スナップショットの鮮度に左右されない)。
etcd スナップショットは**近道**で、git に無い状態(Application の同期状態、発行済みの証明書、
API サーバが割り当てた nodePort など)まで一度に戻したいときに使う。日次で取っているのは
[../talos/after-migration/etcd-snapshot.yaml](../talos/after-migration/etcd-snapshot.yaml)
(移行後は `apps/k8up/`)で、restic の `--host etcd`。取り出しは:

```shell
restic snapshots --host etcd
restic dump <ID> /work/etcd.snapshot > etcd.snapshot
```

## VM の組み方(QEMU/KVM)

k3s 期の本番サーバ(Ubuntu)の上で回していた。**ホストのネットワークには触らない。** ドリルのつまずきをここにまとめてある。

### tap/bridge は要らない。QEMU の内部ハブで足りる

「bond は user-mode ネットワークでは試せない」というのは誤りだった。`-netdev hubport` で
**QEMU の中だけに L2 セグメントを作れる**ので、ホストに tap も bridge も作らずに 2 本の NIC を
同じセグメントに挿せる。SLIRP(`-netdev user`)は `ipv6=on` で **RA を送ってくる**ので、
RA 由来のデフォルトルートもここで試せる。

```shell
# hub 1 = bond のメンバー 2 本 + SLIRP(IPv6 あり)、hub 2 = eno4 相当の別 LAN
sudo qemu-system-x86_64 -machine q35,accel=kvm -cpu host -smp 4 -m 12288 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=OVMF_VARS.fd \
  -drive file=disk.raw,if=virtio,format=raw -boot order=c \
  -netdev 'user,id=n0,ipv4=on,net=10.0.0.0/24,host=10.0.0.1,dhcpstart=10.0.0.15,ipv6=on,ipv6-net=240f:6d:842b:1::/64,ipv6-host=240f:6d:842b:1::1,hostfwd=tcp:127.0.0.1:50201-10.0.0.15:50000,hostfwd=tcp:127.0.0.1:50211-10.0.0.2:50000,hostfwd=tcp:127.0.0.1:50221-10.0.0.2:6443' \
  -netdev hubport,id=hp0,hubid=1,netdev=n0 \
  -netdev hubport,id=hp1,hubid=1 -device virtio-net-pci,netdev=hp1,mac=52:54:00:ee:00:01 \
  -netdev hubport,id=hp2,hubid=1 -device virtio-net-pci,netdev=hp2,mac=52:54:00:ee:00:02 \
  -netdev 'user,id=n1,ipv4=on,ipv6=off,net=10.10.0.0/24,host=10.10.0.1' \
  -netdev hubport,id=hp3,hubid=2,netdev=n1 \
  -netdev hubport,id=hp4,hubid=2 -device virtio-net-pci,netdev=hp4,mac=52:54:00:ee:00:05 \
  -display none -serial file:serial.log -monitor unix:monitor.sock,server,nowait
```

**KVM を使うので sudo で起動する。** `patches/*.yaml` からの読み替えは
**インタフェース名とディスクだけ**(`eno1`/`eno2`/`eno4` → `enp0s2`/`enp0s3`/`enp0s4`、
`/dev/sda` → `/dev/vda`)。`balance-alb`・`miimon: 100`・静的 IPv6・
**v6 のデフォルトルートを書かないこと**はそのまま。

### つまずいた点

- **ディスクは 140 GB 取る(sparse なので実消費は 4 GB ちょい)。** 小さくすると
  `volumes.yaml` の値を縮めることになり、`maxSize: 64GiB` が効くかを試したことにならない
- **ISO ではなく `metal-amd64.raw.zst` を焼く。** ISO 経由だと「ISO で起動 →
  `apply-config` → 再起動 → **ISO 側がインストール** → 再起動 → ディスク」という段取りに
  なり、外す時機を間違えると PXE ブートに落ちる。raw なら最初から maintenance mode で上がる。
  **実機は USB で ISO**(上の「メディアに載せる」)── ここだけ実機と違う
- **`NETDEV WATCHDOG: transmit queue 0 timed out` は QEMU 側のミス。** bond の 2 本目を
  **何も繋がっていないハブ**に挿していた。QEMU 自身が
  `warning: hub 3 is not connected to host network` と言うので、**`qemu.log` を必ず読む**。
  ハブが正しければ **NIC 3 本でも問題ない**
- **インタフェース名は起動ごとに変わる。** maintenance mode で
  `talosctl get links --insecure` を見てから patch を読み替えること
- **コンソールが要るときは monitor の `screendump`。** `-display none` でも
  `screendump /path/foo.ppm` で画面が撮れる。**kubelet の版ズレはこれで見つけた**
  (シリアルには Talos のダッシュボードが流れてこない)。`socat`/`nc` が無ければ
  python の `socket.AF_UNIX` で `monitor.sock` に直接書けばよい
- **前の VM を殺し忘れると `hostfwd` のポートを握ったままで、新しい VM が黙って死ぬ。**
  `pgrep -af qemu-system-x86_64` で確認する。**`pkill -f` のパターンは
  `qemu-system-[x]86_64` のように書く** ── そうしないと自分の ssh セッションごと殺す(実際に踏んだ)
- `ipv6=on` を付けると **`ipv4=on` を明示しないと** `IPv4 disabled but netmask/host/dns provided` で起動しない
- **v1.14 の `talosctl` は `--nodes` / `--endpoints` がグローバルフラグではない。**
  `talosctl --insecure -n … get links` は `unknown command` になる。
  `talosctl get links --insecure -n … -e …` の順で書く
- maintenance mode は `-e 127.0.0.1:50201 -n 127.0.0.1:50201`。設定投入後は apid 経由なので
  **`-n` はノードの実アドレス**(`-n 10.0.0.2 -e 127.0.0.1:50211`)。
  `-n 127.0.0.1:50211` は `invalid target` になる
- `talosctl apply-config -m reboot` は無い(`auto` / `no-reboot` / `staged` / `try`)
- `talosctl upgrade-k8s` は **k8s の API に直接繋ぎに行く**ので、SLIRP のときは
  `--endpoint https://127.0.0.1:<hostfwd>` を渡す。`kubeconfig` の書き換えだけでは足りない
- ハブの構成は monitor の `info network` で確認できる

### 副作用の遮断: QEMU を専用ユーザーで走らせる

app-of-apps まで同期させると cloudflare-ddns(本番の DNS を書き換える)・netbird(本番に繋ぐ)・
k8up(本番の restic リポジトリに書く)・ACME・SMTP が外に出る。**Talos の VM の中には入れないし、ホスト側で宛先だけで落とすと本番の通信まで
巻き込む**ので、QEMU を専用ユーザーで動かして `-m owner --uid-owner` で落とす(イメージの取得は通るので同期は進む):

```shell
sudo useradd -r -M -s /usr/sbin/nologin -G kvm qemudrill
for ip in <api.cloudflare.com 6 つ> <acme> <本番の公開 IP> <R2 2 つ>; do
  sudo iptables -I OUTPUT 1 -m owner --uid-owner qemudrill -d $ip -j REJECT
done
for p in 587 465 25; do   # SMTP は REJECT。DROP だと Infisical が起動しない
  sudo iptables -I OUTPUT 1 -m owner --uid-owner qemudrill -p tcp --dport $p -j REJECT --reject-with tcp-reset
done
sudo ip6tables -I OUTPUT 1 -m owner --uid-owner qemudrill -d 2000::/3 -j REJECT
```

- **`sudo -u qemudrill` は通らない**(sudoers が root 宛てだけ NOPASSWD)。`sudo runuser -u qemudrill -- <script>` を使う
- **起動は script にする。** `nohup … > log` のリダイレクトは**呼び出し側の権限**で開かれるので、qemudrill が所有するディレクトリには書けない
- `/var/tmp/drill` を qemudrill 所有にすると **`kubeconfig` を書き出せない。** 出力先は別の場所にする

## VM ブートドリル(2026-09-06〜09、6 回)

`talos/patches/` を本番サーバ上の QEMU で実際に起動して確かめた記録。**直したものは直した場所に理由を書いてある**ので、ここは索引。

| 日付 | 確かめたこと | 見つけた穴 → 直した場所 |
| --- | --- | --- |
| 09-06 | v1.14.0 の作法、etcd スナップショットからの復旧 | 型付きドキュメントとの衝突 → 上の「machine config の作法」 |
| 09-07(1 回目) | `patches/` だけで起動。bond0(balance-alb)・静的 IPv6・wireguard | IPv6 の既定経路が消える → [cluster.yaml](../talos/patches/cluster.yaml) の `accept_ra: "2"`。`addr_gen_mode: "2"` が黙って失敗 → 同 `"3"` |
| 09-07(2 回目) | `apiserver.yaml` を足して bootstrap まで。`KubeAuthenticationConfig`・`certExtraSANs`(`DNS:ks.doany.io`)が効く | `versions.yaml` の Kubernetes 版が使われず Talos の既定になる → [versions.yaml](../talos/versions.yaml)・[render.sh](../talos/render.sh) の `--kubernetes-version` と needle |
| 09-08(3 回目) | `render.sh` の出力を丸ごと。Cilium(KPR・vxlan・BPF masq)・nodePort 80・dual-stack の `kube-dns` | kubelet だけ既定の版 → user volume にして `KubeletConfig` を消すのをやめた。control-plane の taint で全部 Pending → [cluster.yaml](../talos/patches/cluster.yaml)。EPHEMERAL がディスク全部 → [volumes.yaml](../talos/patches/volumes.yaml) |
| 09-08(4 回目) | 本物の値で ArgoCD・cert-manager・infisical まで(下) | chart が `metadata.namespace` を書かず `default` に落ちる → [add-namespace.awk](../talos/add-namespace.awk)(直した config を `upgrade-k8s` で当て直すと正しい namespace に作られた) |
| 09-08 | inlineManifests の更新と削除 | 下の「inlineManifests は「更新できない」ではない」 |
| 09-08(5 回目) | app-of-apps まで同期 | `InfisicalSecret` の CRD が無くて `apps/` が丸ごと止まる → `SkipDryRunOnMissingResource`([apps/k8up/README.md](../apps/k8up/README.md))。5 回失敗した Application は自動では戻らない → ArgoCD の `retry`([migration-day.md](migration-day.md) の 7) |
| 09-09(6 回目) | ディスク 140 GB・本番と同じ値で。Entra の issuer と groups の CEL、RBAC、`EPHEMERAL` ちょうど 64.0 GiB、`u-local-path` 72 GiB | 無し |

ほかに残しておくこと:

- **bond のフェイルオーバーは 8 秒以内**(片方の carrier を落とすと `Currently Active Slave` が移り、`talosctl` は途切れない)。
  balance-alb らしくメンバー間で MAC が入れ替わる。**復旧方向は QEMU では確かめられていない**(`set_link … on` でゲストの carrier が戻らない)
- `addr_gen_mode: "3"` は再起動ごとに IID が変わる。cloudflare-ddns(`local.iface.stable:bond0`)が ::2 ではなく SLAAC 側を拾うようなら
  `stable_secret` を足して 2 に戻す(当日の 9 で ::2 が出ていることを見る)
- **wireguard はカーネル組み込み**(`/sys/module/wireguard/version` が 1.0.0)。privileged + hostNetwork の Pod から `wg-quick up` が通る。
  Ubuntu で要った AppArmor の回避は Talos には無い(LSM が SELinux)
- `net.ipv6.conf.eno4.disable_ipv6: "1"` は効く。`bond0` の sysctl は Talos が bond を作ったあとに当たる。`/proc/cmdline` に schematic の引数が載る
- `patches/main.yaml` の `vfio_pci` / `vfio_iommu_type1` が `/proc/modules` に出た(**当時。いまは外した**)
- infisical は SMTP が無くても上がる(`Testing smtp connection` で止まって見えるだけ)。起動直後の
  `CreateContainerConfigError: failed to sync secret cache` は optional な Secret の同期待ちで、放っておくと直る
- 6 回目の所要: `apply-config` → apid 復帰 75 秒 → ノード Ready 200 秒 → bootstrap 層が全部 Running まで 120 秒。
  **headlamp の `secret "headlamp-oidc" not found` は正常**(Infisical の DB が空のため。当日は 7 で先に戻す)

### ブートドリル 4 回目(2026-09-08、本物の値で bootstrap 層まで)

ArgoCD・cert-manager・infisical と SOPS 済みの Secret を入れた machine config を、`apply-config` 1 回で焼いた絵。
**当日の 5 はこれと同じになれば通っている**(ドリルでは ArgoCD の `extraObjects` を空にして app-of-apps だけ外していた)。

```
main   Ready   control-plane   v1.36.2      # 当時の版。いまは versions.yaml の kubernetes:

argocd        argocd-application-controller-0 / applicationset / notifications /
              redis / repo-server / server            すべて Running
cert-manager  cert-manager / cainjector / webhook     Running(startupapicheck は Completed)
infisical     infisical / postgresql-0 / redis-master-0  Running、/api/status が 200
kube-system   cilium / envoy / operator / coredns ×2 / hubble ×2 / metrics-server
local-path-storage  local-path-provisioner
```

### VM では確かめられていないこと

当日の確認に入れてある([migration-day.md](migration-day.md) の 4・9): 実機の NIC 名(`eno1`/`eno2`/`eno4`、tg3)とインストール先ディスク、
本物のスイッチ相手の balance-alb、ISP のルータの RA(MTU・RDNSS・lifetime)、carrier の復旧方向、PT3 と B-CAS リーダー。

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

**`inlineManifests` + `upgrade-k8s` は、machine config だけで回せる本物の経路。**
「初回だけ入れて以後は触れない」ではない。**この実測を根拠に、Talos 期は
`bootstrap/` をまるごと inlineManifests に載せることにした**
([decisions.md](decisions.md)「machine config と Cilium の chart をどう連動させるか」)。

当時の懸念(値が machine config に埋まってレビューできない)は、
**`render.sh` が `bootstrap/` の値から描く**形にして消えている ── 読むのは
`bootstrap/cilium/values.yaml` のままで、machine config はその派生物。

## Z440 に移すときに変わるもの

Talos に移ったあと(Phase 2.5)、同じ Talos のまま HP Z440 に載せ替える。計画は [z440-migration.md](z440-migration.md)。

- **NIC の名前が変わる。** `LinkAliasConfig` で `mac(link.permanent_addr)` を selector にして名前を付け、bond のメンバーはその別名で指す。
  別名は `eno1` のようなシステムの名前に見えるものにしない。**bond0 の MAC は `hardwareAddr` で固定してあるので変わらない**([patches/cluster.yaml](../talos/patches/cluster.yaml))
- **ディスクはオンボードの SATA(AHCI)につながる。** `/dev/sda` のままか `talosctl get disks` で見て [patches/main.yaml](../talos/patches/main.yaml) の `diskSelector` を合わせる
- **iLO が無い。** Intel AMT 9.x(10.0.0.5)で電源と Serial-over-LAN だけ(KVM は無い)。SOL に出すには schematic の
  `extraKernelArgs` に `console=ttyS<n>,115200n8` が要る(v1.14 以降は machine config にカーネル引数を書けない。上の「Image Factory で ISO を作る」)
- **GPU を挿さないと POST しない。** Intel Arc A310 を常設する(AV1 のエンコードにも使う)。schematic に `siderolabs/i915`(**要確認**)を足す。
  Arc は **UEFI で CSM を切る**のが前提

## ネットワークまわりの前提

Talos の既定は Flannel + kube-proxy(1.14.0 で Flannel 0.28.9。1.13 から NetworkPolicy に対応。L3/L4 まで)。
**このクラスタは Cilium に替える**(decisions.md「ルーティングの選定」。CNI の交換は構築時にやる ──
稼働中の差し替えは全 Pod 再起動が前提で、後からだとコストが一桁変わる)。Talos 側の止め方は
[../talos/patches/cni.yaml](../talos/patches/cni.yaml)(**v1alpha1 の `cni.name: none` はもう書けない**)、
Cilium 側の Talos 固有の値は [../talos/cilium-values.yaml](../talos/cilium-values.yaml)。

- **LoadBalancer の実体は無い**(k3s の ServiceLB 相当が無い)。hostPort と Gateway の hostNetwork で済ませた
  (decisions.md「LoadBalancer をどう置き換えるか」)
- **クライアント IP**: 単一ノードなので `externalTrafficPolicy: Cluster` のままで保たれる(decisions.md「クライアント IP」)
- `NetworkDefaultActionConfig: block` を使うなら、`NetworkRuleConfig` で要るポートを明示的に開ける

## 管理モデル(3 つのレイヤーを混同しない)

| レイヤー | 決めること | 変更手段 |
| --- | --- | --- |
| イメージ | カーネル引数、system extension(GPU ドライバ等) | Image Factory で schematic を作って `talosctl upgrade` |
| machine config | CNI、kube-proxy、ディスク、ネットワーク、ファイアウォール | `talosctl apply-config` |
| Kubernetes | ワークロード、Cilium の Gateway API、Cilium 本体 | `kubectl` / Helm / GitOps |

SSH もシェルもパッケージマネージャも無く gRPC API だけなので、**障害時は「直さず作り直す」**。
machine config は必ず git に置く(唯一の真実になる)。デバッグは `talosctl dmesg` / `logs` / `read`、1.13 以降は debug コンテナ。
