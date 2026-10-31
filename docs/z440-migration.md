# Talos に移したノード main を Z440 に移す(入れ直して restic から戻す)

DL360 Gen9 で動いている `main` を HP Z440 に移す計画(ROADMAP の Phase 2.5)。
**SSD は持っていくが、中身は持っていかない。** Z440 で Talos を入れ直し(SSD は上書きされる)、PV のデータは k8up の restic から戻す
([../recovery/README.md](../recovery/README.md) の建て直しと同じ道)。入れ直すのは、ディスクの切り方をこのときしか変えられないから
(PV の置き場を local-path から OpenEBS LVM LocalPV にする。「2. NIC と bond0」の下の「ディスク」)。
あとで小さいサーバ(Talos)に 10.0 と 10.10 のあいだのルーターを任せ、Z440 は 10.0 側だけにする予定(「終わったら」)。

## 構成と、Z440 での扱い

| | DL360 Gen9(今) | Z440 |
| --- | --- | --- |
| CPU | Xeon E5-2696 v4(22 コア、LGA2011-3、150W) | 載せ替える。Z440 は E5-2600 v3 / v4 に対応(C612)。v4 のマイクロコードは BIOS 2.58 から入るので、**先に BIOS を 02.62 に上げる**(手順 1) |
| メモリ | DDR4 Registered 8GB。**2026-10-17 から 5 枚(40GB)**。1 枚は BIOS を上げるために Z440 へ移した | **6 枚 × 8GB = 48GB** にする。Z440 は Registered 専用、8 スロット、上限 128GB |
| SSD | SATA の Radeon R7 447GB 1 本。Smart Array 経由(素通し)なので Linux からは `TRAN=sas`・`/dev/sda` に見える | 内蔵の SATA(AHCI)に直結。`ahci` は Talos のカーネルに入っている([talos.md](talos.md)) |
| 起動 | UEFI、セキュアブート無効 | **UEFI、CSM 無効**(Arc の条件)、セキュアブート無効 |
| GPU | 無し(画面は iLO の Matrox G200) | **Intel Arc A310 を常設。** Xeon E5 は内蔵 GPU が無く、**Z440 は GPU が無いと POST しない**(画面なしで起動する BIOS の設定は見つからない。兄弟機には隠しの「Headless Mode」があるらしいが Z440 では未確認)。denpa の AV1 のハードウェアエンコードにも使う。Talos では extension `siderolabs/i915` を schematic に入れてある(A310 は DG2 なので i915。`siderolabs/xe` とは同じ GPU を取り合うので両方は入れない) |
| NIC | Broadcom BCM5719 × 4(`tg3`)。`eno1`+`eno2` → `bond0`(10.0.0.2、`240f:6d:842b:1::2`)、`eno4` → 10.10.0.4 | 内蔵の Intel I218-LM 1 ポート(`e1000e`)+ **HP 361T**(Intel I350-T2、`igb`)。どちらも Talos のカーネルに入っているはず(**要確認**。talos.md に書いてあるのは tg3・bonding・AHCI だけ) |
| TV チューナー | PT3(PCIe、`earth_pt3`。extension `siderolabs/dvb-pt3`) | PCIe のスロットに差し替える |
| USB | B-CAS 用の IC カードリーダー(GemPC Twin)、キーボードの受信機 | 差し替える |
| リモート管理 | iLO(10.0.0.3) | **Intel AMT 9.x**(ME 9.1)。電源とシリアルコンソールは使えるが、画面(KVM)は使えない(「3. リモート管理: Intel AMT」) |

## 1. 事前の準備(サーバは止めない)

1. **Arc A310 を差す。** 外さない(無いと POST しない)。以下の BIOS の作業も画面が要る。
   **ただし古い BIOS は Arc を初期化できずに止まる**(白い LED だけでビープ無し、ファンが強くなる)。02.62 にするまでは補助電源の要らない古いグラボで作業する
2. **Z440 の BIOS を 02.62 に上げる**(HP の SoftPaq sp151054)。**v4 を載せる前に、仮の v3 の CPU と DL360 から移した RDIMM 1 枚で**やる
   (古い BIOS は v4 を認識しない)。起動中に Esc → 「Flash System BIOS」で USB メモリから書く(2026-10-31 に済み)
3. **ME を 9.1.45.3000 に上げる**(SoftPaq sp90102。9.1.37 は AMT にパスワード無しで入れる CVE-2017-5689 がある)。2026-10-31 に済み。**02.62 は USB から起動できない**
   (F9 の一覧が空。Esc の BIOS の更新だけは USB を読む)ので、UEFI シェルは **DVD(El Torito の UEFI イメージ)** から起動する。
   `FwUpdLcl.efi` は v2 のシェルだと `Error 8714`(ファイルを開けない)になり、**EDK1 の v1 のシェル(`Shell_Full.efi`)から動かすと通る**。
   `-generic` はこの版に無い。v2 のシェルで `connect -r` → `map -r` すると USB も見えるので、v1 のシェルと ME のファイルは USB に置いて、
   `fs1:\EFI\shellv1.efi` → `cd ME` → `FwUpdLcl.efi -f 9.1.45.3000.bin` → 電源コードを抜いて入れ直す
4. BIOS の設定: **起動は UEFI、CSM 無効**、セキュアブート無効、**After Power Loss = On**(停電のあと自動で上がる)、Wake on LAN。
   **CSM を切るまでは Arc で画面が出ないことがある**(Arc は UEFI の GOP 前提)。出なければ一時的に別の古いグラボで CSM を切る
5. **361T を差す**(ロープロファイルの金具ならフルハイトに付け替える)。届いて 3 日のうちに動くことを確かめる(出品者の初期不良の対応が 3 日)
6. **MAC アドレスを控える**: 内蔵の口(I218-LM は `48:0f:cf:67:0d:4e`。ME の `MeInfo.efi` で読んだ)と 361T のポート 1。BIOS の画面かラベル、何かの OS の `ip link`、ルーターの DHCP のリース一覧、
   AMT の画面のどれでもよい。移したあとは `talosctl get links` で照合できる

## 2. NIC と bond0(Talos)

Z440 では NIC の名前が DL360 と変わる(`eno1`〜`eno4` にはならない)。**名前ではなく MAC で選ぶ**:
`LinkAliasConfig` で別名を付け、`BondConfig` と `LinkConfig` はその別名を指す。

- 別名は `eno1` のような**システムの名前に見えるものにしない**(Talos が弾く)。例: `lan0` = 内蔵の Intel → `bond0` → 10.0 側(BL1500HM)、
  `jcom0` = 361T のポート 1 → 10.10 側(HUMAX)。361T の 2 ポート目は空けておく(`bond0` に足して冗長にもできる)
- 選ぶのは **`mac(link.permanent_addr)`**。bond のメンバーになると今の MAC は bond の MAC に変わるので、元の MAC で見る
- **`bond0` は残す**(メンバーは `lan0` の 1 本)。MAC は `hardwareAddr: e6:2c:1b:1a:a0:39` で固定してあるので、
  **DL360 でも Z440 でも変わらない**。ルーターの IPv6 公開のエントリ([router.md](router.md))は直さなくてよい
- `bootstrap/talos.sops.yaml` で `eno4` を名指ししているところ(`LinkConfig` と sysctl の `net.ipv6.conf.eno4.disable_ipv6`)も別名に直す

```yaml
apiVersion: v1alpha1
kind: LinkAliasConfig
name: lan0            # jcom0 も同じ形で、361T のポート 1 の MAC
selector:
    match: glob("<内蔵の口の MAC>", mac(link.permanent_addr))   # 公式の例の形。== で比べられるかは未確認
# BondConfig の links: [lan0]、LinkConfig の name: jcom0
```

**Z440 の MAC を `LinkAliasConfig` に `||` で足してから描く**(手順 4)。足さないと Z440 で別名が当たらず、10.0 側が上がらない。

### ディスク

`disk.dev_path == "/dev/sda"` は Z440 でも SSD 1 本なら同じになるはず(maintenance mode で `talosctl get disks` を見る。`bootstrap/talos.sops.yaml` の注)。
**入れ直しで、PV の置き場を local-path の `u-local-path`(xfs のパーティション 1 つ)から LVM に切り替える**
([decisions.md](decisions.md)「Z440 で、ストレージを OpenEBS LVM LocalPV に…」)。ボリュームは未割り当ての領域にしか作れないので、このときしか切り直せない。

| | 大きさ(447GB の SSD) | 作るもの |
| --- | --- | --- |
| EFI・BOOT・META・STATE | 数 GiB | Talos |
| `EPHEMERAL`(/var) | 64GiB で頭打ち | Talos(`VolumeConfig`) |
| `r-lvm` | 残り全部(380GiB ほど) | Talos(`RawVolumeConfig`)。VG `data` の唯一の PV(`LVMVolumeGroupConfig`) |
| thin プール `data_thinpool` | VG の 90%(340GiB ほど)。残りは溢れかけたときに足す分 | [lvm-thinpool](../bootstrap/storage.yaml)(Talos は thin を作れない) |
| PVC ごとの thin の LV(xfs) | PVC の requests が上限。書いた分だけプールを使う | OpenEBS LVM LocalPV(StorageClass は既定の `local-path`。名前は前のまま) |

local-path との違いで気を付けること:

- **PVC の requests が本当の上限になる。** local-path はディスクの残り全部が使えたので、`adguardhome-work`(5Gi)に 68 GB 入っていた。
  戻す前に `recovery/pv.sh - plan-all` が PVC に入るかを見る(`fit`。入らなければ止まる)
- **PVC の合計はプール(約 340Gi)に収める。** thin なので超えても作れるが、**プールが溢れると全部の PVC の書き込みが止まる。** 残りは denpa の encoded に回している(bootstrap/lvm-localpv-values.yaml)。
  `kubectl -n kube-system get pods -l app=lvm-thinpool` が 90% で NotReady になる(ログに 1 時間ごとの使用率)。
  denpa の残量の表示(statfs)は PVC の大きさで見るので、プールの空きより多く出る
- **新しい PVC の直下は root の 0755**(local-path は 0777 だった)。root 以外で書くアプリは `fsGroup` が要る(worklog に足した。ほかは付いているか root)
- etcd は `EPHEMERAL` に居るので、プールが溢れても巻き込まれない

## 3. リモート管理: Intel AMT

Z440 は Intel vPro の AMT(内蔵の Intel の口に乗る管理機能。ME 9.1 = AMT 9.x)を持つ。iLO の代わりに、OS が止まっていても使える。

- **使える**: 電源の入・切・再起動と状態の確認、**シリアルコンソール(Serial over LAN、SOL)**、ISO やディスクをネットワーク越しにつなぐ(IDE-R / USB-R)。
  SOL で見えるのは Talos のカーネルのコンソール(起動の様子とエラー)。**ログインは無い**ので、操作は `talosctl`
- **使えない**: 画面(KVM)。AMT の KVM は CPU 内蔵の GPU が前提で、Xeon E5 には無い(Arc の画面も AMT には乗らない)
- **AMT は内蔵の Intel の口(`lan0`)にしか乗らない。** 361T(10.10 側)からは使えない

### AMT の初期設定(Z440 の画面で 1 回だけ)

**MEBx は画面で操作する**ので、Arc にモニタをつなぎ、キーボードもつなぐ。

1. 起動中に **Ctrl+P** で MEBx に入る。最初のパスワードは `admin` で、すぐに変えさせられる
   (大文字・小文字・数字・記号を含む 8 文字以上)。新しいパスワードは Infisical に置く
2. **ネットワーク**: IPv4 は**固定で 10.0.0.5**(10.0.0.3 は DL360 の iLO。BL1500HM の DHCP は 10.0.0.10 からなので当たらない。
   AMT の IP は OS とは別に持つ)。名前(FQDN。例: `amt-main`)も聞かれる。**IPv6 は無効にする**
3. **リダイレクト**: SOL と IDE-R(USB-R)を有効にする
4. **「Activate Network Access」を実行する**(しないとネットワークから AMT に入れない)
5. **ユーザーの同意(User Consent)**: 「なし」(リモート操作のたびに本体の画面での承認を求めない)
6. Wake on LAN・電源が切れていても AMT を動かす設定(「ON in S0, ME Wake in S3, S4-5」)

### 守り

- AMT はパスワード 1 つで電源もコンソールも握れる。**家の外に出さない。** ルーターの DMZ は 10.0.0.2 だけなので 10.0.0.5 は外から届かない。
  IPv6 の公開は `bond0` の MAC(`e6:2c:1b:1a:a0:39`。設定で上書きした値)だけで、AMT は内蔵の口の元の MAC を使うので当たらない。
  それでも AMT の IPv6 は切っておく(上の 2)
- 使う口は 16992・16993(管理)と 16994・16995(SOL・IDE-R)

### Talos 側の設定(シリアルコンソール)

AMT の SOL は、OS からは PCI のシリアルポート(「Intel … KT Controller」)に見える。

1. 番号を確かめる: `talosctl -n 10.0.0.2 dmesg | grep ttyS`(`ttyS4` などになる)
2. Image Factory の schematic の `customization.extraKernelArgs` に `console=tty0` と `console=ttyS<番号>,115200n8` を足し、
   新しい schematic ID で `talosctl upgrade --image factory.talos.dev/installer/<schematic>:<版>`(再起動する)。
   カーネル引数は machine config に書けない(`bootstrap/talos.sops.yaml` の注、[talos.md](talos.md))。
   schematic ID は `bootstrap/talos.sops.yaml` の先頭の `# schematic:` に書く(Renovate と render.sh はそこを読む)。
   Arc の `siderolabs/i915` は移行の前に入れてある(その schematic に `extraKernelArgs` を足す)

### つなぎ方

- **Windows**: Intel の [Device Management Toolkit の Console](https://github.com/device-management-toolkit/console) を使う。
  Releases の `console_windows_x64.exe` を落として実行するだけ(Web の UI は同梱。初回だけ `Key Not Found, Generate new key? Y/N` に `Y`)。
  10.0.0.5 を足して、電源の操作・SOL・IDE-R(ISO をつなぐ)を使う。**常駐させない**(使うときだけ手元で起動する)
  - 選んだ理由: Intel の公式で開発中なのはこれだけ(Manageability Commander は終了、EMA は AMT 9 が対象外)
  - **未確認**: Console は README で「アルファ版、本番では使わない」としていて、対応する AMT の版も書いていない。**AMT 9 につながるか、
    UEFI(Arc のため CSM 無効)のまま IDE-R の ISO から起動できるかは、AMT の初期設定のあとで最初に試す**。
    つながらなければ [MeshCentral](https://github.com/Ylianst/MeshCentral) を手元で一時的に動かす。IDE-R がだめでも USB を挿せば済む
- **Linux**: `amtterm 10.0.0.5`(SOL)、`amttool`(電源)。Debian・Ubuntu のパッケージ `amtterm`
- **家の外から**: NetBird で 10.0.0.0/24 に入る。ただし **NetBird の入口(routing peer)はこのノードの上**なので、
  **ノードが止まっていると外からは届かない**。小さいサーバに入口を置けば、止まっていても外から電源を入れ直せる
- **ノード自身からは自分の AMT に届かない**(NIC を OS と分け合っていて、自分宛ては折り返さない)。ほかの機器か NetBird の端末から使う

## 4. 移す直前(DL360 で)

コマンドは全部 `tools/t.ps1 --admin` のシェルで打つ([../recovery/README.md](../recovery/README.md)「道具と経路」)。
LVM への切り替えは main に入っていること(入れたあと DL360 の Argo CD は `adguardhome-work` を 10Gi に広げられず、denpa などの縮めた PVC も縮められずに同期のエラーを出すが、
local-path が広げられないだけで、入れ直せば消える)。worklog の `fsGroup`(fj.doany.io の doa/worklog-cloud#179)も入っていること。

1. **AdGuard のクエリログを消す**(Web の「設定 → 一般設定 → クエリログを消去」)。`querylog.json` が 68 GB あり、
   最後のバックアップに乗ると、戻すときに `adguardhome-work`(10Gi)に入らず `plan-all` が止まる。
   消す前に、どの端末が 1 日 10 GB も引いているかを見ておく(2026-10 末から。前は 1 日 0.3 GB ほど)
2. **Z440 の MAC を `LinkAliasConfig` に足して main にマージ**(「2. NIC と bond0」)。talos-boot が通ること
3. machine config を描く: `./bootstrap/render.sh bootstrap/clusterconfig`(`valid for metal mode` まで出ること)。
   Talos の ISO を **DVD に焼いておく**(02.62 は USB から起動できない。「1. 事前の準備」の 3)。URL は `https://factory.talos.dev/image/<schematic>/<版>/metal-amd64.iso`([../recovery/README.md](../recovery/README.md) の 2)
4. 計画停止を知らせる(止まるもの: 全部の Web、DNS、NetBird、Matrix、録画)。録画の予約が入っていない時間にする
5. **最後のバックアップ**。ここから先に書かれたものは戻らない:

   ```shell
   sh recovery/pv.sh - backup-all          # Schedule のある namespace を全部、今すぐ取って待つ。全部 Succeeded になること
   kubectl -n k8up create job --from=cronjob/etcd-snapshot etcd-snapshot-final
   ```

6. `talosctl -n 10.0.0.2 shutdown`

## 5. 載せ替え

CPU(グリスを塗り直す)・メモリ 5 枚(Z440 に先に 1 枚ある)・SSD・PT3・USB 機器を Z440 に移す。仮の v3 の CPU は外す。
LAN は「2. NIC と bond0」のとおりにつなぐ。最初の起動はモニタ(Arc)とキーボードをつないでおく。

## 6. Z440 で入れ直して戻す

[../recovery/README.md](../recovery/README.md) の 2〜10 をそのまま流す。違うのは次のところ:

- **2. ISO で起動する**: DVD を入れて、起動中に **F9**(ブートメニュー)で DVD を選ぶ。AMT の IDE-R で ISO をつないでもよい(「3. リモート管理」。
  UEFI のまま IDE-R から起動できるかは未確認)。maintenance mode の IP は Arc の画面に出る。
  `talosctl get links --insecure` で **Z440 の MAC が 2. で足したものと一致する**こと、`talosctl get disks --insecure` で `/dev/sda` が 447GB の SSD であること
- **3. 当てる**: SSD は上書きされる(古いパーティションは消え、新しいパーティションは Talos が作るときに先頭を消す)。
  `talosctl get volumestatus` で `EPHEMERAL`(64GiB)と **`r-lvm`**(残り全部)が `ready`
- **4. クラスタを起こす**: 「Running」に `lvm-thinpool`・`lvm-localpv-node`・`lvm-localpv-controller`・`snapshot-controller`(kube-system)も入る。
  `kubectl -n kube-system logs ds/lvm-thinpool -c pool` の最後に `data_thinpool` が VG の 90% で出ていること。
  `kubectl get sc` で `local-path`(default)の PROVISIONER が `local.csi.openebs.io`
- **8. PV データを戻す**: `sh recovery/pv.sh - plan-all` の最後の「PVC に入るか」が全部通ること(入らないものは PVC を大きくするか restic から消す)

## 7. 起動して確かめる

- [ ] BIOS で CPU(E5-2696 v4、22 コア)とメモリ 48GB が見える
- [ ] 入れたあと SSD から起動する(UEFI の起動の選択に出なければ、SSD の `EFI/BOOT/BOOTX64.EFI` を選ぶ)
- [ ] [../recovery/README.md](../recovery/README.md) の 9 の確かめ(公開している名前・IPv6・DNS・NetBird・PT3 など)
- [ ] `talosctl -n 10.0.0.2 get addresses`: `bond0` に 10.0.0.2 と `240f:6d:842b:1::2`、`jcom0` に 10.10.0.4。
      `talosctl get links bond0` の MAC が `e6:2c:1b:1a:a0:39`
- [ ] `kubectl get nodes` が Ready、`kubectl get pods -A` で止まっているものが無い
- [ ] `kubectl get pvc -A` が全部 Bound、`kubectl -n kube-system get pods -l app=lvm-thinpool` が Ready。
      埋まり具合は `kubectl -n kube-system exec ds/lvm-thinpool -c watch -- lvs data`
- [ ] **一度 `talosctl -n 10.0.0.2 reboot` して、全部の Pod が戻る**(thin プールと LV を Talos が起動時に有効にする。talos-boot も見ている)
- [ ] Web(`https://fj.doany.io` など)が家の中と外から開く。外からの IPv6 でも届く([router.md](router.md) の確かめ方)
- [ ] DNS: 10.0.0.2 と 10.10.0.4 の両方で引ける
- [ ] NetBird がつながり、10.10.0.0/24 に届く
- [ ] PT3: `talosctl ls /dev/dvb` に adapter0〜3、録画が動く。B-CAS のカードリーダーが見える
- [ ] Arc が見える(`talosctl ls /dev/dri` に `renderD128`、`talosctl dmesg` に GuC / HuC。extension を入れたあと)。denpa 側は何もしなくてよい(ffmpeg は QSV / VA-API 入り、chart は `/dev/dri` をマウント済み)
- [ ] 次の k8up のバックアップ(03:00 JST の通知)が OK ✅

## 戻し方

**SSD は入れ直した時点で上書きされるので、DL360 に挿し戻しても元には戻らない。** 戻すときも同じ道
(DL360 に SSD を戻し、iLO(10.0.0.3)のコンソールで ISO から起動して、同じ config で入れ直し、restic から戻す)。
別名の `match` には両方の機械の MAC が `||` で並んでいるので、config は DL360 でもそのまま効く。
最後のバックアップより後に Z440 で書かれたものは、戻す前にもう一度 `backup-all` で取る。

## 終わったら

- [router.md](router.md)・この文書の構成表を Z440 に直す
- 「iLO(10.0.0.3)」と書いてあるところを AMT(10.0.0.5)に直す: deploy/netbird/routing-peer.yaml のコメント、ROADMAP.md、
  docs/decisions.md、recovery/README.md(建て直しの入口。ISO の起動と Secure Boot の手順も AMT の IDE-R に)、docs/talos.md の対象の行
- **10.10 側を外す**(小さいサーバをルーターにしたあと): `bootstrap/talos.sops.yaml` の 10.10 側の `LinkConfig`・別名・
  `disable_ipv6` の sysctl を消し、AdGuard の 10.10.0.4 の待ち受け(deploy/adguardhome/service-dns.yaml)を外し、
  10.10 側の機器の DNS を 10.0.0.2 にする。NetBird の 10.10.0.0/24 の経路は、BL1500HM の静的ルーティングで届くのでそのままでよい
