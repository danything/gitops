# ROADMAP

ここには**やること と 進捗**だけを置く。**なぜそうしたかは [`docs/decisions.md`](docs/decisions.md)**、
建て直しの手順は [`recovery/README.md`](recovery/README.md)。

## いまここ

**2026-10-31 に HP Z440 へ移し、Talos(OpenEBS LVM)で全部のアプリが動いている。** 残りは下の Phase 2.5 の空いているところ
(AMT・VolSync)。

## Phase 2.5 — HP Z440 へ移す(Talos のまま)

**手順と確かめることは [docs/z440-migration.md](docs/z440-migration.md)。** 箱の違いは schematic と NIC の名前に閉じ込め、
bond0 の MAC は設定で固定してあるのでルーターは触らない。

- [x] Intel Arc A310 を買う(常設。無いと POST しない。denpa の QSV / AV1 も兼ねる)
- [x] BIOS を 02.62、ME を 9.1.45.3000 に上げてから E5-2696 v4 を載せる(02.62 は USB から起動できず、DVD を使った)
- [x] Z440 用の schematic(`siderolabs/i915`)、NIC の別名(`LinkAliasConfig`。#649・#650)
- [x] 移して確かめる(2026-10-31)。途中で直したもの: Pod から PV を 2 つ同時に付ける(`shared: "yes"`。#655)、
      xfs で作れない 128Mi の PVC(#653・denpa#1840)、pgload と復元の落とし穴(#651 ほか)
- [ ] **AMT を設定する**(MEBx は Ctrl+P。手順は [docs/z440-migration.md](docs/z440-migration.md)「3. リモート管理」)。
      AMT は内蔵の I218-LM(`eno1`)でしか動かないので、`eno1` を 10.10 側(HUMAX)に挿し替え、361T の 2 ポートを bond0 に回して
      **10.10.0.3** にする案(作業用 PC から NetBird なしで届く。`LinkAliasConfig` の MAC の入れ替えと `disable_ipv6` の名前を `eno1` に)。
      済んだら SOL の `console=` を schematic に足し、docs の「iLO(10.0.0.3)」を AMT に直す
- [x] **受信の防火壁を Cilium の Host Firewall で作る**(#658。Talos の防火壁は Pod からノードの IP の Gateway を捨てるので使わない。
      経緯は [bootstrap/talos.md](bootstrap/talos.md))。外から 50000・10250・2379 が閉じ、Pod からの fj.doany.io が通るのを確かめた
- [x] Arc の HuC を読む(#659。`siderolabs/mei`)。QSV の ICQ が AV1・H.264 で通るようになった(H.265 の ICQ は DG2 では通らず、VA-API に回る)
- [ ] **ストレージとバックアップを入れ替える**(入れ直しのついでに。理由は [docs/decisions.md](docs/decisions.md)「Z440 で、ストレージを OpenEBS LVM LocalPV に…」)
  - [x] ディスクの切り方: `u-local-path` をやめ、`RawVolumeConfig` + `LVMVolumeGroupConfig` で VG `data` にする。
        thin プールは Talos で作れないので `bootstrap/storage.yaml` の DaemonSet が作る(書いてあるだけ。効くのは Z440 で入れ直したとき)
  - [x] OpenEBS LVM LocalPV と snapshot-controller(CRD 込み)を入れる。StorageClass は名前を `local-path` のまま OpenEBS に。
        talos-boot で PVC・VolumeSnapshot・スナップショットからの PVC・再起動のあとまでを確かめている
  - [x] Z440 で入れ直し、`recovery/pv.sh - restore-all` で戻す([docs/z440-migration.md](docs/z440-migration.md) の 4〜7)
  - [ ] VolSync(restic mover、copyMethod: Snapshot)を入れ、PVC ごとに ReplicationSource。R2 は PVC ごとに別の経路
  - [ ] 戻しは populator(PVC の `dataSourceRef`)。移設のときは `recovery/pv.sh restore-all`(k8up の restic から)で戻し、そのあと VolSync に切り替える
  - [ ] k8up・`backupcommand`・notify・restore-check を VolSync に合わせて畳む。k8up のリポジトリは保持期間(月次 6 か月)が切れるまで残す

## Phase 3 — Talos 定常運用

- [ ] **Talos 1.15.0 の正式版が出たら乗り換える**(Renovate の PR)

## 済んだこと(記録)

- **Talos へ移した(2026-10-17)。** git から建て直し、PV を restic から戻した([recovery/README.md](recovery/README.md))
- **バックアップと復元の確認を自動に。** restic + k8up で日次、etcd も日次、月次の取り出し確認、machine config は PR ごとに QEMU で起動([deploy/k8up/README.md](deploy/k8up/README.md))
- **PT3 の付け直し(pt3-rebind)を外した(2026-10-29)。** 並び順を守る PR([siderolabs/talos#14652](https://github.com/siderolabs/talos/pull/14652))は
  「カーネルが必要な時に読み込む形にすべき」(smira)として閉じられ、その実装 [siderolabs/talos#14724](https://github.com/siderolabs/talos/pull/14724) が
  v1.15.0-alpha.2 に入った。#607 で `kernel.modules` を `earth-pt3` だけにし、alpha.2(Kubernetes 1.37.2)に上げて、
  tc90522・qm1d1c0042・mxl301rf が自動で読まれてチューナー 4 つ(adapter0〜3 と frontend0)が付くのを確かめた
