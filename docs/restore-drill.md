# 復元リハーサル(サーバ上の QEMU/KVM で)

Hyper-V は WSL から管理者権限で触れないので、本番サーバ(46 GB RAM、VT-x)の上に QEMU/KVM で Ubuntu の VM を立てて、
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

**それ以外は健全。** 44 Running / 12 Completed、Gateway は `Accepted=True Programmed=True` で
LB-IPAM の `10.10.0.53` も 15 本のルートも戻った。全 Application が `Synced`。

起動しなかったものは、**どれもスナップショットが古いことの表れ**で欠陥ではない
(このリハーサルは 9/6 のスナップショットに対して行った):

| | |
| --- | --- |
| `denpa/tuner-agent` | PT3 が無い。VM では毎回こうなる |
| `netbird/*` | **9/6 の時点で NetBird は存在しない。** git だけが先に進んでいるので Pod は作られるが、Infisical 側に Secret が無く `CreateContainerConfigError` |
| `erpnext`(いまは撤去)の socketio と worker | `ENOTFOUND erpnext-dragonfly-queue`。chart の版と、スナップショットの Service 名が食い違っていた |
| `k8up` | リハーサルの手当てで `k8up-global` を消しているため。意図どおり |

**「git がバックアップより進んでいる」状態は復元では普通に起きる**、を改めて確認した形になった。

## 結果(2026-09-07、Cilium 1.20.1 + Gateway API)

3 回目。CNI を Cilium(kubeProxyReplacement / LB-IPAM / L2 アナウンス)に、入口を Gateway API に替えたあと、
初めて通した。**確かめたかった 3 つはすべて Yes。手当ては何も要らなかった。**

戻したのはスナップショット `df3ca7eb`(2026-09-06 19:11 UTC、15.954 GiB)。Cilium と Gateway への移行後のもの。
`restore.sh` 開始 05:56:28 → k3s 起動 06:01:48 → 全 Pod が落ち着くまで 06:12 ごろ。イメージの pull がほとんどの時間。

| 確かめたこと | 結果 | 根拠 |
| --- | --- | --- |
| **Cilium が自力で上がるか** | **上がる。鶏卵にならない** | k3s 起動時点(06:01:44)で `/etc/cni/net.d/` は空。cilium エージェントが 06:02:28 に `05-cilium.conflist` を書き(`Wrote CNI configuration file`)、kubelet の `cni plugin not initialized` がそこで解消。k3s 起動の 40 秒後。`cilium-dbg status` は `KubeProxyReplacement: True` / `Cilium: Ok 1.20.1` / `Cluster health: 1/1 reachable` |
| **Gateway が戻るか** | **戻る。エージェントの再起動は要らない** | `kube-system/doany` が `PROGRAMMED=True`・`10.10.0.53`。リスナー 3 本(`https` 15 route / `https-apex` 1 / `http` 1)すべて Accepted + ResolvedRefs + Programmed。LB-IPAM は 4 本の LoadBalancer に `10.10.0.50`〜`.53` を払い出し、`cilium-l2announce-*` の Lease 4 本を `main` が保持 |
| **AdGuard の hostPort が張られるか** | **張られる** | `cilium-dbg service list` に HostPort のフロントエンドが 14 本(v4/v6 両方)。AdGuard は `0.0.0.0:53/UDP`・`:53/TCP`・`:853/TCP` → `10.42.0.19`。`dig @<ノード IP> example.com` が UDP でも TCP でも答えた |

移行のときに要った「ConfigMap を書いてから cilium エージェントを再起動する」「hostPort を有効にして Pod を作り直す」は、
**機能を有効にするための一度きりの手当て**だった。復元では DaemonSet と Helm のリリース Secret ごと戻るので初回で決まる。

**hostPort は `ss` に出ない。** Cilium は eBPF で張るのでソケットが存在しない。見るなら
`kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status` と `cilium-dbg service list`。

一般の健全性(復元しただけで、まだ何も手を入れていない状態):

- **47 Running / 15 Completed。** 起動しなかったのは前回と同じ 2 つだけで、どちらも VM の都合。
  `denpa/tuner-agent`(hostPath の `/dev/dvb`・`/dev/bus` が無い = PT3 が無い)と
  `wireguard/wg-easy`(PostStartHook がカーネルの wireguard モジュールを見つけられない)。
- PVC 23 件すべて Bound。PV 25 件の `nodeAffinity` はすべて `main`。
- `InfisicalSecret` 13 件すべて OK(本番も同時点で 13 件)。Infisical 本体も上がった。
- データも戻っている(当時の Mattermost の `posts` が 9832 行。本番は 10593 行で、スナップショットが 11 時間前なので妥当)。
- 遮断は全部効いた(上の「Cilium にしても〜」)。

### 新しく見つかったこと: **Argo CD の app-of-apps が CRD 待ちで丸ごと止まる**(対処済み)

```
Failed | one or more synchronization tasks are not valid:
  failed to discover server resources for group version k8up.io/v1:
  the server could not find the requested resource (retried 5 times)
```

git には `k8up.io/v1` の `Schedule` があるのに、復元したクラスタに k8up の CRD が無い。CRD を入れる当の
Application(`apps/k8up/`)が同じ同期に含まれているので抜けられず、子 Application が 5 つ作られないまま
**11 個**(本番は 16 個)で止まった。戻したスナップショット(09-06 19:11)が k8up の導入(09-07 02:30 ごろ)より
古かったせいでもあるが、**「git がバックアップより進んでいる」状態は復元では普通に起きる。**
対処(`SkipDryRunOnMissingResource=true`)と理由は [../apps/k8up/README.md](../apps/k8up/README.md)
「CRD がまだ無いクラスタで apps を止めないこと」。

- 手で CRD を入れて同期をかけ直すと `successfully synced (all tasks run)` になった。**原因はこれで確定**
- **CRD を入れただけでは自動同期は再開しない。** Argo CD は API リソース一覧をキャッシュしていて、
  application-controller の再起動でも戻らなかった。`Application` に `operation` を書いて同期を起こす必要があった
- 同期を通したあと、operator が `Error: secret "k8up-global" not found` で止まった(git に無いため)。
  いまは `restore.sh` が作り直す(リハーサルモードでは作らない)

このリハーサルは **`Schedule` を消し、R2 を iptables で塞ぎ、operator が起動できない**の 3 段構えにした。
本番の restic リポジトリは**開始前と完全に同一**(7 スナップショット、ID もサイズも一致)で終わった。

### 細かい差分(どれも問題ではない)

- スナップショットに移行途中の `traefik` DaemonSet と Pod、`traefik` の LoadBalancer Service が残っていて、
  復元したクラスタでは Traefik が hostPort 80/443 を掴んだ。Gateway は LoadBalancer(`10.10.0.53`)なので衝突しない。
  本番ではその後に消してある。
- `3proxy` の TLS サイドカーはスナップショット時点で hostPort 8443、いまの git は 3129。同期を通せば追いつく。

## 結果(2026-09-06、flannel + kube-proxy + ServiceLB + Traefik の頃)

**過去の記録。** CNI が flannel、入口が Traefik の頃に 2 回実施し、**2 回目で全項目クリア。**
復元は 7 GiB を 2 分弱、k3s は同じバージョンで起動し、PV も Node 名もそのまま戻った。

1 回目で見つかった 4 件と、その対処:

| 見つかったこと | 原因 | 対処 |
| --- | --- | --- |
| Deployment が全部 `replicas: 0` で戻る | state.db のスナップショットを scale down の**後**に取っていた | 取る順序を入れ替えた(`backup/k3s-backup`)。git 管理外の Infisical が上がらず気付いた |
| 復元直後に名前解決が死ぬ | AdGuard の LoadBalancer(:53)に endpoint が無い間、kube-proxy がローカル宛 53 を REJECT し、systemd-resolved のスタブが巻き込まれる | `restore.sh` が `/etc/resolv.conf` をスタブから外す |
| Secret が 4 つ消える | **Argo CD が prune していた**。Infisical operator が CR の annotation(tracking-id 含む)を Secret にコピーするため、Argo CD が「git に無い管理対象」と誤認する | Argo CD の `resource.exclusions` で Secret を管理対象から外した |
| Infisical が起動しない | 起動時の SMTP 接続検証が通るまで HTTP を listen しない | 遮断するなら DROP ではなく **REJECT** で即座に落とす |

2 回目ではいずれも再発せず、消えていた Secret も全部残っていた(Argo CD が犯人だったことがこれで確定)。
結果は 45 Running / 17 Completed、`InfisicalSecret` 15 件すべて OK。起動しなかった 2 つはどちらも VM の都合で、
`denpa/tuner-agent`(PT3 が無い)と `wireguard/wg-easy`(カーネルに wireguard モジュールが無い)。

この 4 件は 2026-09-07 の Cilium 構成でも**再発していない**。`/etc/resolv.conf` の件は
kube-proxy が Cilium の kubeProxyReplacement に替わっても同じことが起きるので、`restore.sh` の手当てはそのまま要る。

## 片付け

VM の中で `k3s kubectl` を叩けば本物と同じ構成が動いているので、データの中身を確かめたいときはここで。終わったら落とす。

```shell
sudo kill $(sudo cat /var/tmp/restore-drill/qemu.pid); sudo rm -rf /var/tmp/restore-drill
```

最後に**ホスト側で** restic のスナップショットを数え直し、開始前と同じであることを確かめる。
