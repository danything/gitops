# 家のルーター

ルーターには API が無いので、設定はここに書いて持つ(IaC にはできない)。これまで decisions.md・apps/matrix/README.md・
docs/talos.md に散らばっていたものを 1 つにまとめた(2026-10-07)。**ルーターの設定を変えたら、ここも直す。**

**`要記入` の欄は、管理画面にログインしないと読めないもの。** 画面で確かめて埋める。

## 機器

| 項目 | 値 |
| --- | --- |
| 機種 | au ひかりのホームゲートウェイ **BL1500HM**(KDDI。管理画面の「クイック設定Web」のページから。2026-10-07) |
| 管理画面 | `http://10.0.0.1/`(クイック設定Web。ログインが要る) |
| 回線 | au ひかり(接続はホームゲートウェイが持つ。IPv6 はネイティブで RA が来る) |
| 外向きの IPv4 | 固定ではない。cloudflare-ddns が `doany.io` と `nb.origin.doany.io` を追従させる(apps/cloudflare-ddns/) |
| IPv6 | プレフィックス `240f:6d:842b:1::/64`(RA で配られる。**変わりうる**ので、どこにも固定で書かない) |
| IPv6 の受信のフィルタ | 要記入(DMZ は IPv4 の話。ノードの `240f:6d:842b:1::2` に外から何が届くかは、ルーターの IPv6 のファイアウォールで決まる) |

## LAN

| 項目 | 値 |
| --- | --- |
| LAN | `10.0.0.0/24`、ルーターは `10.0.0.1` |
| ノード `main` | `10.0.0.2`(bond0)、`240f:6d:842b:1::2`。**ノード側の静的設定**(`/etc/netplan/00-main.yaml`。DHCP は使わない。既定経路は `10.0.0.1`、IPv6 は RA を受ける) |
| 別の LAN | `10.10.0.0/24`(ゲートウェイ `10.10.0.1`)。ノードの eno4 が `10.10.0.4`(静的。既定経路には使わない) |
| DNS | 端末には AdGuard Home(ノードの 53)を配る。配り方(ルーターの DHCP の DNS 欄か)は要記入 |

## 外からの転送

**DMZ(すべての受信)をノード `10.0.0.2` に向けている。** 個別のポート転送ではないので、ノードで受けているものは全部外に出る。
DMZ の向け先を変えると、下の全部と AdGuard の split-horizon が一斉に外れる(decisions.md「LoadBalancer をどう置き換えるか」)。

ノードで受けているもの(hostPort。増やすと、それも外に出る):

| ポート | 何 | 外から要るか |
| --- | --- | --- |
| 80 / 443 TCP | Gateway(全部の Web) | 要る |
| 53 UDP・TCP / 853 TCP | AdGuard Home(DNS / DoT) | 開けている(下の「53 番は外にも開けている」) |
| 8443 UDP・TCP | LiveKit(Matrix の通話。apps/matrix/README.md) | 要る |
| 3478 UDP | NetBird の STUN(apps/netbird/) | 要る |
| 51822 UDP | NetBird の routing peer(WireGuard) | 要る |
| 3129 TCP | 3proxy の TLS 口(apps/3proxy/) | 外から使うなら要る |
| 6443 TCP | Kubernetes の API(`ks.doany.io:6443`。recovery/README.md) | 要る(認証つき) |

Talos の API(50000)は LAN からしか届かない(recovery/README.md)。

## 53 番は外にも開けている(意図して)

AdGuard Home は問い合わせ元を絞っておらず(apps/adguardhome/config.yaml の `allowed_clients: []`)、DMZ で 53 番も外に出ている。
**意図してそうしている**(2026-10-07 に確認)。オープンリゾルバとして DNS の増幅攻撃の踏み台に使われうることは承知の上。
閉じるときは、ルーターで 53 番の受信を止めるか、`allowed_clients` に家の LAN・Pod・NetBird の範囲だけを書く。

## ヘアピン NAT(NAT ループバック)

**有効にしておくこと。** 家の中の端末も、LiveKit や NetBird が STUN で調べた外の IP に向けて送る。
無効だと家の中からだけ通話がつながらない(apps/matrix/README.md「ルーターの転送」)。
Web は AdGuard の split-horizon で家の中では `10.0.0.2` を引くので、ヘアピンに頼らない。

## 作り直す・機種を替えるとき

1. LAN を `10.0.0.0/24`、ルーターを `10.0.0.1` にする
2. ノードを `10.0.0.2` にする
3. DMZ を `10.0.0.2` に向ける
4. ヘアピン NAT を有効にする
5. DHCP で配る DNS を AdGuard Home にする
6. 外から確かめる: `https://doany.io`、Element の通話、NetBird の接続
