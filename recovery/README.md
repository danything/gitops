# recovery

**ノード `main` をまっさらから建て直す入口。** git と restic(Cloudflare R2)だけで戻す。
2026-10-17 に実機でこの順に建て直した(そのときの姿が今の本番)。
秘密は暗号化してあるので、この repo は公開のままでよい。

| | |
| --- | --- |
| `env.age` | バックアップ先の資格情報(R2 の鍵、restic のパスワード)。age のパスフレーズで暗号化 |
| `sops-age.key.age` | `bootstrap/` の SOPS ファイルを復号する age 秘密鍵(管理者の鍵。`deploy/` の SopsSecret も開ける)。**同じパスフレーズ**で暗号化 |
| [backup-all.sh](backup-all.sh) | 入れ直す前に全部の PVC を今すぐ取る道具(戻すのは populator。下の 6) |

**秘密のために復元ですることは無い。** アプリの秘密は git の SOPS(各 `deploy/` の `secrets.sops.yaml`)にあり、
クラスタの中で復号する鍵は machine config([../bootstrap/sops-age.sops.yaml](../bootstrap/sops-age.sops.yaml))が入れる。

**populator で戻す形(6)は、この形ではまだ入れ直して流していない。** 次の建て直しで最初に確かめる(VolSync の populator が OpenEBS LVM のスナップショットから PVC を作れることは、machine config の PR ごとの QEMU の起動テストで見ている)。

**手動のリハーサルは回さない。** 中身は月次の [restore-check](../deploy/backup/restore-check.yaml)、machine config は
[talos-boot](../.github/workflows/talos-boot.yml) が確かめる。残るのはこの手順書の通し(道具そのもの)だけ。

手で持つのは **age のパスフレーズ 1 つだけ**。GitHub へのログインは要らない
(置き場の考え方は [../docs/decisions.md](../docs/decisions.md)「そのパスフレーズをどこに置くか」)。
**この 2 ファイルは紙にも刷っておく** ── リポジトリが読めることは前提にしている。
base64 で `env.age` が 12 行、`sops-age.key.age` が 7 行。

```shell
base64 recovery/env.age recovery/sops-age.key.age   # 印刷して封筒へ
```

`env.age` の中身は `KEY=値` の env ファイル(`RESTIC_REPOSITORY=s3:https://<account-id>.r2.cloudflarestorage.com/<bucket>`・
`RESTIC_PASSWORD`・`AWS_ACCESS_KEY_ID`・`AWS_SECRET_ACCESS_KEY`・`AWS_DEFAULT_REGION=auto`・`MATTERMOST_WEBHOOK`)。
値を入れ替えたら作り直してコミットする(`age -p -o recovery/env.age <env ファイル>`。同じ値は [../deploy/backup/secrets.sops.yaml](../deploy/backup/secrets.sops.yaml) にもある)。
復元の手順そのものには要らない(PVC は VolSync が SopsSecret の資格情報で戻す)。手元の restic で R2 を直接読むときに使う。

## 何で戻すか

| 層 | 何で戻すか |
| --- | --- |
| ホストの設定 | **machine config**。`bootstrap/render.sh` が repo から描く(`bootstrap/talos-secrets.sops.yaml` が同じなら同じクラスタ CA) |
| k8s オブジェクト | **git から Argo CD で再構築**。`bootstrap/` は machine config が当てる |
| 秘密 | **git の SOPS**(`SopsSecret`)。クラスタの鍵は machine config が入れ、sops-secrets-operator(Argo CD が入れる)が Secret にする |
| PV データ | **VolSync の populator**(PVC の `dataSourceRef` → 各アプリの `<pvc>-dst`。Argo CD が PVC を作ると埋まる) |

etcd のスナップショット(リポジトリ `<bucket>/etcd`、[../deploy/backup/etcd-snapshot.yaml](../deploy/backup/etcd-snapshot.yaml))は
git に無い状態まで一度に戻したいときの近道で、主経路ではない([../bootstrap/talos.md](../bootstrap/talos.md)「etcd スナップショットから戻す(近道)」)。

## 道具と経路

**コマンドは全部 `tools/t.ps1 --admin` で入ったコンテナのシェルで打つ**(`HOME` はリポジトリの `.home/` で、
age 鍵と restic の資格情報はそこに残る。ノードにシェルは無い)。**talosctl / kubectl の資格情報は t.ps1 が用意する** ──
talosconfig も管理者の kubeconfig も `bootstrap/talos-secrets.sops.yaml` の CA からその場で作る(ファイルでは持たない)
([../tools/README.md](../tools/README.md)「クラスタの資格情報」)。GitHub の操作(5)だけ手元の `gh`。

- **作業用 PC(J:COM 側の LAN)からは 10.10.0.4(eno1)にしか届かない**(10.0.0.2 は届かない。届かないときは Wi-Fi で 10.0 側につなぐ)。t.ps1 の行き先はそこに固定してある
- AMT(10.10.0.3)で電源と SOL(Talos のカーネルのコンソール)が使える。SOL に出るのは `console=ttyS0` の入った schematic で
  起動したときだけで、ISO の maintenance mode は出ない(ISO も同じ schematic で作れば出る)。**画面(KVM)は無い**ので、
  BIOS とブートメニューは Arc にモニタとキーボードをつなぐ([../ROADMAP.md](../ROADMAP.md)「AMT」)
- **GitHub Actions では代わりにならない。** Talos の API(50000)はノードの受信の防火壁(Cilium の Host Firewall)でプライベートのアドレスからしか通さず
  ([../docs/router.md](../docs/router.md)「外からの転送」。maintenance mode では防火壁が無い)、CI の OIDC の信頼も
  machine config を当てて初めてできる

## 1. 鍵を開いて machine config を描く

```shell
mkdir -p ~/.config/sops/age && age -d -o ~/.config/sops/age/keys.txt recovery/sops-age.key.age   # パスフレーズ
./bootstrap/render.sh /dev/shm/c && rm -rf /dev/shm/c   # 描けるかだけ見る。`valid for metal mode` まで出ること
```

- **`bootstrap/talos-secrets.sops.yaml` を作り直さない。** 作り直すと別のクラスタ CA になり、`bootstrap/apiserver-ca.crt` が合わなくなる
- **描いたものは手元に置かない**(秘密が平文で入る)。当てるときは 3 の `apply.sh` がその場で描いて消す
- 版は [../bootstrap/talos.sops.yaml](../bootstrap/talos.sops.yaml) の先頭のコメント。**上げるなら建て直しの日ではない日に**

## 2. ISO で起動する

ISO は Image Factory のもの(URL の schematic と版は `talos.sops.yaml` の先頭と揃える)。ハイブリッドなのでそのまま書けばよい
(Windows なら Rufus の **DD イメージモード**。WSL からは USB が見えない)。

```shell
curl -LO https://factory.talos.dev/image/96371c8f956f7f5f9d09925bb49fe096c0cad05c5cf5bdb464790982c0b067ca/v1.15.0-alpha.2/metal-amd64.iso
```

- ISO の schematic は気にしなくてよい。ディスクに書かれるのは machine config の `--install-image`
- **Secure Boot が Disabled**(RBSU は POST 中に F9 → Server Security → Secure Boot Settings)。Boot Mode は UEFI のまま
- POST 中に **F11** で USB を選ぶ(Z440 は USB から UEFI で起動できず、DVD に焼く。AMT の IDE-R で ISO をつなぐのは未確認)
- コンソールに maintenance mode の IP が出る。インタフェースが `eno1` / `eno2` / `eno4`、インストール先が `/dev/sda`(447 GB)であること
  (違ったら `bootstrap/talos.sops.yaml` を直して 1 に戻る。**`diskSelector` の先は書いたら消える**):

```shell
IP=<コンソールに出た IP>
talosctl get links --insecure -n $IP -e $IP
talosctl get disks --insecure -n $IP -e $IP
```

## 3. 当てる(インストールは無人で進む)

```shell
./bootstrap/apply.sh --insecure -n $IP -e $IP     # 描いて当てる(描いたものは /dev/shm に置いて消す)
```

`UnattendedInstallConfig` があるので、ディスクに書いて自分で再起動する。**ここで SSD が上書きされる。**
`STATE` / `EPHEMERAL` / `r-lvm`(PV 用。VG `data` になる)が `ready` になったら USB を抜いてよい(挿したままだとブート順によっては
また maintenance mode で上がる):

```shell
talosctl get volumestatus    # EPHEMERAL は 64GiB 上限。違ったら入れ直すしかない
```

## 4. クラスタを起こす

```shell
talosctl bootstrap         # 単一ノードなので 1 回だけ
kubectl get nodes          # Ready / control-plane / talos.sops.yaml の先頭の kubernetes の版
kubectl get pods -A        # cilium・coredns・lvm-thinpool・lvm-localpv・snapshot-controller・argocd・cert-manager が Running
kubectl -n kube-system logs ds/lvm-thinpool -c pool   # 最後に data_thinpool(VG の 90%)が出る。出なければ PVC が 1 つも bind しない
kubectl get gatewayclass   # cilium が Accepted(無いと Gateway が `Waiting for controller` のまま)
```

`talosctl kubeconfig` は使わない(取り消せない 1 年の証明書が呼ぶたびに出る)。t.ps1 が `talos-secrets.sops.yaml` の CA でその場で作る。

## 5. Gateway・auth などが入るのを見る(ArgoCD)

手ですることは無い。ArgoCD の `gitops` の Application([../bootstrap/argocd-repos.yaml](../bootstrap/argocd-repos.yaml) の ApplicationSet が作る)が `deploy/` の
`ClusterIssuer`・Gateway・auth・sops-secrets-operator と各 namespace の `SopsSecret` を当てる。

```shell
kubectl -n argocd get application gitops       # SopsSecret の CRD が来るまでは何度か落ちて retry で戻る
kubectl get sopssecrets -A                      # STATUS が全部 Healthy(Secret ができた)
kubectl get certificate -A                      # Gateway に証明書が付く
```

Argo CD はこの間に `deploy/` の残りと各リポジトリの `deploy/` も同期しはじめる。**PVC の中身は 6 で埋まる**まで、
PVC を待つアプリと、Forgejo から来る非公開アプリ(`repos-forgejo` が `ErrorOccurred`)は上がらない。想定どおり。

## 6. PV データを戻す(VolSync の populator。待つだけ)

**何も打たない。** 各アプリの PVC は `dataSourceRef` で ReplicationDestination(各アプリの `volsync.yaml` の `<pvc>-dst`)を指している。
Argo CD が PVC を作ると、VolSync(volume populator)が R2 の `<bucket>/volsync/<ns>/<pvc>` の最新を一時的なボリュームに戻し、
そのスナップショットから PVC を作ってから渡す。PVC は埋まるまで `Pending` で、アプリの Pod は空の PVC では起きない。

- **順番は勝手にそろう。** RD が使う Secret(`volsync-<pvc>`)は SopsSecret から来るので、sops-secrets-operator が作るまで RD は失敗してやり直す(PVC は `Pending` のまま)。
  Forgejo の PVC は gitops にあるので先に埋まり、非公開アプリ(マニフェストもイメージも Forgejo)はそのあとに出てきて埋まる
- **空の PVC を取ることはない。** ReplicationSource は PVC が埋まるまでスナップショットを取れないので、戻す前の空の中身が「いちばん新しい」にならない
- **Postgres・SQLite・Tuwunel(RocksDB)もファイルのまま戻る。** スナップショットから取っているので crash-consistent で、起きるときに自分で立ち直る
- denpa-raw は取っていないので空で作る
- **バックアップがまだ無い PVC**(足したばかりのアプリ)は、リポジトリが空なので空のまま作る
- 見るところ: `kubectl get pvc -A`(`Pending` が残っていないか)と `kubectl get replicationdestination -A`(`<pvc>-dst` の `latestMoverStatus`)

今あるクラスタで PVC を戻すとき(消した・壊した)も同じ仕組みを使う。`<pvc>-dst` に戻したい時刻を入れて戻し直させ、PVC を消して Argo CD に作り直させる
(`<pvc>-dst` は作られたときの中身を持ち続けるので、戻し直させないと古い中身で埋まる。`WHEN` を今にすれば最新):

```shell
NS=xool PVC=xool-db WHEN=2026-11-01T00:00:00Z
kubectl -n $NS patch replicationdestination $PVC-dst --type merge \
  -p "{\"spec\":{\"trigger\":{\"manual\":\"r-$(date +%s)\"},\"restic\":{\"restoreAsOf\":\"$WHEN\"}}}"
kubectl -n $NS get replicationdestination $PVC-dst -w   # latestImage が変わる(latestMoverStatus が Successful)まで待つ
kubectl -n argocd scale sts/argocd-application-controller --replicas=0   # selfHeal が replicas を戻さないように
kubectl -n $NS scale deploy,sts --all --replicas=0
kubectl -n $NS delete pvc $PVC
kubectl -n argocd scale sts/argocd-application-controller --replicas=1   # PVC と replicas が戻り、PVC は <pvc>-dst から埋まる
```

- **入れ直す前は最後に全部取る**(`tools/t.ps1 --admin sh recovery/backup-all.sh`。終わると `manual` を消して Argo CD を戻す)
- **R2 にあるもの**は R2 の画面か `restic -r <bucket>/volsync/<ns>/<pvc> snapshots`。取るのをやめて PVC だけ残したものはリポジトリを消しておく
- **PVC の requests が本当の上限**(OpenEBS LVM)。中身が PVC より大きくなっていると埋められない。PVC を大きくしてから作り直す
- **k8up の頃のリポジトリ**(バケットの根)は 2026-11-01 に消した。2026-11-01 より前のものは戻せない

## 7. 確かめる

公開している名前を全部叩く(作業用 PC のコンテナから。ノードの上からは 80/443 に届かない)。

```shell
kubectl get httproute,grpcroute -A -o jsonpath='{range .items[*]}{range .spec.hostnames[*]}{@}{"\n"}{end}{end}' \
  | grep -v '^\*' | sort -u | while read h; do
      printf '%-24s %s\n' "$h" "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$h/" 2>/dev/null || echo ERR)"
    done
```

| | |
| --- | --- |
| 200 | 大半 |
| **302** | `a` / `ah` / `hl` ── oauth2-proxy が Entra へ飛ばしている |
| **401** | `dp` ── **これが正しい。** 公開側から来た通信を denpa が弾いている。200 なら X-Forwarded-For が壊れていて住所判定が効いていない |
| ERR | `dp.l.doany.io` ── 宅内専用の名前。AdGuard を引く端末からしか通らない |

- [ ] `kubectl -n argocd get applications` が全部 Synced / Healthy、`kubectl get sopssecrets -A` が全部 Healthy
- [ ] `talosctl get links bond0` の MAC が **`e6:2c:1b:1a:a0:39`**(ルーターの IPv6 ホスト公開がこの MAC を指す。[../docs/router.md](../docs/router.md))
- [ ] **別の回線の IPv6 だけで 443 に届く。** J:COM 側の PC から `curl -6 -so /dev/null -w "%{http_code} %{remote_ip}\n" https://fj.doany.io/` で
      `200 240f:6d:842b:1::2`(アドレス直打ちは SNI が無く Gateway が切るので駄目)
- [ ] DNS の AAAA が `::2`(SLAAC のアドレスではない)。`talosctl get addresses` を起動直後・数分後・再起動後に見る
      (sysctl より先に RA が届くと SLAAC が一度付いて残りうる)
- [ ] `talosctl get routes -o yaml | grep -B10 'protocol: ra'` に `dst: ""`(IPv6 の既定経路)が残っている
- [ ] netbird で外から VPN に入れる(ブラウザでは確かめられない)、AdGuard(`dig @10.10.0.4 example.com`)
- [ ] **PT3**: `talosctl ls /dev/dvb` に adapter0〜3 と各 `frontend0`、`talosctl ls /dev/bus/usb` に B-CAS リーダー、録画が動く
- [ ] Renovate の CronJob が次の回で動く(`kubectl -n renovate get jobs`)、バックアップの通知(deploy/backup/notify.yaml)が翌日 OK ✅
- [ ] etcd のスナップショットを 1 回手で取る(`kubectl -n backup create job --from=cronjob/etcd-snapshot etcd-snapshot-first`)

## 8. 後始末

```shell
rm -f ~/.config/restic.env   # env.age を開いて手元の restic を使ったとき
```

## 詰まったときに見るところ

| | |
| --- | --- |
| ノードが上がらない | AMT の SOL(インストール済みのノードのカーネルのコンソール)。ダッシュボード(版と健全性)は Arc につないだモニタ |
| Pod が Pending | **PSA のラベル**([../bootstrap/talos.md](../bootstrap/talos.md)「PSA のラベル」)か、control-plane の taint |
| PVC が Bound しない | `kubectl -n kube-system logs ds/lvm-thinpool -c pool`(VG `data` が無い = `talosctl get volumestatus` の `r-lvm`)、ノードに `doany.io/lvm-thinpool=ready` が付いて `lvm-localpv-node` が動いているか、`kubectl -n kube-system logs ds/lvm-localpv-node -c openebs-lvm-plugin` |
| 非公開イメージが引けない | `bootstrap/talos.sops.yaml` の fj.doany.io の `password` が machine config に入っているか、Forgejo が戻っているか(6) |
| cilium-drift が TLS で落ちる | `talos-secrets.sops.yaml` を作り直した。`bootstrap/apiserver-ca.crt` を新しい `talos-secrets.sops.yaml` の Kubernetes の CA(`certs.k8s.crt` を base64 で戻したもの)にする |
| Application が `OutOfSync / Missing` のまま | `retry`(約 33 分)で自力で戻る。30 分以上動かなければ `kubectl -n argocd patch application <名前> --type=merge -p '{"operation":{"sync":{"revision":"HEAD"},"initiatedBy":{"username":"me"}}}'`。**chart のものは `HEAD` ではなく `spec.source.targetRevision` の値** |
| inlineManifest を直したのに効かない | `apply.sh` → **`upgrade-k8s`**([../bootstrap/talos.md](../bootstrap/talos.md)「当て方」) |
