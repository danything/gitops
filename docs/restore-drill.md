# 復元リハーサル(サーバ上の QEMU/KVM で)

**k3s 期だけのやり方。** Talos のノードにはシェルも QEMU も無いので、この形では流せない(Talos 期の戻し方は [recovery/README.md](../recovery/README.md)「Talos に移ったあと」)。

Hyper-V は WSL から管理者権限で触れないので、本番サーバ(当時 46 GB の RAM。2026-10-17 から 40 GB、VT-x)の上に QEMU/KVM で Ubuntu の VM を立てて、
そこに `recovery/` の `restore.sh` を `RESTORE_DRILL=1` で流す。初回 2026-09-06、Cilium 構成での再実施が 2026-09-07。

## 副作用を出さないための遮断(VM の中で最初にやる)

復元されたクラスタは本物と同じ設定で立ち上がるので、そのままだと cloudflare-ddns が DNS を書き換え、cert-manager が ACME を叩き、
ArgoCD が通知を投げ、Infisical がメールを出す。raw テーブルで先に落とす(k3s が後から入れる FORWARD のルールより先に評価される)。

**SMTP だけは DROP ではなく REJECT。** Infisical は起動時の SMTP 接続検証が通るまで HTTP を listen しないので、
DROP にすると永遠に上がってこない(2026-09-06 の 1 回目で踏んだ)。そして **raw テーブルには REJECT ターゲットが無い**ので、
SMTP のぶんだけは filter テーブル(`OUTPUT` と `FORWARD`)に入れる。

```shell
# api.cloudflare.com / acme-v02.api.letsencrypt.org / 本番の公開 IP。IP は VM の中で getent で引き直す
for ip in 104.19.192.174 104.19.192.175 104.19.192.176 104.19.192.177 104.19.192.29 104.19.193.29 172.65.32.248 59.140.229.91; do
  sudo iptables -t raw -I PREROUTING -d $ip -j DROP; sudo iptables -t raw -I OUTPUT -d $ip -j DROP
  sudo iptables -I FORWARD -d $ip -j DROP
done
# SMTP は REJECT(filter)。DROP だと Infisical が起動しない
for p in 587 465 25; do
  sudo iptables -I OUTPUT  -p tcp --dport $p -j REJECT --reject-with tcp-reset
  sudo iptables -I FORWARD -p tcp --dport $p -j REJECT --reject-with tcp-reset
done
# QEMU の user-mode network は IPv6 も外に出せるので、グローバル宛は全部落とす(R2 も k3s も IPv4 で足りる)
sudo ip6tables -t raw -I OUTPUT -d 2000::/3 -j DROP; sudo ip6tables -t raw -I PREROUTING -d 2000::/3 -j DROP
```

**Cilium にしても iptables の遮断はそのまま効く**(2026-09-07 に確認)。Cilium 1.20.1 は
`Masquerading: IPTables` / `Host Routing: Legacy` なので Pod の外向き通信も netfilter を通る。
実際に cloudflare-ddns・cert-manager・argocd-notifications の **Pod のログ**で
それぞれ `error sending request`・`dial tcp 172.65.32.248:443: i/o timeout`・
`dial tcp 59.140.229.91:443: connect: connection timed out` を確認した。

### **k8up: R2 の本番リポジトリに書かせない**

復元したクラスタには k8up の `Schedule` が戻ってくる。
向き先は **本番の restic リポジトリ**なので、放っておくとリハーサルのスナップショットが本番に混ざる。
`restore.sh` 自体は R2 の読みが要るため、最初から R2 を塞ぐことはできない。

1. **始める前にスナップショット数を控える。** ホストのスクリプトのぶんは `k3s-host`、k8up のぶんは `k8up` のタグが付く。

   ```shell
   sudo sh -c 'set -a; . /etc/k3s-backup/env; set +a; restic snapshots --compact'
   ```

2. **restic の展開が終わったら(k3s が起動したら)VM の中で R2 を塞ぐ。** ここから先 R2 は要らない。

   ```shell
   for ip in $(getent ahostsv4 <account-id>.r2.cloudflarestorage.com | awk '{print $1}' | sort -u); do
     sudo iptables -t raw -I OUTPUT -d $ip -j DROP; sudo iptables -t raw -I PREROUTING -d $ip -j DROP
     sudo iptables -I OUTPUT -d $ip -j DROP; sudo iptables -I FORWARD -d $ip -j DROP
   done
   ```

3. **`Schedule` を消す。** Argo CD が作り直すので、消えたままにはならない。効くのは次の 2 段目のほう。

   ```shell
   sudo k3s kubectl delete schedules.k8up.io --all -A
   ```

4. **operator の資格情報(`k8up-global` Secret)を消す。** `restore.sh` はリハーサルモードではこれを作らないので、
   スナップショットに入っていなければ operator は `CreateContainerConfigError` で起動しない。
   入っている(=新しいスナップショットから戻した)なら、`kubectl -n k8up delete secret k8up-global` で同じ状態にできる。

5. **終わったらホスト側で数え直す。** 増えていなければ本番は無傷。

## VM の作り方(サーバ上)

```shell
sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils
D=/var/tmp/restore-drill; mkdir -p $D; cd $D
curl -fsSLO https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img
ssh-keygen -t ed25519 -N "" -f drill_key
qemu-img create -f qcow2 -F qcow2 -b $D/resolute-server-cloudimg-amd64.img disk.qcow2 60G
# hostname は必ず main(state.db の Node と local-path PV の nodeAffinity が main を指している)
cat > user-data <<UD
#cloud-config
hostname: main
manage_etc_hosts: true
users:
  - name: ruk
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: [ "$(cat drill_key.pub)" ]
UD
printf 'instance-id: restore-drill-1\nlocal-hostname: main\n' > meta-data
cloud-localds seed.iso user-data meta-data
sudo qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 8192 -display none -serial file:$D/console.log \
  -drive file=$D/disk.qcow2,if=virtio -drive file=$D/seed.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 -daemonize -pidfile $D/qemu.pid
ssh -i drill_key -p 2222 ruk@127.0.0.1
```

## VM の中

```shell
# 遮断ルール(上)を入れてから
sudo apt-get update && sudo apt-get install -y age
sudo mkdir -p /etc/k3s-backup
curl -fsSL https://raw.githubusercontent.com/danything/gitops/main/recovery/env.age | sudo age -d -o /etc/k3s-backup/env   # パスフレーズ
curl -fsSLO https://raw.githubusercontent.com/danything/gitops/main/recovery/restore.sh
sudo systemd-run --unit=restore-drill --collect --setenv=RESTORE_DRILL=1 sh restore.sh
journalctl -u restore-drill -u k3s-restore-finish -f
sudo k3s kubectl get pods -A
```

`RESTORE_DRILL=1` がやること: bond0/eno4 のプロファイルを当てない、`k3s-backup.timer` を有効にしない
(VM のスナップショットを本番の restic リポジトリに混ぜない)。

`restore.sh` は `RESTIC_REPOSITORY` の環境変数 > 既にある `/etc/k3s-backup/env` > `env.age` の復号、の順に見る。
本番サーバの上でやるなら `sudo cat /etc/k3s-backup/env` をそのまま VM に流し込めば済み、パスフレーズは要らない
(中身は `env.age` と同じもの)。

## 結果(2026-09-07 その 2、NetBird / bootstrap の Actions 化のあと)

**新しく見つかったこと: Gateway の nodePort が 80/443 で戻らない。**

```
復元後: cilium-gateway-doany  80:31024/TCP,443:30229/TCP
本番  : cilium-gateway-doany  80:80/TCP,443:443/TCP
```

Cilium の Gateway コントローラが Service を作り直すので、**ノードの IP 経由の公開 Web が全部死ぬ**。
本番の 80/443 は手で当てた値で、**git にも `CiliumGatewayClassConfig` にも書けない**
(`spec.service` に nodePort の項目が無い ── `allocateLoadBalancerNodePorts` や
`externalTrafficPolicy` はあるが、ポート番号の指定は無い)。
`restore.sh` が復元の最後に当て直すようにした。

**2026-09-08 追記。** #91 で Gateway を hostNetwork にしたとき、「Envoy がホストの
80/443 を直接 bind するので当て直しは要らない」と判断して `restore.sh` から消した。
**これは誤りで、戻した。** Envoy は確かに `0.0.0.0:80` を LISTEN しているが、
そのソケットに直接来た接続は通らない ── 実通信は Cilium の L7LB リダイレクト
(`cilium-dbg bpf lb list` の `[NodePort, l7-load-balancer]`)を経由して Envoy に入る。
本番で port-80 の nodePort だけ 30080 に振り直して確かめた:

```
外部 http  → 000    外部 https → 401(無事)
LAN(Pod から 10.10.0.4:80)→ 000
ホスト(127.0.0.1 / 10.0.0.2 / 10.10.0.4 の :80)→ 000
ss: 0.0.0.0:80 は cilium-envoy が LISTEN したまま
```

**それ以外は健全**(44 Running / 12 Completed、Gateway・LB-IPAM・15 本のルートが戻り、全 Application が `Synced`)。
起動しなかったのは PT3 の無い `denpa/tuner-agent` と、9/6 のスナップショットより git が先に進んでいたぶん(NetBird など)だけ。

## 結果(2026-09-07、Cilium 1.20.1 + Gateway API)

3 回目。CNI を Cilium に、入口を Gateway API に替えて初めて通した(スナップショット `df3ca7eb`、16 GiB。k3s 起動まで約 5 分、
落ち着くまで約 16 分でほとんどがイメージの pull)。**確かめたかった 3 つはすべて Yes、手当ては要らなかった**:
Cilium は自力で上がる(CNI の設定を k3s 起動の 40 秒後に書く。鶏卵にならない)、Gateway は再起動なしで `Programmed=True`、
AdGuard の hostPort も張られる(**`ss` には出ない**。eBPF なので `cilium-dbg service list` で見る)。
47 Running / 15 Completed、PVC・`InfisicalSecret`・データも戻った。本番の restic リポジトリは開始前と同一のまま。
新しく見つかったのは **Argo CD の app-of-apps が CRD 待ちで丸ごと止まる**こと(下の表)。

## 結果(2026-09-06、flannel + kube-proxy + ServiceLB + Traefik の頃)

**過去の記録。** 2 回実施し、1 回目で下の表の 4 件が見つかり、**2 回目で全項目クリア**(7 GiB を 2 分弱で復元、45 Running / 17 Completed)。

## 見つかったことと対処(3 回ぶん)

| いつ | 見つかったこと | 原因 | 対処 |
| --- | --- | --- | --- |
| 09-06 | Deployment が全部 `replicas: 0` で戻る | state.db を scale down の**後**に取っていた | 取る順序を入れ替えた(`backup/k3s-backup`) |
| 09-06 | 復元直後に名前解決が死ぬ | AdGuard の :53 に endpoint が無い間、ローカル宛 53 が REJECT され systemd-resolved のスタブが巻き込まれる | `restore.sh` が `/etc/resolv.conf` をスタブから外す(Cilium でも要る) |
| 09-06 | Secret が 4 つ消える | Infisical operator が tracking-id を Secret にコピーし、**Argo CD が prune していた** | Secret を Argo CD の管理対象から外した(今は `InfisicalSecret` に `Prune=false`。[bootstrap/README.md](../bootstrap/README.md)) |
| 09-06 | Infisical が起動しない | 起動時の SMTP 接続検証が通るまで HTTP を listen しない | 遮断は DROP ではなく **REJECT**(上の「遮断」) |
| 09-07 | **Argo CD の app-of-apps が CRD 待ちで丸ごと止まる**(子 Application が 11/16 で止まる) | k8up の CRD を入れる Application が同じ同期の中にいる。CRD を入れても自動同期は再開しない(API リソース一覧のキャッシュ) | `SkipDryRunOnMissingResource=true`([../apps/k8up/README.md](../apps/k8up/README.md)「CRD がまだ無いクラスタで apps を止めないこと」) |
| 09-07 | operator が `secret "k8up-global" not found` | git に無い Secret | `restore.sh` が作り直す(リハーサルモードでは作らない) |
| 09-07 その 2 | Gateway の nodePort が 80/443 で戻らない | 上の「結果(2026-09-07 その 2)」 | `restore.sh` が最後に当て直す |

**「git がバックアップより進んでいる」状態は復元では普通に起きる。** どの回も、起動しなかったものの多くはスナップショットが古いことの表れだった。

## 片付け

VM の中で `k3s kubectl` を叩けば本物と同じ構成が動いているので、データの中身を確かめたいときはここで。終わったら落とす。

```shell
sudo kill $(sudo cat /var/tmp/restore-drill/qemu.pid); sudo rm -rf /var/tmp/restore-drill
```

最後に**ホスト側で** restic のスナップショットを数え直し、開始前と同じであることを確かめる。
