# DL360 Gen9 から HP Z440 へ移す

今のノード `main`(Ubuntu + k3s)を、**SSD ごと** HP Z440 に移す手順(2026-10-11 にまとめた)。
OS と k3s はそのまま。Talos への移行(talos.md・migration-day.md)とは別の話で、こちらが先。

あとで小さいサーバ(Talos)を足して 10.0 と 10.10 の 2 つの LAN のあいだのルーターを任せ、Z440 は 10.0 側だけにする予定
(そのときは「10.10 側を外す」の節)。

## 今の構成と、Z440 での扱い

| | DL360 Gen9(今) | Z440 |
| --- | --- | --- |
| CPU | Xeon E5-2696 v4(22 コア、LGA2011-3、150W) | 載せ替える。Z440 は E5-2600 v3 / v4 に対応(C612)。v4 は BIOS が新しい必要があるので**先に BIOS を 02.62 に上げる**(シリアル `JPH6212F3G` = 2016 年第 21 週製造で、v4 対応の版のはず) |
| メモリ | DDR4 Registered 8GB × 6(48GB) | そのまま挿す。Z440 は Registered 専用、8 スロット、上限 128GB |
| SSD | SATA の Radeon R7 447GB 1 本。Smart Array(hpsa)経由だが素通し(RAID にしていない) | Z440 の SATA ポートに直結。起動用イメージ(initramfs)に `ahci` が入っていることを確認済み |
| 起動 | UEFI、セキュアブート無効。`EFI/BOOT/BOOTX64.EFI`(予備の起動ファイル)あり | Z440 に起動の登録が無くても、予備の起動ファイルで SSD から起動できる。Z440 の BIOS もセキュアブートは無効にしておく |
| NIC | Broadcom BCM5719 × 4(`tg3`)。`eno1`+`eno2` → `bond0`(10.0.0.2、`240f:6d:842b:1::2`)、`eno4` → 10.10.0.4 | 内蔵の Intel 1 ポート(`e1000e`)+ **HP 361T**(Intel I350-T2、`igb`。2026-10-11 に購入)。どちらのドライバも initramfs に入っている |
| TV チューナー | PT3(PCIe、Altera `1172:4c15`、`earth_pt3`) | PCIe のスロットに差し替える |
| USB | B-CAS 用の IC カードリーダー(GemPC Twin)、キーボードの受信機 | 差し替える |
| リモート管理 | iLO | iLO は無い。**Intel AMT(vPro)で電源の操作とシリアルコンソールは使える**が、画面(KVM)は使えない(「リモート管理: Intel AMT」)。初回の起動はモニタとキーボードをつなぐ |

k3s の設定(`/etc/rancher/k3s/config.yaml`)は NIC の名前を使っていない(ノードの IP は既定の経路の口から自動で決まる)。
NIC の名前に頼っているのは **netplan** と、cloudflare-ddns の `ip6Provider: local.iface.stable:bond0`
(apps/cloudflare-ddns/application.yaml)だけ。

## 方針: NIC の名前と bond0 を今と同じにする

Z440 の NIC に **MAC アドレスで今と同じ名前(`eno1`・`eno4`)を付ける**。こうすると netplan のほかは何も変えなくてよい。

- **`bond0` は残す**(メンバーは 1 本になる)。`bond0` の MAC(`e6:2c:1b:1a:a0:39`)は systemd-networkd が
  マシン ID と名前から作っているので、`bond0` を残せば変わらない。**ルーターの IPv6 公開のエントリはこの MAC を指している**
  (router.md)。`bond0` をやめるならルーターのエントリも直す
- 10.10 側(`eno4`)は 361T の 1 ポート目。2 ポート目は空けておく(`bond0` に足して 2 本の冗長にもできる)

| 名前 | Z440 の口 | つなぐ先 |
| --- | --- | --- |
| `eno1`(→ `bond0`) | 内蔵の Intel | 10.0 側(BL1500HM の LAN) |
| `eno4` | 361T のポート 1 | 10.10 側(HUMAX の LAN) |

## 1. 事前の準備(サーバは止めない)

1. **Z440 の BIOS を 02.62 に上げる**(HP の SoftPaq sp151054。今 Z440 に載っている CPU のままで)。
   v4 を載せてから上げようとすると、古い BIOS が v4 を認識せずに起動しないことがある
2. **361T を Z440 に差す**。Z440 は普通の高さのスロットなので、金具がロープロファイルならフルハイトの金具に付け替える
   (ヤフオクで 550〜700 円)。届いて 3 日のうちに動くことを確かめる(出品者の初期不良の対応が 3 日)
3. **MAC アドレスを控える**: Z440 の内蔵の口(BIOS の画面か本体のラベル)と、361T のポート 1(カードのシールか、
   何かの OS で起動して `ip link`)
4. BIOS の設定: セキュアブート無効、起動は UEFI、電源が戻ったら起動する(停電のあと自動で上がるように)、Wake on LAN

## 2. Z440 用の netplan を別のファイルで用意する(移す前に今のサーバで)

**1 つのファイルに DL360 用と Z440 用の両方を書かない。** Z440 で名前の `eno1` と MAC で名前を付けた口の両方の定義が
当たり、どちらが効くかがファイルの並び順任せになる。Z440 用は別のファイルに丸ごと書き、
**電源を切る直前に入れ替える**(DL360 はもう起動しないので、入れ替えたあとに DL360 で効くことは無い)。

1. 今の `/etc/netplan/00-main.yaml` を `sudo cat` で確かめる
2. それを写して `/etc/netplan/00-main.yaml.z440` を作り(拡張子が `.yaml` でないので netplan は読まない)、
   `ethernets:` の `eno1` / `eno2` / `eno4` を次に置き換える。`bond0`(`interfaces: [eno1]` に減らす)と
   `eno4` の IP・経路はそのまま。`<…>` は控えた MAC

```yaml
  ethernets:
    eno1:
      match:
        macaddress: "<Z440 の内蔵の口の MAC>"
      set-name: eno1
      wakeonlan: true
    eno4:
      match:
        macaddress: "<361T のポート 1 の MAC>"
      set-name: eno4
      # (ここから下は今の eno4 の設定をそのまま: dhcp4: false、addresses: 10.10.0.4/24、routes …)
  bonds:
    bond0:
      interfaces: [eno1]
      # (ほかは今の bond0 のまま)
```

3. 書いたら中身を目で見て確かめるだけにする。**`netplan apply` はしない**(bond0 を作り直すので k3s が動いているあいだは
   避ける。00-main.yaml の先頭の注意)。このファイルは移す直前に入れ替える(「3. 移す直前」の手順 3)

## 3. 移す直前

1. バックアップを取って成功を確かめる: `sudo systemctl start k3s-backup.service` → `journalctl -u k3s-backup -n 50`
   (backup/README.md)
2. 計画停止を知らせる(止まるもの: 全部の Web、DNS、NetBird、Matrix、録画)
3. netplan を Z440 用に入れ替える(反映はしない。次の起動から効く):
   `sudo mv /etc/netplan/00-main.yaml /etc/netplan/00-main.yaml.dl360 && sudo mv /etc/netplan/00-main.yaml.z440 /etc/netplan/00-main.yaml`
4. `sudo poweroff`

## 4. 載せ替え

CPU(グリスを塗り直す)・メモリ 6 枚・SSD・PT3・USB 機器を Z440 に移す。LAN は上の表のとおりにつなぐ。
モニタとキーボードをつなぐ。

## 5. 起動して確かめる

- [ ] BIOS で CPU(E5-2696 v4、22 コア)とメモリ 48GB が見える
- [ ] SSD から起動する(起動の選択に出なければ、`EFI/BOOT/BOOTX64.EFI` を選ぶ)
- [ ] `ip -br addr`: `bond0` に 10.0.0.2 と `240f:6d:842b:1::2`、`eno4` に 10.10.0.4。`ip link show bond0` の MAC が `e6:2c:1b:1a:a0:39`
- [ ] `kubectl get nodes` が Ready、`kubectl get pods -A` で止まっているものが無い
- [ ] Web(`https://fj.doany.io` など)が家の中と外から開く。外からの IPv6 でも届く(router.md の確かめ方)
- [ ] DNS: 10.0.0.2 と 10.10.0.4 の両方で引ける
- [ ] NetBird がつながり、10.10.0.0/24 に届く
- [ ] PT3: `ls /dev/dvb` に adapter0〜3、録画が動く。B-CAS のカードリーダーが見える
- [ ] 翌朝のバックアップ(04:00)が成功している

## 戻し方

SSD とほかの部品を DL360 に戻し、DL360 の画面(モニタか iLO)で netplan を元に戻して再起動する:
`sudo mv /etc/netplan/00-main.yaml /etc/netplan/00-main.yaml.z440 && sudo mv /etc/netplan/00-main.yaml.dl360 /etc/netplan/00-main.yaml`
(戻さないとネットワークが上がらない。ほかは何も変えていないので、それで元どおりになる)

## リモート管理: Intel AMT

Z440 は Intel vPro の AMT(内蔵の Intel の口に乗る管理機能)を持つ。iLO の代わりに、OS が止まっていても
次のことができる。

| 機能 | 使えるか |
| --- | --- |
| 電源の入・切・再起動、状態の確認 | 使える |
| **シリアルコンソール(Serial over LAN、SOL)** | 使える。Ubuntu のテキストの画面と GRUB を、ネットワーク越しに見て操作できる(下の Ubuntu 側の設定が要る) |
| 起動用の ISO やディスクを、ネットワーク越しにつなぐ(IDE-R / USB-R) | 使える |
| 画面(KVM、リモートデスクトップ) | **使えない**。AMT の KVM は CPU 内蔵の GPU が前提で、Xeon E5 には無い(Intel の資料・コミュニティ) |

**AMT は内蔵の Intel の口(`eno1`)にしか乗らない。** 361T(10.10 側)からは使えない。

### AMT の初期設定(Z440 の画面で 1 回だけ)

1. 起動中に **Ctrl+P** で MEBx(AMT の設定画面)に入る。最初のパスワードは `admin` で、すぐに変えさせられる
   (大文字・小文字・数字・記号を含む 8 文字以上)。新しいパスワードは Infisical に置く
2. **ネットワーク**: IPv4 は**固定で 10.0.0.3**(BL1500HM の DHCP は 10.0.0.10 から配るので当たらない。
   AMT の IP は OS とは別に持つ)。**IPv6 は無効にする**
3. **リダイレクト**: SOL と IDE-R(USB-R)を有効にする
4. **ユーザーの同意(User Consent)**: 「なし」にする(リモートから操作するときに、本体の画面での承認を求めない)
5. Wake on LAN・電源が切れていても AMT を動かす設定(「ON in S0, ME Wake in S3, S4-5」)

### 守り

- AMT はパスワード 1 つで電源もコンソールも握れる。**家の外に出さない。**
  - ルーターの DMZ は 10.0.0.2(ノード)だけに向いているので、10.0.0.3 の AMT は外から届かない
  - IPv6 の公開はノード(`bond0` の MAC `e6:2c:1b:1a:a0:39`)だけで、AMT は内蔵の口の元の MAC を使うので当たらない。
    念のため AMT の IPv6 は切る(上の 2)
- 使う口は 16992・16993(管理)と 16994・16995(SOL・IDE-R)

### Ubuntu 側の設定(シリアルコンソール)

AMT の SOL は、OS からは PCI のシリアルポート(「Intel … KT Controller」)に見える。

1. 番号を確かめる: `lspci | grep -i "KT Controller"` と `dmesg | grep ttyS`(`ttyS4` などになる)
2. `/etc/default/grub` の `GRUB_CMDLINE_LINUX` に `console=tty0 console=ttyS<番号>,115200n8` を足し、
   GRUB 自身も出すなら `GRUB_TERMINAL="console serial"` と `GRUB_SERIAL_COMMAND="serial --speed=115200"` を足して
   `sudo update-grub`
3. ログインできるようにする: `sudo systemctl enable --now serial-getty@ttyS<番号>.service`

### つなぎ方

- **Windows**: [Intel Manageability Commander](https://www.intel.com/content/www/us/en/download/18796/intel-manageability-commander.html)
  (Intel の公式、Windows 用。前身の MeshCommander は 2022 年に開発終了)。10.0.0.3 にパスワードで入り、電源の操作と
  Serial-over-LAN の画面を使う
- **Linux**: `amtterm 10.0.0.3`(シリアルコンソール)、`amttool`(電源)。Debian・Ubuntu のパッケージ `amtterm`
- **家の外から**: NetBird で 10.0.0.0/24 に入って使う。ただし **今の NetBird の入口(routing peer)はこのノードの上**なので、
  **ノードが止まっていると外からは AMT に届かない**。小さいサーバ(Talos)を足して入口をそちらにも置けば、
  ノードが止まっていても外から電源を入れ直せる

## 終わったら

- 戻す見込みが無くなったら `/etc/netplan/00-main.yaml.dl360` を消してよい
- router.md・この文書の「今の構成」を Z440 に直す
- **10.10 側を外す**(小さいサーバをルーターにしたあと): netplan の `eno4` を消し、AdGuard の 10.10.0.4 の待ち受け
  (apps/adguardhome/service-dns.yaml)を外し、10.10 側の機器の DNS を 10.0.0.2 にする。NetBird の 10.10.0.0/24 の経路は、
  BL1500HM の静的ルーティングで届くのでそのままでよい
