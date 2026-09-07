# 復元リハーサル(サーバ上の QEMU/KVM で)

Hyper-V は WSL から管理者権限で触れないので、本番サーバ(46 GB RAM、VT-x)の上に QEMU/KVM で Ubuntu の VM を立てて、
そこに `recovery/` の `restore.sh` を `RESTORE_DRILL=1` で流す。初回 2026-09-06。

## 副作用を出さないための遮断(VM の中で最初にやる)

復元されたクラスタは本物と同じ設定で立ち上がるので、そのままだと cloudflare-ddns が DNS を書き換え、cert-manager が ACME を叩き、
ArgoCD が Mattermost に通知し、Infisical がメールを出す。raw テーブルで先に落とす(k3s が後から入れる FORWARD のルールより先に評価される)。

```shell
# api.cloudflare.com / acme-v02.api.letsencrypt.org / 本番の公開 IP(mm.doany.io, il.doany.io)。IP は VM の中で getent で引き直す
for ip in 104.19.192.174 104.19.192.175 104.19.192.176 104.19.192.177 104.19.192.29 104.19.193.29 172.65.32.248 59.140.229.91; do
  sudo iptables -t raw -I PREROUTING -d $ip -j DROP; sudo iptables -t raw -I OUTPUT -d $ip -j DROP
done
for p in 587 465; do sudo iptables -t raw -I PREROUTING -p tcp --dport $p -j DROP; sudo iptables -t raw -I OUTPUT -p tcp --dport $p -j DROP; done
# QEMU の user-mode network は IPv6 も外に出せるので、グローバル宛は全部落とす(R2 も k3s も IPv4 で足りる)
sudo ip6tables -t raw -I OUTPUT -d 2000::/3 -j DROP; sudo ip6tables -t raw -I PREROUTING -d 2000::/3 -j DROP
```

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

`RESTORE_DRILL=1` がやること: bond0/eno4 のプロファイルを当てない、k3s の `flannel-iface` を外す、`k3s-backup.timer` を有効にしない
(VM のスナップショットを本番の restic リポジトリに混ぜない)。

## **この記録は Cilium 移行前のもの(要再実施)**

2 回のリハーサルはどちらも **flannel + kube-proxy + ServiceLB + Traefik の頃**のもので、
その後(2026-09-06〜07)に CNI を Cilium へ、入口を Gateway API へ替えた。
**復元の道筋そのものは変わっていない**(state.db を戻せば Cilium の DaemonSet も
Helm のリリース Secret も一緒に戻り、Cilium は hostNetwork なので CNI 無しで起動できる)が、
**実際に通したことはまだ無い。**

確かめたいのは次の 3 つ。

- 復元した k3s(`flannel-backend: none` + `disable-kube-proxy`)で **Cilium が自力で上がるか**。
  CNI の設定ファイルは cilium エージェントが起動時に書くので、鶏卵にはならないはず
- **Gateway が戻るか**。LB-IPAM の払い出しと L2 アナウンスはエージェントの再起動が要るので、
  復元直後に一度で決まるかどうか
- **AdGuard の hostPort が張られるか**。Cilium の hostPort は Pod のサンドボックス作成時に設定される

`RESTORE_DRILL=1` は flannel-iface を落とす処理を持っていたが、その行はもう config.yaml に無いので
削除した(2026-09-07)。VM でも実機でも同じ設定で通る。

## 結果(2026-09-06、flannel の頃)

サーバ上の QEMU/KVM(Ubuntu 26.04 cloud image、4 vCPU / 8 GB、hostname は `main`)で 2 回実施した。
**2 回目で全項目クリア。** 復元は 7 GiB を 2 分弱、k3s は同じバージョンで起動し、PV も Node 名もそのまま戻る。

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

## 片付け

VM の中で `k3s kubectl` を叩けば本物と同じ構成が動いているので、データの中身(Mattermost の投稿数、
ERPNext の DB 一覧など)を確かめたいときはここで。終わったら落とす。

```shell
sudo kill $(cat /var/tmp/restore-drill/qemu.pid); sudo rm -rf /var/tmp/restore-drill
```
