# Talos に移したノード main を SSD ごと Z440 に移す

DL360 Gen9 で動いている `main`(2026-10-17 から Talos)を、**SSD ごと** HP Z440 に移す計画(ROADMAP の Phase 2.5)。
あとで小さいサーバ(Talos)に 10.0 と 10.10 のあいだのルーターを任せ、Z440 は 10.0 側だけにする予定(「終わったら」)。

## 構成と、Z440 での扱い

| | DL360 Gen9(今) | Z440 |
| --- | --- | --- |
| CPU | Xeon E5-2696 v4(22 コア、LGA2011-3、150W) | 載せ替える。Z440 は E5-2600 v3 / v4 に対応(C612)。v4 のマイクロコードは BIOS 2.58 から入るので、**先に BIOS を 02.62 に上げる**(手順 1) |
| メモリ | DDR4 Registered 8GB。**2026-10-17 から 5 枚(40GB)**。1 枚は BIOS を上げるために Z440 へ移した | **6 枚 × 8GB = 48GB** にする。Z440 は Registered 専用、8 スロット、上限 128GB |
| SSD | SATA の Radeon R7 447GB 1 本。Smart Array 経由(素通し)なので Linux からは `TRAN=sas`・`/dev/sda` に見える | 内蔵の SATA(AHCI)に直結。`ahci` は Talos のカーネルに入っている([talos.md](talos.md)) |
| 起動 | UEFI、セキュアブート無効 | **UEFI、CSM 無効**(Arc の条件)、セキュアブート無効 |
| GPU | 無し(画面は iLO の Matrox G200) | **Intel Arc A310 を常設。** Xeon E5 は内蔵 GPU が無く、**Z440 は GPU が無いと POST しない**(画面なしで起動する BIOS の設定は見つからない。兄弟機には隠しの「Headless Mode」があるらしいが Z440 では未確認)。denpa の AV1 のハードウェアエンコードにも使う。Talos では extension が要る(`siderolabs/i915`。**要確認**) |
| NIC | Broadcom BCM5719 × 4(`tg3`)。`eno1`+`eno2` → `bond0`(10.0.0.2、`240f:6d:842b:1::2`)、`eno4` → 10.10.0.4 | 内蔵の Intel I218-LM 1 ポート(`e1000e`)+ **HP 361T**(Intel I350-T2、`igb`。2026-10-11 に購入)。どちらも Talos のカーネルに入っているはず(**要確認**。talos.md に書いてあるのは tg3・bonding・AHCI だけ) |
| TV チューナー | PT3(PCIe、`earth_pt3`。extension `siderolabs/dvb-pt3`) | PCIe のスロットに差し替える |
| USB | B-CAS 用の IC カードリーダー(GemPC Twin)、キーボードの受信機 | 差し替える |
| リモート管理 | iLO(10.0.0.3) | **Intel AMT 9.x**(ME 9.1)。電源とシリアルコンソールは使えるが、画面(KVM)は使えない(「3. リモート管理: Intel AMT」) |

## 1. 事前の準備(サーバは止めない)

1. **Arc A310 を差す。** 外さない(無いと POST しない)。以下の BIOS の作業も画面が要る
2. **Z440 の BIOS を 02.62 に上げる**(HP の SoftPaq sp151054)。**v4 を載せる前に、仮の v3 の CPU と DL360 から移した RDIMM 1 枚で**やる
   (古い BIOS は v4 を認識しない)。起動中に Esc → 「Flash System BIOS」で USB メモリから書く
3. BIOS の設定: **起動は UEFI、CSM 無効**、セキュアブート無効、**After Power Loss = On**(停電のあと自動で上がる)、Wake on LAN。
   **CSM を切るまでは Arc で画面が出ないことがある**(Arc は UEFI の GOP 前提)。出なければ一時的に別の古いグラボで CSM を切る
4. **361T を差す**(ロープロファイルの金具ならフルハイトに付け替える)。届いて 3 日のうちに動くことを確かめる(出品者の初期不良の対応が 3 日)
5. **MAC アドレスを控える**: 内蔵の口と 361T のポート 1。BIOS の画面かラベル、何かの OS の `ip link`、ルーターの DHCP のリース一覧、
   AMT の画面のどれでもよい。移したあとは `talosctl get links` で照合できる

## 2. NIC と bond0(Talos)

Z440 では NIC の名前が DL360 と変わる(`eno1`〜`eno4` にはならない)。**名前ではなく MAC で選ぶ**:
`LinkAliasConfig` で別名を付け、`BondConfig` と `LinkConfig` はその別名を指す。

- 別名は `eno1` のような**システムの名前に見えるものにしない**(Talos が弾く)。例: `lan0` = 内蔵の Intel → `bond0` → 10.0 側(BL1500HM)、
  `jcom0` = 361T のポート 1 → 10.10 側(HUMAX)。361T の 2 ポート目は空けておく(`bond0` に足して冗長にもできる)
- 選ぶのは **`mac(link.permanent_addr)`**。bond のメンバーになると今の MAC は bond の MAC に変わるので、元の MAC で見る
- **`bond0` は残す**(メンバーは `lan0` の 1 本)。MAC は `hardwareAddr: e6:2c:1b:1a:a0:39` で固定してあるので、
  **DL360 でも Z440 でも変わらない**。ルーターの IPv6 公開のエントリ([router.md](router.md))は直さなくてよい
- `talos/patches/cluster.yaml` で `eno4` を名指ししているところ(`LinkConfig` と sysctl の `net.ipv6.conf.eno4.disable_ipv6`)も別名に直す

```yaml
apiVersion: v1alpha1
kind: LinkAliasConfig
name: lan0            # jcom0 も同じ形で、361T のポート 1 の MAC
selector:
    match: glob("<内蔵の口の MAC>", mac(link.permanent_addr))   # 公式の例の形。== で比べられるかは未確認
# BondConfig の links: [lan0]、LinkConfig の name: jcom0
```

**ディスク**: `disk.dev_path == "/dev/sda"` は Z440 でも SSD 1 本なら同じになるはず(`talosctl get disks` で見る。`talos/patches/main.yaml` の注)。

**この config は DL360 では効かない**(MAC が当たらず 10.0 側が上がらない)ので、普通に当てない。
`talosctl apply-config --mode=staged` で**次の起動から**効くように置き、電源を切る直前にやる(手順 4)。

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
   カーネル引数は machine config に書けない(`talos/patches/main.yaml` の注、[talos.md](talos.md))。
   schematic ID は `talos/versions.yaml` と `main.yaml` の注も揃える。**Arc の extension を足すのも同じ手順**なので一緒にやる

### つなぎ方

- **Windows**: [Intel Manageability Commander](https://www.intel.com/content/www/us/en/download/18796/intel-manageability-commander.html)
  (Intel の公式。前身の MeshCommander は 2022 年に開発終了)。10.0.0.5 に入り、電源の操作と SOL の画面を使う
- **Linux**: `amtterm 10.0.0.5`(SOL)、`amttool`(電源)。Debian・Ubuntu のパッケージ `amtterm`
- **家の外から**: NetBird で 10.0.0.0/24 に入る。ただし **NetBird の入口(routing peer)はこのノードの上**なので、
  **ノードが止まっていると外からは届かない**。小さいサーバに入口を置けば、止まっていても外から電源を入れ直せる
- **ノード自身からは自分の AMT に届かない**(NIC を OS と分け合っていて、自分宛ては折り返さない)。ほかの機器か NetBird の端末から使う

## 4. 移す直前

1. **k8up のバックアップが成功している**こと: 夜のぶん(03:00 JST の通知)が OK ✅。手で確かめるなら
   `kubectl -n k8up create job --from=cronjob/k8up-notify notify-manual`([../apps/k8up/README.md](../apps/k8up/README.md))
2. 計画停止を知らせる(止まるもの: 全部の Web、DNS、NetBird、Matrix、録画)
3. Z440 用の config を置く: `render.sh` → `talosctl -n 10.0.0.2 apply-config --mode=staged -f talos/clusterconfig/controlplane.yaml`
4. `talosctl -n 10.0.0.2 shutdown`

## 5. 載せ替え

CPU(グリスを塗り直す)・メモリ 5 枚(Z440 に先に 1 枚ある)・SSD・PT3・USB 機器を Z440 に移す。仮の v3 の CPU は外す。
LAN は「2. NIC と bond0」のとおりにつなぐ。最初の起動はモニタ(Arc)とキーボードをつないでおく。

## 6. 起動して確かめる

- [ ] BIOS で CPU(E5-2696 v4、22 コア)とメモリ 48GB が見える
- [ ] SSD から起動する(UEFI の起動の選択に出なければ、SSD の `EFI/BOOT/BOOTX64.EFI` を選ぶ)
- [ ] `talosctl -n 10.0.0.2 get addresses`: `bond0` に 10.0.0.2 と `240f:6d:842b:1::2`、`jcom0` に 10.10.0.4。
      `talosctl get links bond0` の MAC が `e6:2c:1b:1a:a0:39`
- [ ] `kubectl get nodes` が Ready、`kubectl get pods -A` で止まっているものが無い
- [ ] Web(`https://fj.doany.io` など)が家の中と外から開く。外からの IPv6 でも届く([router.md](router.md) の確かめ方)
- [ ] DNS: 10.0.0.2 と 10.10.0.4 の両方で引ける
- [ ] NetBird がつながり、10.10.0.0/24 に届く
- [ ] PT3: `talosctl ls /dev/dvb` に adapter0〜3、録画が動く。B-CAS のカードリーダーが見える
- [ ] Arc が見える(`talosctl ls /dev/dri`。extension を入れたあと)
- [ ] 次の k8up のバックアップ(03:00 JST の通知)が OK ✅

## 戻し方

SSD とほかの部品を DL360 に戻し、iLO(10.0.0.3)のコンソールで見ながら起動する。
**staged で置いた Z440 用の config のままでは、DL360 で 10.0 側が上がらない。** Z440 で動いているうちに戻すなら、
DL360 用の config を `apply-config --mode=staged` してから `shutdown` して移す。

**別案(要検証)**: 別名の `match` に**両方の機械の MAC を `||` で並べ**、DL360 でも Z440 でも効く config を 1 つにする。
移す前に DL360 で普通に当てて効くことを確かめられ、戻すときも何も変えなくてよい。
DL360 の `eno2`(bond の 2 本目)のように、片方の機械にしか無い口の別名がエラーにならないかを先に確かめる。

## 終わったら

- [router.md](router.md)・この文書の構成表を Z440 に直す
- 「iLO(10.0.0.3)」と書いてあるところを AMT(10.0.0.5)に直す: apps/netbird/routing-peer.yaml のコメント、ROADMAP.md、
  docs/decisions.md、recovery/README.md(建て直しの入口。ISO の起動と Secure Boot の手順も AMT の IDE-R に)、docs/talos.md の対象の行
- **10.10 側を外す**(小さいサーバをルーターにしたあと): `talos/patches/cluster.yaml` の 10.10 側の `LinkConfig`・別名・
  `disable_ipv6` の sysctl を消し、AdGuard の 10.10.0.4 の待ち受け(apps/adguardhome/service-dns.yaml)を外し、
  10.10 側の機器の DNS を 10.0.0.2 にする。NetBird の 10.10.0.0/24 の経路は、BL1500HM の静的ルーティングで届くのでそのままでよい
