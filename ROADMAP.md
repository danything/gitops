# ROADMAP

ここには**やること と 進捗**、それと進めるのに要る手順だけを置く。**なぜそうしたかは [`docs/decisions.md`](docs/decisions.md)**、
建て直しの手順は [`recovery/README.md`](recovery/README.md)。

## いまここ

**2026-10-31 に HP Z440 へ移し、Talos(OpenEBS LVM)で全部のアプリが動いている。** 残りは AMT と、バックアップの VolSync への切り替え。

## やること

- [ ] **バックアップを VolSync に切り替える**(理由は [docs/decisions.md](docs/decisions.md)「Z440 で、ストレージを OpenEBS LVM LocalPV に…」)
  - [ ] VolSync(restic mover、copyMethod: Snapshot)を入れ、PVC ごとに ReplicationSource。R2 は PVC ごとに別の経路。k8up と並べて動かして確かめる
  - [ ] 戻しは populator(PVC の `dataSourceRef`)。`recovery/pv.sh` と README の 8 を VolSync に合わせる
  - [ ] k8up・`backupcommand`・notify・restore-check を VolSync に合わせて畳む。k8up のリポジトリは保持期間(月次 6 か月)が切れるまで残す
- [ ] **AMT を設定する**(下の「AMT」)。済んだら SOL の `console=` を schematic に足し、「iLO(10.0.0.3)」と書いてあるところを AMT に直す
  (deploy/netbird/routing-peer.yaml のコメント、docs/decisions.md、recovery/README.md(ISO の起動も AMT の IDE-R に)、docs/talos.md の対象の行、docs/router.md)
- [ ] **Talos 1.15.0 の正式版が出たら乗り換える**(Renovate の PR)
- [ ] (いつか)小さいサーバ(Talos)に 10.0 と 10.10 のあいだのルーターと NetBird の入口を任せる。ノードが止まっていても外から AMT に届くようになる。
  そのとき 10.10 側を外すなら、`bootstrap/talos.sops.yaml` の 10.10 側の `LinkConfig`・別名・`disable_ipv6`、AdGuard の 10.10.0.4 の待ち受け
  (deploy/adguardhome/service-dns.yaml)を消し、10.10 側の機器の DNS を 10.0.0.2 にする(AMT を 10.10 に置いたなら、それも移す)

## ノード main(HP Z440)

| | |
| --- | --- |
| CPU・メモリ | Xeon E5-2696 v4(22 コア)、DDR4 Registered 8GB × 6 = 48GB(Registered 専用・8 スロット。挿す順はサービスガイドの 66 ページ: CPU に近い 7・8 番を空ける) |
| ディスク | SATA の Radeon R7 447GB(`/dev/sda`)。EPHEMERAL 64GiB と、残りを VG `data`(thin プール `data_thinpool` は VG の 90%)。[docs/decisions.md](docs/decisions.md) の「組んだ形」 |
| GPU | **Intel Arc A310 を常設**(Xeon E5 は内蔵 GPU が無く、**Z440 は GPU が無いと POST しない**)。extension は `siderolabs/i915` と、HuC を読む `siderolabs/mei`(`xe` とは両方入れない)。QSV の ICQ は AV1・H.264 で通り、H.265 は VA-API に回る |
| NIC | 内蔵の I218-LM(`eno1`、`48:0f:cf:67:0d:4e`)と HP 361T(`ens3f0` `d4:f5:ef:6d:db:88`・`ens3f1` `d4:f5:ef:6d:db:89`)。名前ではなく元の MAC で `LinkAliasConfig` の別名(`lan0` `lan1` → `bond0`、`jcom0` → 10.10)を付け、DL360 の MAC と `\|\|` で並べてある。`bond0` の MAC は `e6:2c:1b:1a:a0:39` で固定 |
| ほか | PT3(`siderolabs/dvb-pt3`)、B-CAS のカードリーダー(GemPC Twin)。起動は UEFI・CSM 無効・セキュアブート無効、After Power Loss = On |

**ファームで踏んだこと**(2026-10-31。BIOS 02.62、ME 9.1.45.3000)

- 古い BIOS は Arc を初期化できずに止まる(白い LED だけ、ビープ無し)。BIOS を上げるまでは補助電源の要らない古いグラボで作業する
- **02.62 は USB から起動できない**(F9 の一覧が空。Esc の BIOS の更新だけは USB を読む)。ISO や UEFI シェルは **DVD**(El Torito の UEFI イメージ)で起動する
- ME の更新(`FwUpdLcl.efi`、SoftPaq sp90102)は v2 の UEFI シェルだと `Error 8714` になり、**EDK1 の v1 のシェル(`Shell_Full.efi`)から動かすと通る**。
  v2 のシェルで `connect -r` → `map -r` すると USB も見えるので、v1 のシェルを USB に置いて起動する。`-generic` は無い。終わったら電源コードを抜いて入れ直す。
  9.1.37 以前は AMT にパスワード無しで入れる(CVE-2017-5689)
- 入れ直しのあとに直したもの: 存在しない NIC の sysctl は `KernelParamSpecController` を止める、xfs は 300MB 未満を作れない、
  OpenEBS LVM は `shared: "yes"` が無いと 2 つ目の Pod がマウントできない(k8up の Backup が止まる)、Talos の防火壁は Pod からの Gateway を捨てる(Cilium の Host Firewall にした)

## AMT

Z440 は Intel AMT 9.x(ME 9.1)を持つ。iLO の代わりに、OS が止まっていても**電源の操作・シリアルコンソール(SOL)・ISO をつなぐ(IDE-R)**が使える。
**画面(KVM)は使えない**(CPU 内蔵の GPU が前提)。SOL で見えるのは Talos のカーネルのコンソールで、ログインは無い。

**AMT は内蔵の I218-LM(`eno1`)にしか乗らない。** いまの `eno1` は 10.0 側(bond0)なので AMT も 10.0.0.x になる(作業用 PC からは NetBird が要る)。
**`eno1` を 10.10 側(HUMAX)に挿し替え、361T の 2 ポートを bond0 に回せば 10.10.0.3 にでき、作業用 PC から直接届く。**
そのときは `LinkAliasConfig` の Z440 の MAC を入れ替え(`lan0` `lan1` ← 361T、`jcom0` ← `eno1`)、`disable_ipv6` の sysctl の名前を `eno1` にし、
`--mode=try` で当てる。10.10.0.3 が HUMAX の DHCP の範囲や予約と重ならないかを先に見る。

**初期設定**(Z440 の画面で 1 回だけ。Arc にモニタとキーボードをつなぐ)

1. 起動中に **Ctrl+P** で MEBx に入る。最初のパスワードは `admin` で、すぐ変えさせられる(大文字・小文字・数字・記号を含む 8 文字以上)。新しいパスワードは Infisical に置く
2. ネットワーク: IPv4 は固定(10.10.0.3、または 10.0 側なら 10.0.0.5。BL1500HM の DHCP は 10.0.0.10 から)。FQDN(例 `amt-main`)も聞かれる。**IPv6 は無効**
3. リダイレクト: SOL と IDE-R を有効にする
4. **「Activate Network Access」を実行する**(しないとネットワークから入れない)
5. User Consent は「なし」。電源が切れていても AMT を動かす(「ON in S0, ME Wake in S3, S4-5」)

**守り**: パスワード 1 つで電源もコンソールも握れるので**家の外に出さない**(DMZ と IPv6 の公開は 10.0.0.2 と bond0 の MAC だけなので当たらないが、AMT の IPv6 は切る)。
使う口は 16992・16993(管理)と 16994・16995(SOL・IDE-R)。ノード自身からは自分の AMT に届かない。

**つなぎ方**: Windows は Intel の [Device Management Toolkit の Console](https://github.com/device-management-toolkit/console)(`console_windows_x64.exe` を落として実行。常駐させない)。
アルファ版で AMT 9 につながるかは未確認。だめなら [MeshCentral](https://github.com/Ylianst/MeshCentral) を手元で一時的に動かす。Linux は `amtterm`(SOL)と `amttool`(電源)。

**シリアルコンソール(Talos)**: `talosctl dmesg | grep ttyS` で番号を見て(`ttyS4` など)、schematic の `extraKernelArgs` に
`console=tty0` と `console=ttyS<番号>,115200n8` を足し、`bootstrap/talos.sops.yaml` の `# schematic:` を直して `talosctl upgrade`(再起動する)。

## 済んだこと(記録)

- **HP Z440 へ移した(2026-10-31)。** DL360 の SSD を移して Talos を入れ直し、PV を restic から戻した。PV の置き場を OpenEBS LVM LocalPV にし
  (#649〜#656)、ノードの防火壁を Cilium の Host Firewall に(#658。経緯は [bootstrap/talos.md](bootstrap/talos.md))、Arc の HuC を読めるようにした(#659)
- **Talos へ移した(2026-10-17)。** git から建て直し、PV を restic から戻した([recovery/README.md](recovery/README.md))
- **バックアップと復元の確認を自動に。** restic + k8up で日次、etcd も日次、月次の取り出し確認、machine config は PR ごとに QEMU で起動([deploy/k8up/README.md](deploy/k8up/README.md))
- **PT3 の付け直し(pt3-rebind)を外した(2026-10-29)。** 並び順を守る PR([siderolabs/talos#14652](https://github.com/siderolabs/talos/pull/14652))は
  「カーネルが必要な時に読み込む形にすべき」(smira)として閉じられ、その実装 [siderolabs/talos#14724](https://github.com/siderolabs/talos/pull/14724) が
  v1.15.0-alpha.2 に入った。#607 で `kernel.modules` を `earth-pt3` だけにし、alpha.2(Kubernetes 1.37.2)に上げて、
  tc90522・qm1d1c0042・mxl301rf が自動で読まれてチューナー 4 つ(adapter0〜3 と frontend0)が付くのを確かめた
