# recovery

**ノード `main` をまっさらから建て直す入口。** git と restic(Cloudflare R2)だけで戻す。
2026-10-17 に実機でこの順に建て直した(そのときの姿が今の本番)。
秘密は暗号化してあるので、この repo は公開のままでよい。

| | |
| --- | --- |
| `env.age` | バックアップ先の資格情報(R2 の鍵、restic のパスワード)。age のパスフレーズで暗号化 |
| `sops-age.key.age` | `bootstrap/` の SOPS ファイルを復号する age 秘密鍵。**同じパスフレーズ**で暗号化 |
| [pv.sh](pv.sh) | PV のデータを VolSync の `ReplicationDestination` で戻す道具(下の 8) |
| [infisical.sh](infisical.sh) / [infisical-ca.mjs](infisical-ca.mjs) | Infisical を restic から直接戻す道具(下の 6・7) |

**2 つの道具は、2026-10-17 に使ったものから決め打ちを外した形で、この形ではまだ流していない。** 次の建て直しで最初に確かめる(`pv.sh - plan-all` は 2026-10-20 に本番の restic と突き合わせて、全 namespace の判定が 8 の表どおりになるのを確かめた)。

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
値を入れ替えたら作り直してコミットする(`age -p -o recovery/env.age <env ファイル>`。同じ値は Infisical の `/k8up/k8up-global` にもある)。

## 何で戻すか

| 層 | 何で戻すか |
| --- | --- |
| ホストの設定 | **machine config**。`bootstrap/render.sh` が repo から描く(`bootstrap/talos-secrets.sops.yaml` が同じなら同じクラスタ CA) |
| k8s オブジェクト | **git から Argo CD で再構築**。`bootstrap/` は machine config が当てる |
| Infisical の DB | **VolSync の `ReplicationDestination`、Secret は手元の restic.env から**(ほかの Secret が Infisical から来るので。[infisical.sh](infisical.sh)) |
| ほかの PV データ | **VolSync の `ReplicationDestination`**([pv.sh](pv.sh)) |

etcd のスナップショット(リポジトリ `<bucket>/etcd`、[../deploy/backup/etcd-snapshot.yaml](../deploy/backup/etcd-snapshot.yaml))は
git に無い状態まで一度に戻したいときの近道で、主経路ではない([../docs/talos.md](../docs/talos.md)「etcd スナップショットからの復旧」)。

## 道具と経路

**コマンドは全部 `tools/t.ps1 --admin` で入ったコンテナのシェルで打つ**(`HOME` はリポジトリの `.home/` で、
age 鍵と restic の資格情報はそこに残る。ノードにシェルは無い)。**talosctl / kubectl の資格情報は t.ps1 が用意する** ──
talosconfig も管理者の kubeconfig も `bootstrap/talos-secrets.sops.yaml` の CA からその場で作る(ファイルでは持たない)
([../tools/README.md](../tools/README.md)「クラスタの資格情報」)。GitHub の操作(5)だけ手元の `gh`。

- **作業用 PC(J:COM 側の LAN)からは 10.10.0.4(eno4)にしか届かない**(10.0.0.2 は届かない)。t.ps1 の行き先はそこに固定してある
- iLO(10.0.0.3)の Remote Console(HTML5)で、ブートメニューも maintenance mode の IP も見える。USB だけ物理で挿す
- **GitHub Actions では代わりにならない。** Talos の API(50000)はノードの受信の防火壁(Cilium の Host Firewall)でプライベートのアドレスからしか通さず
  ([../docs/router.md](../docs/router.md)「外からの転送」。maintenance mode では防火壁が無い)、CI の OIDC の信頼も
  machine config を当てて初めてできる

## 1. 鍵を開いて machine config を描く

```shell
mkdir -p ~/.config/sops/age && age -d -o ~/.config/sops/age/keys.txt recovery/sops-age.key.age   # パスフレーズ
./bootstrap/render.sh bootstrap/clusterconfig       # `valid for metal mode` まで出ること
```

- **`bootstrap/talos-secrets.sops.yaml` を作り直さない。** 作り直すと別のクラスタ CA になり、`bootstrap/apiserver-ca.crt`・
  Infisical の Kubernetes auth(7)が合わなくなる
- **`render.sh` は出力先を丸ごと消して作り直す。** `bootstrap/clusterconfig/` に kubeconfig などを置いていたら消える
- 版は [../bootstrap/talos.sops.yaml](../bootstrap/talos.sops.yaml) の先頭のコメント。**上げるなら建て直しの日ではない日に**

## 2. ISO で起動する

ISO は Image Factory のもの(URL の schematic と版は `talos.sops.yaml` の先頭と揃える)。ハイブリッドなのでそのまま書けばよい
(Windows なら Rufus の **DD イメージモード**。WSL からは USB が見えない)。

```shell
curl -LO https://factory.talos.dev/image/96371c8f956f7f5f9d09925bb49fe096c0cad05c5cf5bdb464790982c0b067ca/v1.15.0-alpha.2/metal-amd64.iso
```

- ISO の schematic は気にしなくてよい。ディスクに書かれるのは machine config の `--install-image`
- **Secure Boot が Disabled**(RBSU は POST 中に F9 → Server Security → Secure Boot Settings)。Boot Mode は UEFI のまま
- POST 中に **F11** で USB を選ぶ(iLO の Virtual Media なら Image File CD-ROM/DVD に ISO の URL を貼り、Reset して F11)
- コンソールに maintenance mode の IP が出る。インタフェースが `eno1` / `eno2` / `eno4`、インストール先が `/dev/sda`(447 GB)であること
  (違ったら `bootstrap/talos.sops.yaml` を直して 1 に戻る。**`diskSelector` の先は書いたら消える**):

```shell
IP=<コンソールに出た IP>
talosctl get links --insecure -n $IP -e $IP
talosctl get disks --insecure -n $IP -e $IP
```

## 3. 当てる(インストールは無人で進む)

```shell
talosctl apply-config --insecure -n $IP -e $IP -f bootstrap/clusterconfig/controlplane.yaml
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
kubectl get pods -A        # cilium・coredns・lvm-thinpool・lvm-localpv・snapshot-controller・argocd・cert-manager・infisical が Running
kubectl -n kube-system logs ds/lvm-thinpool -c pool   # 最後に data_thinpool(VG の 90%)が出る。出なければ PVC が 1 つも bind しない
kubectl get gatewayclass   # cilium が Accepted(無いと Gateway が `Waiting for controller` のまま)
```

`talosctl kubeconfig` は使わない(取り消せない 1 年の証明書が呼ぶたびに出る)。t.ps1 が `talos-secrets.sops.yaml` の CA でその場で作る。

## 5. Gateway・auth などが入るのを見る(ArgoCD)

手ですることは無い。ArgoCD の `gitops` の Application([../bootstrap/argocd-repos.yaml](../bootstrap/argocd-repos.yaml) の ApplicationSet が作る)が `deploy/` の
`ClusterIssuer`・Gateway・auth・`InfisicalSecret` を当てる。

```shell
kubectl -n argocd get application gitops       # InfisicalSecret の CRD が来るまでは何度か落ちて retry で戻る
kubectl get certificate -A                      # Gateway に証明書が付く
```

Argo CD はこの間に `deploy/` の残りと各リポジトリの `deploy/` も同期しはじめる。**中身はまだ空**なので、
Infisical の Secret を待つアプリと、Forgejo から来る非公開アプリ(`repos-forgejo` が `ErrorOccurred`)は上がらない。想定どおり。

## 6. Infisical の DB を戻す

```shell
age -d -o ~/.config/restic.env recovery/env.age     # パスフレーズ。終わったら消す(10)
sh recovery/infisical.sh db      # users が 0 なら止まる
```

Infisical の Postgres の PVC(`data-postgresql-0`)を、VolSync のリポジトリ(`<bucket>/volsync/infisical/data-postgresql-0`)の
**このクラスタができる前の最新**のスナップショットで丸ごと置き換える([pv.sh](pv.sh) の `pvc` と同じ)。
VolSync の Secret はほかの namespace では Infisical から来るが、ここだけは戻すのが Infisical そのものなので、`restic.env` から作る。
古いものを選ぶときは `RESTORE_BEFORE=2026-10-30T00:00:00Z sh recovery/infisical.sh db`。

## 7. Infisical の Kubernetes auth の CA を差し替える

**DB を戻すと、operator の Machine Identity(`f2bc3416…`、許可 SA `infisical/infisical-auth`)の CA も
古いクラスタのものに戻る。** InfisicalSecret が全部 `SSL certificate verification failed … self-signed certificate` で止まる。

管理者でログインしておく。ブラウザのログインは t.ps1 が中継するので、シェルの中ではなく手元で
`tools/t.ps1 infisical login --domain https://il.doany.io/api`(トークンは `.home/` に残る)。

```shell
sh recovery/infisical.sh ca          # クラスタと Infisical の CA の頭を並べて見る
sh recovery/infisical.sh ca apply    # 差し替えて、operator を蹴り直す(失敗が続くと間を空けるため)
kubectl get infisicalsecret -A       # 全部 Ready になる。backup/backup と各 namespace の volsync もここで入り、VolSync の Secret ができる
```

`talos-secrets.sops.yaml` を作り直していなければ CA は前と同じなので、`ca` で頭が一致していれば `apply` は要らない。

## 8. PV データを戻す(VolSync)

**1 本で流す。** Argo CD を止め、Forgejo を先に戻し、非公開アプリの Application と PVC が出てくるのを待ってから、
残りの namespace を 1 つずつ「止める → 戻す → 起こす」:

```shell
sh recovery/pv.sh - plan-all      # 読むだけ。namespace ごとに戻す PVC とスナップショット、PVC に入るか(fit)を出す。先にこれを見る
sh recovery/pv.sh - restore-all
```

`restore-all` がやっていること(途中で止まったら Argo CD が止まったままのことがあるので、止まったところの表示に従う。**流し直すと Forgejo からやり直す**ので、続きは `<ns> restore` を 1 つずつ):

1. `argo-pause`(selfHeal が replicas を戻して、戻している最中にアプリが起き上がるので)
2. `forgejo restore` ── **Forgejo を先に。** 非公開アプリのイメージ(fj.doany.io のレジストリ。中身は `forgejo-repos`)も、
   Argo CD が読むマニフェストも、それを読むトークン(Forgejo の DB)も全部 Forgejo にあるので、戻すまで 1 本も上がらない
3. `argo-resume` して ApplicationSet のエラーが消え、**残りの namespace と PVC が全部出そろって全部の `plan` が通る**まで待ち(10 分。通らなければ forgejo だけ戻した状態で止まる)、
   **全部が PVC に入るか(`fit`)を見て**(入らなければ同じく止まる)、また `argo-pause`
4. `deploy/volsync/` の namespace(forgejo・infisical を除く)を 1 つずつ `<ns> restore`
5. `argo-resume`

1 つだけ戻すなら `sh recovery/pv.sh <ns> plan` で見てから `sh recovery/pv.sh <ns> restore`(Argo CD は先に `argo-pause`)。

- **PVC は丸ごと戻す。** `restore` は `deploy/volsync/<ns>.yaml` の ReplicationSource の PVC ごとに、ReplicationDestination(`copyMethod: Direct`)で
  リポジトリ `<bucket>/volsync/<ns>/<pvc>` から書き戻す。スナップショットから取っているので、Postgres・SQLite・Tuwunel(RocksDB)も
  ファイルのまま戻り、起きるときに自分で立ち直る(k8up の頃の pg_dump・SQLite・tar の戻し分けは要らない)。戻す前の中身は消す(`enableFileDeletion`)
- **戻すのはこのクラスタができる前のスナップショットだけ**(kube-system の namespace ができた時刻より前。`restoreAsOf`。`RESTORE_BEFORE` で上書きできる)。
  ReplicationSource は Argo CD が作ると時刻を待ちはじめ、戻す前の空の PVC を取ったものが「いちばん新しい」になりうるため(2026-10-31 に k8up で踏んだ)
- 使う Secret(`volsync-<pvc>`)は deploy/volsync/ の InfisicalSecret が作る(7 が済んでいること)。無ければ `restore` は書く前に止まる
- `deploy/volsync/` に無い namespace や PVC、スナップショットが無いものは `plan` の時点で止まる(黙って飛ばさない)。やめたアプリは deploy/volsync/ から消す
- PVC が `Pending`(StorageClass は使う Pod が付くまで bind しない)でも、VolSync の mover が付けば bind する
- **PVC の requests が本当の上限**(OpenEBS LVM)。`fit` が `restic stats` の大きさと requests を比べ、9 割を超えるものがあれば
  `plan-all` は 1 で終わり、`restore-all` は上書きする前に止まる。PVC を大きくするか、restic から要らないものを消す
- **k8up の頃のリポジトリ**(バケットの根。host が namespace)は、保持期間(2027-05 ごろ)が切れるまで残してある。そこから戻すときは
  `restic -r <restic.env の RESTIC_REPOSITORY> snapshots --host <ns>` で探して `restic restore` で手で取り出す([../deploy/backup/README.md](../deploy/backup/README.md)「k8up の頃のリポジトリ」)

## 9. 確かめる

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

- [ ] `kubectl -n argocd get applications` が全部 Synced / Healthy、`kubectl get infisicalsecret -A` が全部 Ready
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

## 10. 後始末

```shell
rm -f ~/.config/restic.env ~/infisical-load.log
```

## 詰まったときに見るところ

| | |
| --- | --- |
| ノードが上がらない | iLO のコンソール。ダッシュボードに版と健全性が出る |
| Pod が Pending | **PSA のラベル**([../docs/talos.md](../docs/talos.md)「PSA のラベル」)か、control-plane の taint |
| PVC が Bound しない | `kubectl -n kube-system logs ds/lvm-thinpool -c pool`(VG `data` が無い = `talosctl get volumestatus` の `r-lvm`)、ノードに `doany.io/lvm-thinpool=ready` が付いて `lvm-localpv-node` が動いているか、`kubectl -n kube-system logs ds/lvm-localpv-node -c openebs-lvm-plugin` |
| 非公開イメージが引けない | `bootstrap/talos.sops.yaml` の fj.doany.io の `password` が machine config に入っているか、Forgejo が戻っているか(8) |
| cilium-drift が TLS で落ちる | `talos-secrets.sops.yaml` を作り直した。`bootstrap/apiserver-ca.crt` を新しい `talos-secrets.sops.yaml` の Kubernetes の CA(`certs.k8s.crt` を base64 で戻したもの)にする |
| Application が `OutOfSync / Missing` のまま | `retry`(約 33 分)で自力で戻る。30 分以上動かなければ `kubectl -n argocd patch application <名前> --type=merge -p '{"operation":{"sync":{"revision":"HEAD"},"initiatedBy":{"username":"me"}}}'`。**chart のものは `HEAD` ではなく `spec.source.targetRevision` の値** |
| inlineManifest を直したのに効かない | `render.sh` → `apply-config` → **`upgrade-k8s`**([../bootstrap/talos.md](../bootstrap/talos.md)「上げ方 / 当て直し方」) |
