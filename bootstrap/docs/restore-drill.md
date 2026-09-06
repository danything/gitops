# 復元リハーサル(サーバ上の QEMU/KVM で)

Hyper-V は WSL から管理者権限で触れないので、本番サーバ(46 GB RAM、VT-x)の上に QEMU/KVM で Ubuntu の VM を立てて、
そこに `recovery/` の `restore.sh` を `RESTORE_DRILL=1` で流す。初回 2026-09-06。

## 副作用を出さないための遮断(VM の中で最初にやる)

復元されたクラスタは本物と同じ設定で立ち上がるので、そのままだと cloudflare-ddns が DNS を書き換え、Traefik が ACME を叩き、
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

## 片付け

```shell
sudo kill $(cat /var/tmp/restore-drill/qemu.pid); sudo rm -rf /var/tmp/restore-drill
```

## 2026-09-06 の結果

サーバ上の QEMU/KVM(Ubuntu 26.04 cloud image、4 vCPU / 8 GB、hostname `main`)。スナップショットは 09:06 の 7.45 GiB。

| 項目 | 結果 |
| --- | --- |
| restic restore(R2 → VM、slirp 経由) | 1 分 43 秒 |
| k3s | 同じ v1.36.2+k3s1 が入り、Node `main`(62d)として Ready。PV 23 個 Bound |
| 遮断 | Cloudflare API / LE / 本番 IP / SMTP / IPv6 は落ちたまま。DNS 書き換え・証明書発行・通知は出ていない |
| 見つかった問題 | 下記 3 件。1 と 2 は直した |

1. **state.db に replicas=0 が焼き込まれていた。** backup.sh が scale down の後にスナップショットを取っていたため。
   git 管理のものは ArgoCD の selfHeal が戻すが、手で apply した Infisical(HelmChart)は 0 のまま。
   → スナップショットを scale down の前に取るよう修正(bootstrap `5717b28`)。修正後の最初のスナップショットは翌 04:00 JST。
   それ以前のスナップショットから戻す場合は `kubectl -n infisical scale deploy/infisical sts/postgresql sts/redis-master --replicas=1` を手で。
2. **復元直後に名前解決が死ぬ。** AdGuard の LoadBalancer(:53)に endpoint が無い間、kube-proxy が `--dst-type LOCAL --dport 53` を REJECT し、
   systemd-resolved のスタブ(127.0.0.53)が巻き込まれる。containerd がレジストリを引けず、AdGuard 自身も上がれない。
   → restore.sh で `/etc/resolv.conf` をスタブから `/run/systemd/resolve/resolv.conf` に差し替え(recovery `d9ed258`)。
3. **Infisical operator が作った Secret を ArgoCD が prune する。** operator は InfisicalSecret CR の annotation を Secret にコピーするので、
   `argocd.argoproj.io/tracking-id` も付いてしまい、ArgoCD(v3.5)はその Secret を Application の資源として認識する
   (本番でも `status.resources` に `Secret mattermost/mattermost` などが載っている)。git には無いので、sync 操作が走ると prune される。
   本番では Infisical が生きているので operator がすぐ作り直して見えないが、復元直後は Infisical が落ちていて作り直せず、
   mattermost / xool / lgtm / wg-easy / cloudflare-ddns / erpnext が `CreateContainerConfigError` のまま止まった。
   kine の履歴でも、ArgoCD の一斉 sync(Ingress や Namespace の更新が並ぶ revision 帯)の中で削除されている。
   → **ArgoCD の `resource.exclusions` で Secret を管理対象から外した**(bootstrap `e787d70`、本番適用済み)。
   git に平文 Secret を置かない方針なので ArgoCD が Secret を作ることは無く、外して困らない。
   CR に `argocd.argoproj.io/sync-options: Prune=false` を付ける案(gitops #3)は、operator が annotation をコピーするのが
   Secret 作成時だけで既存の Secret には効かないため、単独では不十分だった(付けたままにしてある)。
4. **Infisical は起動時に SMTP 接続を検証し、届かないと HTTP を listen し始めない。** リハーサルでは私の遮断(587 を DROP)が原因で
   10 分以上 0/1 のままだった。本番の復元でも Exchange Online に届かない状況だと Infisical が上がらず、operator 製 Secret も戻らない。
   遮断するなら DROP ではなく REJECT(即座に失敗させる)。

5. **クラスタにしか無い Secret が復元後に消えた。** スナップショットには 70 個の Secret があったのに、
   復元 1 時間後のクラスタには 55 個しかなかった。差分 15 個のうち 11 個は Helm のリリース履歴
   (`sh.helm.release.v1.*` の v2 以降。v1 だけ残った)。残り 4 個のうち 3 個は **`InfisicalSecret` が無く、
   手で `kubectl apply` しただけの Secret** だった。

   | Secret | その後 | 対処 |
   | --- | --- | --- |
   | `wireguard/wg-easy-init` | 誰も作り直せず wg-easy が起動不能 | `apps/wireguard/wg-easy-secrets.yaml` で Infisical 管理に移した(値の投入は手作業) |
   | `wireguard/wg-easy-oidc` | 同上 | OIDC は Entra 側の仕様で元々使えないので Secret を作らない。Deployment の参照を `optional: true` にして、無くても起動するようにした |
   | `blog/artalk-secrets` | 同上 | **未使用**なので放置(消してもよい) |
   | `tamasagashi/ghcr-pull` | Infisical から作り直された | 対処不要(最初から `InfisicalSecret` があった) |

   Infisical operator が管理している Secret は、Infisical が上がった時点で全部作り直された(15 件すべて OK)。
   **消えたのは「git にも Infisical にも無く、クラスタにしか存在しない」ものだけ。** 犯人は特定できていない
   (Argo CD の sync 結果にもログにも出ておらず、kine のトムストーンは compaction で消えていた)。
   次回のリハーサル(`resource.exclusions` 適用後のスナップショット)で再現するか確かめる。

## 片付けの前に

VM の中で `k3s kubectl` を叩けば本物と同じ構成が動いている。データの中身(Mattermost の投稿数、ERPNext の DB 一覧など)を
見たいときはここで。終わったら QEMU を落として `/var/tmp/restore-drill` を消す。
