# ROADMAP

ここには**やること と 進捗**だけを置く。**なぜそうしたかは [`docs/decisions.md`](docs/decisions.md)**、
建て直しの手順は [`recovery/README.md`](recovery/README.md)。

## いまここ

**DL360 の上の Talos で全部のアプリが動いている。次は Phase 2.5(Talos のまま HP Z440 へ移す)。**
順番の理由は [docs/decisions.md](docs/decisions.md)「Z440 へは Talos のまま移す」。

## Phase 2.5 — HP Z440 へ移す(Talos のまま)

**手順と確かめることは [docs/z440-migration.md](docs/z440-migration.md)。** 箱の違いは schematic と NIC の名前に閉じ込め、
bond0 の MAC は設定で固定してあるのでルーターは触らない。

- [ ] Intel Arc A310 を買う(常設。無いと POST しない。denpa の QSV / AV1 も兼ねる)
- [ ] BIOS を 02.62 に上げてから E5-2696 v4 を載せる
- [ ] AMT(10.0.0.5)、Z440 用の schematic(GPU の extension と SOL の `console=`)、NIC の別名(`LinkAliasConfig`)
- [ ] 移して確かめる。docs の「iLO(10.0.0.3)」を AMT に直す
- [ ] **ストレージとバックアップを入れ替える**(入れ直しのついでに。理由は [docs/decisions.md](docs/decisions.md)「Z440 で、ストレージを OpenEBS LVM LocalPV に…」)
  - [x] ディスクの切り方: `u-local-path` をやめ、`RawVolumeConfig` + `LVMVolumeGroupConfig` で VG `data` にする。
        thin プールは Talos で作れないので `bootstrap/storage.yaml` の DaemonSet が作る(書いてあるだけ。効くのは Z440 で入れ直したとき)
  - [x] OpenEBS LVM LocalPV と snapshot-controller(CRD 込み)を入れる。StorageClass は名前を `local-path` のまま OpenEBS に。
        talos-boot で PVC・VolumeSnapshot・スナップショットからの PVC・再起動のあとまでを確かめている
  - [ ] Z440 で入れ直し、`recovery/pv.sh - restore-all` で戻す([docs/z440-migration.md](docs/z440-migration.md) の 4〜7)
  - [ ] VolSync(restic mover、copyMethod: Snapshot)を入れ、PVC ごとに ReplicationSource。R2 は PVC ごとに別の経路
  - [ ] 戻しは populator(PVC の `dataSourceRef`)。移設のときは `recovery/pv.sh restore-all`(k8up の restic から)で戻し、そのあと VolSync に切り替える
  - [ ] k8up・`backupcommand`・notify・restore-check を VolSync に合わせて畳む。k8up のリポジトリは保持期間(月次 6 か月)が切れるまで残す

## Phase 3 — Talos 定常運用

- [ ] **Talos 1.15.0 の正式版が出たら乗り換える**(Renovate の PR)

## 済んだこと(記録)

- **Talos へ移した(2026-10-17)。** git から建て直し、PV を restic から戻した([recovery/README.md](recovery/README.md))
- **バックアップと復元の確認を自動に。** restic + k8up で日次、etcd も日次、月次の取り出し確認、machine config は PR ごとに QEMU で起動([apps/k8up/README.md](apps/k8up/README.md))
- **PT3 の付け直し(pt3-rebind)を外した(2026-10-29)。** 並び順を守る PR([siderolabs/talos#14652](https://github.com/siderolabs/talos/pull/14652))は
  「カーネルが必要な時に読み込む形にすべき」(smira)として閉じられ、その実装 [siderolabs/talos#14724](https://github.com/siderolabs/talos/pull/14724) が
  v1.15.0-alpha.2 に入った。#607 で `kernel.modules` を `earth-pt3` だけにし、alpha.2(Kubernetes 1.37.2)に上げて、
  tc90522・qm1d1c0042・mxl301rf が自動で読まれてチューナー 4 つ(adapter0〜3 と frontend0)が付くのを確かめた
