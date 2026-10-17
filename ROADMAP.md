# ROADMAP

ここには**やること と 進捗**だけを置く。**なぜそうしたかは [`docs/decisions.md`](docs/decisions.md)**、
建て直しの手順は [`recovery/README.md`](recovery/README.md)。

## いまここ

**2026-10-17 に DL360 の上で Ubuntu + k3s から Talos(v1.15.0-alpha.1 / Kubernetes v1.37.1)に移した。**
git から建て直して restic から戻し、全部のアプリが動いている。**次は Phase 2.5(Talos のまま HP Z440 へ移す)。**
順番の理由は [docs/decisions.md](docs/decisions.md)「Z440 へは Talos のまま移す」。

**実機の RAM は 2026-10-17 から RDIMM 6 枚中 5 枚(40GB)。** 1 枚は Z440 の BIOS 更新に貸している。

## Phase 2.5 — HP Z440 へ移す(Talos のまま)

**手順は [docs/z440-migration.md](docs/z440-migration.md)。** Talos の machine config は宣言的なので、
箱の違いは schematic と NIC の名前に閉じ込める。bond0 の MAC は設定で固定してあるので、ルーターは触らない。

- [ ] **Intel Arc A310 を買う(常設)。** Xeon E5 に内蔵 GPU は無く、**Z440 は単体の GPU が無いと POST しない。**
      ロープロファイル・補助電源なし・AV1 のハードウェアエンコード可で、denpa の QSV もこれで賄う
      (いまの DL360 の画面は iLO の Matrox G200 だけで、denpa の Pod に `renderD*` が無い)。
      **Arc は UEFI + CSM 無効が要る。**
- [ ] **BIOS を 02.62 に上げてから E5-2696 v4 を載せる。** 上げるまでは仮の CPU と、DL360 から借りた RDIMM 1 枚で起こす。
- [ ] **AMT を設定する(9.x、10.0.0.5)。** 電源と SOL だけで KVM は無い。iLO のように画面は見えない。
- [ ] **Z440 用の schematic。** Intel GPU の extension(**`siderolabs/i915` で足りるか要確認**。新しい世代の Arc B シリーズなどは
      `siderolabs/xe`。**両方は入れない** ── 同じ GPU を取り合う)と、SOL に出すための `console=` のカーネル引数。
      変えたら `talos/versions.yaml` の ID と depName を差し替える。
- [ ] **NIC を MAC で名付ける(`LinkAliasConfig`)。** 箱が替わるとインタフェース名が変わるので、bond のメンバーは名前でなく MAC で指す。
- [ ] Z440 用の machine config を先に描いて置いておき、移す。
- [ ] 移したら: `talosctl ls /dev/dri` に `renderD128`、`talosctl dmesg` に GuC / HuC の読み込みが出ること。
      **denpa 側は何もしなくてよい**(イメージの ffmpeg は QSV / VA-API 入りで、chart は `/dev/dri` をマウント済み)。
      `talosctl get links bond0` の MAC と、外からの IPv6 も見る([recovery/README.md](recovery/README.md) の 9)。
- [ ] docs の「iLO(10.0.0.3)」を AMT(10.0.0.5)に直す(recovery/README.md・talos.md・router.md など)。

## Phase 3 — Talos 定常運用

- [ ] **R2 の容量が下がり切るのを見る。** `host=main` を消した直後の restic の実データは **5.60 GiB**(圧縮前 8.52 GiB、
      480 スナップショット。2026-10-17)。denpa の録画の forget([apps/k8up/denpa-encoded-forget.yaml](apps/k8up/denpa-encoded-forget.yaml))は
      ホストのスナップショットが同じ中身を抱えていたので効いていなかった。日曜の prune のあと、`pulumi` ワークフローの週次の Summary で見る
- [ ] **Talos 1.15.0 の正式版が出たら乗り換える**(Renovate の PR)。PT3 のモジュールの読み順を守る上流の修正
      ([siderolabs/talos#14652](https://github.com/siderolabs/talos/pull/14652))が入ったら、[apps/pt3/rebind.yaml](apps/pt3/rebind.yaml) を外して
      `talos/patches/main.yaml` の並び順だけにする。入ったら dvb-pt3 の extension の README も直す(上流)

## 済んだこと(記録)

1 行ずつ。詳しいことはリンク先にある。

- **Talos へ移した(2026-10-17)。** git から建て直し、PV を restic から戻した。踏んだ穴は直した場所と [recovery/README.md](recovery/README.md) に
- **後片付け(2026-10-17)。** Ubuntu 期のホストのスナップショット(`host=main` 10 本)を forget + prune。etcd の日次スナップショットを
  R2 へ([apps/k8up/etcd-snapshot.yaml](apps/k8up/etcd-snapshot.yaml)、最初の 1 本 `dacc947b` を手で回して確認)
- **四半期ごとの手動の復元リハーサルをやめて自動に(2026-10-17)。** データは月次の CronJob が最新のスナップショットを取り出して開く
  ([apps/k8up/restore-check.yaml](apps/k8up/restore-check.yaml)。SQLite の integrity_check、pg_dump を使い捨ての postgres に流す、tar の中身。
  初回 27 件すべて OK)。ホストの設定は [.github/workflows/talos-boot.yml](.github/workflows/talos-boot.yml) が描いた machine config を QEMU で起動する
- **バックアップを restic + k8up に(2026-09-06〜09-08)。** R2 の `doany-restic` へ日次、論理バックアップと PVC の注釈、失敗通知、`restic check`([apps/k8up/README.md](apps/k8up/README.md))。R2 のずれ検知(2026-10-05)
- **Cilium + Gateway API に(2026-09-06〜07)。** **Talos で後から替えるのが高いのは CNI だけ**なので先に。decisions.md「ルーティングの選定」
- **Talos の検証(2026-09-06〜10-17)。** QEMU で 7 回([docs/talos.md](docs/talos.md)「VM ブートドリル」)
- **運用まわり(2026-09-07〜)。** Cilium の値を git に、Entra をアプリロールに([docs/entra.md](docs/entra.md))、自動マージの範囲(decisions.md「依存の更新をどこまで自動で入れるか」)、Talos の更新は検知だけ自動([talos/versions.yaml](talos/versions.yaml))、通信の可視化は Hubble(`hl.doany.io`)
- **PVC を守る仕掛けをやめた(2026-09-07、`local-path-retain` の撤去は 2026-10-05)** ── decisions.md「PVC を守る仕掛けをやめた」
