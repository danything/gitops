# talos

実機(HP ProLiant DL360 Gen9)を Talos Linux に載せ替えるための machine config。
**v1.14.0 の形で書いてある**(1.13 以前とは別物。作法は [../docs/talos.md](../docs/talos.md))。

**版と schematic の出どころは [versions.yaml](versions.yaml)。** Renovate がそこを見て、
新しい Talos が出たら PR を作る。**適用は自動化しない**(ノードが 1 台なので、
上げることは全停止を伴う再起動になる)。理由と手順は versions.yaml のコメントに書いてある。
下のコマンドに埋めてある版と schematic も、変えるときは versions.yaml と揃えること。

talhelper は使わない。`talosctl gen config` にこのディレクトリのパッチを渡すだけで足りる。

```shell
# 1) 秘密を作る。生成物は SOPS(age)で暗号化してコミットする
talosctl gen secrets -o secrets.yaml
sops -e -i secrets.yaml            # → talos/secrets.yaml (暗号化済み)

# 2) machine config を作る
sops -d secrets.yaml > /tmp/secrets.plain.yaml
talosctl gen config doany https://10.0.0.2:6443 \
  --with-secrets /tmp/secrets.plain.yaml \
  --install-image factory.talos.dev/installer/32820716ca2384dc3cefbb672e6be929c67636e93e556d7740c312efb6538302:v1.14.0 \
  --config-patch @patches/cluster.yaml \
  --config-patch @patches/main.yaml \
  --output-dir /tmp/talos-config
shred -u /tmp/secrets.plain.yaml

# 3) maintenance mode のノードに流す(ISO で起動した直後)
talosctl apply-config --insecure -n <コンソールに出た IP> -f /tmp/talos-config/controlplane.yaml
# 自動でディスクにインストールして再起動する。ISO を抜いてから:
talosctl -n 10.0.0.2 -e 10.0.0.2 --talosconfig /tmp/talos-config/talosconfig bootstrap
talosctl -n 10.0.0.2 -e 10.0.0.2 --talosconfig /tmp/talos-config/talosconfig kubeconfig
```

`clusterconfig/` と平文の秘密は `.gitignore` 済み。

## 確認できたこと / できていないこと

`patches/` のインタフェース名とディスクだけを VM 用に読み替えて QEMU で実際に起動した
(2026-09-07。手順と証拠は [../docs/talos.md](../docs/talos.md)「VM ブートドリル」)。

確認できた:

- **bond0(balance-alb、miimon 100)が上がる**。片方の carrier を落とすとフェイルオーバーする
- **静的 IPv6 `::2` が SLAAC と並んで載る**。IPv6 の既定経路は RA で来る
  (ただし `net.ipv6.conf.bond0.accept_ra: "2"` が要る。無いと Kubernetes 起動後に消える)
- **wireguard はカーネル組み込み**(`/sys/module/wireguard/version` = 1.0.0)。
  privileged + hostNetwork の Pod で `wg-quick up` が通り、UDP 51820 がホスト netns で LISTEN する。
  Ubuntu で要った AppArmor の回避は不要
- eno4 相当の `disable_ipv6: "1"`、`UnattendedInstallConfig` の CEL diskSelector、
  schematic のカーネル引数(`intel_iommu=on iommu=pt`)、`vfio_pci` / `vfio_iommu_type1` の読み込み

まだ確認できていないこと(VM では原理的に確かめられない):

- 実機の NIC 名(`eno1`/`eno2`/`eno4`)と tg3 ドライバでの bond、実際のスイッチ相手の balance-alb
- ISP のルータからの RA と `240f:6d:842b:1::/64` の実プレフィックス
- ディスクセレクタ `/dev/sda`(VM では `/dev/vda` で試した)
- PT3 を KubeVirt に渡す vfio のパススルー本体(`patches/main.yaml`。モジュールが載ることまで)
