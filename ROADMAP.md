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

## Phase 3 — Talos 定常運用

- [ ] **R2 の容量が下がり切るのを見る。** `host=main` を消した直後の restic の実データは **5.60 GiB**(2026-10-17)。
      日曜の prune のあと、`pulumi` ワークフローの週次の Summary で見る
- [ ] **Talos 1.15.0 の正式版が出たら乗り換える**(Renovate の PR)。PT3 のモジュールの読み順を守る上流の修正
      ([siderolabs/talos#14652](https://github.com/siderolabs/talos/pull/14652))が入ったら、[apps/pt3/rebind.yaml](apps/pt3/rebind.yaml) を外して
      `talos/patches/main.yaml` の並び順だけにする。入ったら dvb-pt3 の extension の README も直す(上流)

## 済んだこと(記録)

- **Talos へ移した(2026-10-17)。** git から建て直し、PV を restic から戻した([recovery/README.md](recovery/README.md))
- **バックアップと復元の確認を自動に。** restic + k8up で日次、etcd も日次、月次の取り出し確認、machine config は PR ごとに QEMU で起動([apps/k8up/README.md](apps/k8up/README.md))
