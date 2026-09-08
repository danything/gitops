# talos

実機(HP ProLiant DL360 Gen9)を Talos Linux に載せ替えるための machine config。
**v1.14.0 の形で書いてある**(1.13 以前とは別物。作法は [../docs/talos.md](../docs/talos.md))。

**版と schematic の出どころは [versions.yaml](versions.yaml)。** Renovate がそこを見て、
新しい Talos が出たら PR を作る。**適用は自動化しない**(ノードが 1 台なので、
上げることは全停止を伴う再起動になる)。理由と手順は versions.yaml のコメントに書いてある。
下のコマンドに埋めてある版と schematic も、変えるときは versions.yaml と揃えること。

talhelper は使わない。`talosctl gen config` にこのディレクトリのパッチを渡すだけで足りる。

**組み立ては [render.sh](render.sh) が全部やる。** 手で書く部分(`patches/`)と、
他から描いてくる部分(Cilium は `bootstrap/cilium/values.yaml` から、
local-path-provisioner は `manifests/` から)を 1 か所で組む。**値をどこにも二度書かない**
のが目的で、版も `versions.yaml` と `bootstrap/cilium/version.yaml` から読む。

**`talosctl upgrade-k8s` の前にも走らせること。** `upgrade-k8s` は inlineManifests を
reconcile するので、古い machine config のまま流すと**走っている Cilium が巻き戻る**
(../docs/decisions.md「machine config と Cilium の chart をどう連動させるか」)。

CI([talos-validate](../.github/workflows/talos-validate.yml))も同じ `render.sh` を使う。
**別の作り方をすると「CI は通るが当日は通らない」が起きる**ので、道具は 1 つにしてある。

```shell
# 1) 秘密を作る。生成物は SOPS(age)で暗号化してコミットする
talosctl gen secrets -o secrets.yaml
sops -e -i secrets.yaml            # → talos/secrets.yaml (暗号化済み)

# 1b) ghcr.io の資格情報。下の「ghcr.io の資格情報」を先に読むこと
sops -e -i registries.yaml         # → talos/registries.yaml (暗号化済み)

# 2) machine config を作る
./talos/render.sh /tmp/talos-config

# 3) maintenance mode のノードに流す(ISO で起動した直後)
talosctl apply-config --insecure -n <コンソールに出た IP> -f /tmp/talos-config/controlplane.yaml
# 自動でディスクにインストールして再起動する。ISO を抜いてから:
talosctl -n 10.0.0.2 -e 10.0.0.2 --talosconfig /tmp/talos-config/talosconfig bootstrap
talosctl -n 10.0.0.2 -e 10.0.0.2 --talosconfig /tmp/talos-config/talosconfig kubeconfig
```

`clusterconfig/` と平文の秘密は `.gitignore` 済み。

## ghcr.io の資格情報

**k3s 期はホストの `/etc/rancher/k3s/registries.yaml` にあった。** ノード単位で持つので
**namespace ごとの `imagePullSecrets` が要らない**という作りで、Talos でも同じにする
(`machine.registries`)。無いと danything の private なリポジトリから出ているイメージが
`ImagePullBackOff` になる。

値は Infisical の `/worklog/ghcr-pull` と同じ PAT。**平文は git に入れない**ので、
`talos/registries.yaml` を作って SOPS で丸ごと暗号化する([`../.sops.yaml`](../.sops.yaml) に規則がある)。

```yaml
# talos/registries.yaml (暗号化前)
machine:
  registries:
    config:
      ghcr.io:
        auth:
          username: 5ym
          password: ghp_…
```

`render.sh` はこのファイルがあれば復号して `--config-patch` に足し、**無ければ警告して続ける**
(作る前でも他の作業は進められる)。CI には age の鍵を渡さないので、
`REGISTRIES` にダミーを入れて経路だけ通している。

**パッチは PR ごとに CI が検証する**([../.github/workflows/talos-validate.yml](../.github/workflows/talos-validate.yml))。
使い捨ての秘密で `gen config` して `talosctl validate --mode metal` を通し、生成物に
想定の設定(`ks.doany.io`・OIDC の issuer・bond の `balance-alb` など)が実際に入っているかまで見る
── **`gen config` は知らないキーを警告なく捨てることがある**ので、通ったことだけでは足りない。

**適用は CI にやらせない。** machine config の適用は再起動を伴うことがあり、1 ノードでは
マージが即停止になる。Talos API は mTLS のみで OIDC を受けないため、CI に渡すには
`os:admin` のクライアント証明書を置くことになる。**検出は自動、適用は手動**
(`versions.yaml` の Renovate と同じ方針)。

## 上げ方 / 当て直し方

**3 つの経路があり、混ぜない。** どれを使うかは「何を変えたか」で決まる。

| 変えたもの | やること | 停止 |
| --- | --- | --- |
| `versions.yaml` の `talos:`(または schematic) | `talosctl upgrade --image factory.talos.dev/installer/<schematic>:<版>` | **再起動** |
| `versions.yaml` の `kubernetes:` | `render.sh` → `apply-config` → `talosctl upgrade-k8s --to <版>` | 無し |
| `patches/` / `bootstrap/cilium/values.yaml` / `manifests/` / `bootstrap/apiserver/rbac.yaml` | `render.sh` → `apply-config` → `talosctl upgrade-k8s` | 場合による |

### inlineManifests を直したとき

**Cilium・local-path・metrics-server・bootstrap-applier の RBAC は machine config の中にいる。**
だから**マニフェストを直しただけでは何も起きない。** 描き直して当てる:

```shell
./talos/render.sh /tmp/talos-config
talosctl -n 10.0.0.2 apply-config -f /tmp/talos-config/controlplane.yaml
talosctl -n 10.0.0.2 upgrade-k8s          # ← これが inlineManifests を reconcile する
```

- **`apply-config` だけでは inlineManifests は動かない。** 起動時にしか読まれない
- **`upgrade-k8s` は版を上げなくても reconcile する。** 同じ版を指しても走る。SSA と
  インベントリで**更新も削除も**する(2026-09-08 に VM で実測。
  [../docs/talos.md](../docs/talos.md)「inlineManifests は『更新できない』ではない」)
- **したがって `upgrade-k8s` の前には必ず `render.sh` → `apply-config`。**
  古い machine config のまま流すと**走っている Cilium が巻き戻る**

### Talos 本体

```shell
talosctl -n 10.0.0.2 upgrade --image factory.talos.dev/installer/<schematic>:<版>
```

**A/B なので失敗すれば前のイメージに戻る。** ノードが 1 台なので再起動 = 全停止
(なぜ自動化しないかは [versions.yaml](versions.yaml) の冒頭)。

**schematic を変えたとき(拡張やカーネル引数)も同じコマンド。** ISO を焼き直す必要はない。

### 当てても効かないもの

- **ディスクの割り方**(`patches/volumes.yaml`)。ボリュームは**まだ確保されていないときにしか
  効かない**ので、あとから `apply-config` しても黙って無視される。変えるには入れ直し
- **`talosctl upgrade-k8s` は Kubernetes の API に直接繋ぎに行く。** `talosconfig` だけでなく
  kubeconfig 側の到達性も要る(VM で SLIRP 越しに試すときは `--endpoint` を渡す)

## 確認できたこと / できていないこと

`patches/` のインタフェース名とディスクだけを VM 用に読み替えて QEMU で実際に起動した
(2026-09-07。手順と証拠は [../docs/talos.md](../docs/talos.md)「VM ブートドリル」)。

確認できた:

- **bond0(balance-alb、miimon 100)が上がる**。片方の carrier を落とすとフェイルオーバーする
- **静的 IPv6 `::2` が SLAAC と並んで載る**。IPv6 の既定経路は RA で来る
  (ただし `net.ipv6.conf.bond0.accept_ra: "2"` が要る。無いと Kubernetes 起動後に消える)
- **wireguard はカーネル組み込み**(`/sys/module/wireguard/version` = 1.0.0)。
  **wg-easy は廃したが、NetBird も同じカーネルの wireguard を使うのでこの確認は生きている。**
  privileged + hostNetwork の Pod で `wg-quick up` が通り、UDP 51820 がホスト netns で LISTEN する。
  Ubuntu で要った AppArmor の回避は不要
- eno4 相当の `disable_ipv6: "1"`、`UnattendedInstallConfig` の CEL diskSelector、
  schematic のカーネル引数(`intel_iommu=on iommu=pt`)、`vfio_pci` / `vfio_iommu_type1` の読み込み

まだ確認できていないこと(VM では原理的に確かめられない):

- 実機の NIC 名(`eno1`/`eno2`/`eno4`)と tg3 ドライバでの bond、実際のスイッチ相手の balance-alb
- ISP のルータからの RA と `240f:6d:842b:1::/64` の実プレフィックス
- ディスクセレクタ `/dev/sda`(VM では `/dev/vda` で試した)
- PT3 を KubeVirt に渡す vfio のパススルー本体(`patches/main.yaml`。モジュールが載ることまで)
