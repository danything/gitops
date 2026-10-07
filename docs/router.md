# 家のルーター

ルーターには API が無いので、設定はここに書いて持つ(IaC にはできない)。これまで decisions.md・apps/matrix/README.md・
docs/talos.md に散らばっていたものを 1 つにまとめた(2026-10-07)。**ルーターの設定を変えたら、ここも直す。**

**`要記入` の欄は、リポジトリに書かれていなかったもの。** 画面で確かめて埋める。

## 機器

| 項目 | 値 |
| --- | --- |
| 機種 | 要記入 |
| 管理画面 | 要記入(LAN 側の `10.0.0.1` と思われる) |
| 回線・接続方式(PPPoE / IPoE など) | 要記入 |
| 外向きの IPv4 | 固定ではない。cloudflare-ddns が `doany.io` と `nb.origin.doany.io` を追従させる(apps/cloudflare-ddns/) |
| IPv6 | プレフィックス `240f:6d:842b:1::/64`(RA で配られる。**変わりうる**ので、どこにも固定で書かない) |

## LAN

| 項目 | 値 |
| --- | --- |
| LAN | `10.0.0.0/24`、ルーターは `10.0.0.1` |
| ノード `main` | `10.0.0.2`(bond0)、`240f:6d:842b:1::2`(静的 IPv6)。**DHCP の固定割り当てか、ノード側の静的設定かは要記入** |
| 別の LAN | `10.10.0.0/24`。ノードの `enp0s4`(実機は eno4)が `10.10.0.4` |
| DNS | 端末には AdGuard Home(ノードの 53)を配る。配り方(ルーターの DHCP の DNS 欄か)は要記入 |

## 外からの転送

**DMZ(すべての受信)をノード `10.0.0.2` に向けている。** 個別のポート転送ではないので、ノードで受けているものは全部外に出る。
DMZ の向け先を変えると、下の全部と AdGuard の split-horizon が一斉に外れる(decisions.md「LoadBalancer をどう置き換えるか」)。

ノードで受けているもの(hostPort。増やすと、それも外に出る):

| ポート | 何 | 外から要るか |
| --- | --- | --- |
| 80 / 443 TCP | Gateway(全部の Web) | 要る |
| 53 UDP・TCP / 853 TCP | AdGuard Home(DNS / DoT) | 853 は外の端末用。**53 は家の中用で、外には要らない**(下の「要確認」) |
| 8443 UDP・TCP | LiveKit(Matrix の通話。apps/matrix/README.md) | 要る |
| 3478 UDP | NetBird の STUN(apps/netbird/) | 要る |
| 51822 UDP | NetBird の routing peer(WireGuard) | 要る |
| 3129 TCP | 3proxy の TLS 口(apps/3proxy/) | 外から使うなら要る |
| 6443 TCP | Kubernetes の API(`ks.doany.io:6443`。recovery/README.md) | 要る(認証つき) |

Talos の API(50000)は LAN からしか届かない(recovery/README.md)。

## 要確認: 外から 53 番に答えていないか

AdGuard Home は問い合わせ元を絞っていない(apps/adguardhome/config.yaml の `allowed_clients: []`)。
DMZ で 53 番まで外に出ていると、**誰の問い合わせにも答えるオープンリゾルバ**になり、DNS の増幅攻撃の踏み台に使われうる。
回線側で 53 番の受信が止められていることもあるので、**家の外から**確かめる(家の中からはヘアピンで届いてしまう):

```shell
dig @<外向きの IPv4> example.com +time=3 +tries=1   # 答えが返ったら開いている
```

開いていたら、ルーターで 53 番の受信を止める(DMZ をやめて個別の転送にする)か、AdGuard の `allowed_clients` に
家の LAN・Pod・NetBird の範囲だけを書く。

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
