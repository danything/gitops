# recovery

**ノード `main` をまっさらから建て直す入口。** git と restic(Cloudflare R2)だけで戻す。
2026-10-17 に実機でこの順に建て直した(そのときの姿が今の本番)。
秘密は暗号化してあるので、この repo は公開のままでよい。

| | |
| --- | --- |
| `env.age` | バックアップ先の資格情報(R2 の鍵、restic のパスワード)。age のパスフレーズで暗号化 |
| `sops-age.key.age` | `bootstrap/` と `talos/` の SOPS ファイルを復号する age 秘密鍵。**同じパスフレーズ**で暗号化 |
| [pv.sh](pv.sh) | PV のデータを k8up の `Restore` で戻す道具(下の 8) |
| [infisical.sh](infisical.sh) / [infisical-ca.mjs](infisical-ca.mjs) | Infisical を restic から直接戻す道具(下の 6・7) |

**2 つの道具は、2026-10-17 に使ったものから決め打ちを外した形で、この形ではまだ流していない。** 次の建て直しで最初に確かめる(`pv.sh - plan-all` は 2026-10-20 に本番の restic と突き合わせて、全 namespace の判定が上の表どおりになるのを確かめた)。

**手動のリハーサルは回さない。** 中身は月次の [restore-check](../apps/k8up/restore-check.yaml)、machine config は
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
| ホストの設定 | **machine config**。`talos/render.sh` が repo から描く(`talos/secrets.yaml` が同じなら同じクラスタ CA) |
| k8s オブジェクト | **git から Argo CD で再構築**。`bootstrap/` は machine config と Argo CD(Application `bootstrap`)が当てる |
| Infisical の DB | **手元の restic で直接**(k8up の資格情報 `k8up-global` が Infisical から来るので、k8up では戻せない) |
| ほかの PV データ | **k8up の `Restore`**([pv.sh](pv.sh)) |

etcd のスナップショット(restic の `--host etcd`、[../apps/k8up/etcd-snapshot.yaml](../apps/k8up/etcd-snapshot.yaml))は
git に無い状態まで一度に戻したいときの近道で、主経路ではない([../docs/talos.md](../docs/talos.md)「etcd スナップショットからの復旧」)。

## 道具と経路

**コマンドは全部 `tools/t.ps1 --admin` で入ったコンテナのシェルで打つ**(`HOME` はリポジトリの `.home/` で、
age 鍵と restic の資格情報はそこに残る。ノードにシェルは無い)。**talosctl / kubectl の資格情報は t.ps1 が用意する** ──
talosconfig も管理者の kubeconfig も `talos/secrets.yaml` の CA からその場で作る(ファイルでは持たない)
([../tools/README.md](../tools/README.md)「クラスタの資格情報」)。GitHub の操作(5)だけ手元の `gh`。

- **作業用 PC(J:COM 側の LAN)からは 10.10.0.4(eno4)にしか届かない**(10.0.0.2 は届かない)。t.ps1 の行き先はそこに固定してある
- iLO(10.0.0.3)の Remote Console(HTML5)で、ブートメニューも maintenance mode の IP も見える。USB だけ物理で挿す
- **GitHub Actions では代わりにならない。** Talos の API(50000)は LAN からしか届かず、CI の OIDC の信頼も
  machine config を当てて初めてできる

## 1. 鍵を開いて machine config を描く

```shell
mkdir -p ~/.config/sops/age && age -d -o ~/.config/sops/age/keys.txt recovery/sops-age.key.age   # パスフレーズ
./talos/render.sh talos/clusterconfig       # `valid for metal mode` まで出ること
```

- **`talos/secrets.yaml` を作り直さない。** 作り直すと別のクラスタ CA になり、`bootstrap/apiserver/ca.crt`・
  Infisical の Kubernetes auth(7)が合わなくなる
- **`render.sh` は出力先を丸ごと消して作り直す。** `talos/clusterconfig/` に kubeconfig などを置いていたら消える
- 版は [../talos/versions.yaml](../talos/versions.yaml)。**上げるなら建て直しの日ではない日に**

## 2. ISO で起動する

ISO は Image Factory のもの(URL の schematic と版は `versions.yaml` と揃える)。ハイブリッドなのでそのまま書けばよい
(Windows なら Rufus の **DD イメージモード**。WSL からは USB が見えない)。

```shell
curl -LO https://factory.talos.dev/image/96371c8f956f7f5f9d09925bb49fe096c0cad05c5cf5bdb464790982c0b067ca/v1.15.0-alpha.2/metal-amd64.iso
```

- ISO の schematic は気にしなくてよい。ディスクに書かれるのは machine config の `--install-image`
- **Secure Boot が Disabled**(RBSU は POST 中に F9 → Server Security → Secure Boot Settings)。Boot Mode は UEFI のまま
- POST 中に **F11** で USB を選ぶ(iLO の Virtual Media なら Image File CD-ROM/DVD に ISO の URL を貼り、Reset して F11)
- コンソールに maintenance mode の IP が出る。インタフェースが `eno1` / `eno2` / `eno4`、インストール先が `/dev/sda`(447 GB)であること
  (違ったら `talos/controlplane.yaml` / `main.yaml` を直して 1 に戻る。**`diskSelector` の先は書いたら消える**):

```shell
IP=<コンソールに出た IP>
talosctl get links --insecure -n $IP -e $IP
talosctl get disks --insecure -n $IP -e $IP
```

## 3. 当てる(インストールは無人で進む)

```shell
talosctl apply-config --insecure -n $IP -e $IP -f talos/clusterconfig/controlplane.yaml
```

`UnattendedInstallConfig` があるので、ディスクに書いて自分で再起動する。**ここで SSD が上書きされる。**
`STATE` / `EPHEMERAL` / `u-local-path` が `ready` になったら USB を抜いてよい(挿したままだとブート順によっては
また maintenance mode で上がる):

```shell
talosctl get volumestatus    # EPHEMERAL は 64GiB 上限。違ったら入れ直すしかない
```

## 4. クラスタを起こす

```shell
talosctl bootstrap         # 単一ノードなので 1 回だけ
kubectl get nodes          # Ready / control-plane / versions.yaml の kubernetes: の版
kubectl get pods -A        # cilium・coredns・local-path・argocd・cert-manager・infisical が Running
kubectl get gatewayclass   # cilium が Accepted(無いと Gateway が `Waiting for controller` のまま)
```

`talosctl kubeconfig` は使わない(取り消せない 1 年の証明書が呼ぶたびに出る)。t.ps1 が `secrets.yaml` の CA でその場で作る。

## 5. 残りの bootstrap/ が入るのを見る(ArgoCD)

手ですることは無い。ArgoCD の Application `bootstrap`([../bootstrap/argocd/repos.yaml](../bootstrap/argocd/repos.yaml))が
`ClusterIssuer`・Gateway・auth・`InfisicalSecret` を当てる。

```shell
kubectl -n argocd get application bootstrap    # InfisicalSecret の CRD が来るまでは何度か落ちて retry で戻る
kubectl get certificate -A                      # Gateway に証明書が付く
```

Argo CD はこの間に `apps/` と各リポジトリの `deploy/` を同期しはじめる。**中身はまだ空**なので、
Infisical の Secret を待つアプリと、Forgejo から来る非公開アプリ(`repos-forgejo` が `ErrorOccurred`)は上がらない。想定どおり。

## 6. Infisical の DB を戻す

```shell
age -d -o ~/.config/restic.env recovery/env.age     # パスフレーズ。終わったら消す(10)
set -a; . ~/.config/restic.env; set +a
restic snapshots --host infisical --latest 1 --compact      # /infisical-postgresql.sql の ID
sh recovery/infisical.sh db <ID>     # users が 0 なら Infisical を起こさずに止まる。流し直すときは先に drop-old
```

起動したばかりの Infisical の Postgres にダンプを流す(ロールと DB は chart が作ってある)。
`public` は消さずに `old_public` に退ける(`DROP SCHEMA` は `max_locks_per_transaction` が足りず落ちる。[infisical.sh](infisical.sh))。
Infisical が上がって中身が見えたら、退けたものを消す:

```shell
sh recovery/infisical.sh drop-old
```

## 7. Infisical の Kubernetes auth の CA を差し替える

**DB を戻すと、operator の Machine Identity(`f2bc3416…`、許可 SA `infisical/infisical-auth`)の CA も
古いクラスタのものに戻る。** InfisicalSecret が全部 `SSL certificate verification failed … self-signed certificate` で止まる。

管理者でログインしておく。ブラウザのログインは t.ps1 が中継するので、シェルの中ではなく手元で
`tools/t.ps1 infisical login --domain https://il.doany.io/api`(トークンは `.home/` に残る)。

```shell
sh recovery/infisical.sh ca          # クラスタと Infisical の CA の頭を並べて見る
sh recovery/infisical.sh ca apply    # 差し替えて、operator を蹴り直す(失敗が続くと間を空けるため)
kubectl get infisicalsecret -A       # 全部 Ready になる。k8up/k8up-global もここで入り、k8up が動き出す
```

`secrets.yaml` を作り直していなければ CA は前と同じなので、`ca` で頭が一致していれば `apply` は要らない。

## 8. PV データを戻す(k8up)

**1 本で流す。** Argo CD を止め、Forgejo を先に戻し、非公開アプリの Application と PVC が出てくるのを待ってから、
残りの namespace を 1 つずつ「止める → 戻す → 起こす」:

```shell
sh recovery/pv.sh - plan-all      # 読むだけ。namespace ごとに何をするかを出す。先にこれを見る
sh recovery/pv.sh - restore-all
```

`restore-all` がやっていること(途中で止まったら Argo CD が止まったままのことがあるので、止まったところの表示に従う。**流し直すと Forgejo からやり直す**ので、続きは `<ns> restore` を 1 つずつ):

1. `argo-pause`(selfHeal が replicas を戻して、戻している最中にアプリが起き上がるので)
2. `forgejo restore` ── **Forgejo を先に。** 非公開アプリのイメージ(fj.doany.io のレジストリ。中身は `forgejo-repos`)も、
   Argo CD が読むマニフェストも、それを読むトークン(Forgejo の DB)も全部 Forgejo にあるので、戻すまで 1 本も上がらない
3. `argo-resume` して ApplicationSet のエラーが消え、**残りの namespace と PVC が全部出そろって全部の `plan` が通る**まで待ち(10 分。通らなければ forgejo だけ戻した状態で止まる)、また `argo-pause`
4. restic の host(forgejo・infisical・etcd を除く)を 1 つずつ `<ns> restore`
5. `argo-resume`

1 つだけ戻すなら `sh recovery/pv.sh <ns> plan` で見てから `sh recovery/pv.sh <ns> restore`(Argo CD は先に `argo-pause`)。
`restore` は namespace の最新のスナップショットを経路ごとに引き、**経路の形で操作を決める**:

| 経路 | 操作 |
| --- | --- |
| `/data/<pvc>` | `folder` |
| `/<ns>-<app>.db`(SQLite) | `sqlite`。PVC は `<app>-db`、無ければ `<app>-data`(denpa)。ファイル名は `<app>.db`。**folder を先に**流すので、`denpa.db*` を除いて取った `/data/denpa-data` を置いてから DB を戻す順になる |
| `/<ns>-postgres.sql` | `pgload`。`deploy/postgres` だけ止めずに残す。ユーザーと DB は `plan` の時点で deploy/postgres の env から決める(forgejo は `forgejo` / `forgejo`、rybbit は `rybbit` / `analytics`。ダンプは `--clean` 付き) |
| `/netbird-backup.tar` | `untar`(`store.db*` `idp.db*` `events.db*` を消してから)。戻すまで netbird-server は `no other identity providers configured` で CrashLoop する |
| `/matrix-backup.tar` | Tuwunel 自身のバックアップ(`backups/`)と `media/` の tar。新しく作られた `db/` を消して展開し、**1 回だけ `--restore-backup` 付きで起こす**(引数は Argo CD を戻すと selfHeal が消す) |

表に無い経路、namespace や PVC が無いものは `plan` の時点で止まる(黙って飛ばさない。「まだ Argo CD が作っていない」と「やめたアプリの残り」を区別できないので)。やめたアプリの残りは restic から消しておく([../apps/k8up/README.md](../apps/k8up/README.md)「やめたアプリの残り」)。新しい形の経路を足したら pv.sh の `plan` とこの表に足す。

- **`Succeeded` は「戻った」の意味ではない。** `pv.sh` は `Restored N files` と(SELinux 以外の)エラー数を出すので、それを見る。
  SQLite は大きさを restic と突き合わせてから付け替える
- `pv.sh` がやっていることと理由(root で走らせる・数字だけの ID を引用符で囲む・バイナリを標準入力で流さない)は [pv.sh](pv.sh) の冒頭
- PVC が `Pending`(local-path は使う Pod が付くまで bind しない)でも、Restore の Pod が付けば bind する

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
      (frontend が無いときは [../apps/cluster/pt3-rebind.yaml](../apps/cluster/pt3-rebind.yaml) が付け直しているか)
- [ ] Renovate の CronJob が次の回で動く(`kubectl -n renovate get jobs`)、k8up の通知が翌日 OK ✅
- [ ] etcd のスナップショットを 1 回手で取る(`kubectl -n k8up create job --from=cronjob/etcd-snapshot etcd-snapshot-first`)

## 10. 後始末

```shell
rm -f ~/.config/restic.env ~/infisical-load.log
```

## 詰まったときに見るところ

| | |
| --- | --- |
| ノードが上がらない | iLO のコンソール。ダッシュボードに版と健全性が出る |
| Pod が Pending | **PSA のラベル**([../docs/talos.md](../docs/talos.md)「PSA のラベル」)か、control-plane の taint |
| PVC が Bound しない | local-path の ConfigMap に `setup` / `teardown` があるか |
| 非公開イメージが引けない | `talos/controlplane.yaml` の fj.doany.io の `password` が machine config に入っているか、Forgejo が戻っているか(8) |
| bootstrap apply が TLS で落ちる | `secrets.yaml` を作り直した。`bootstrap/apiserver/ca.crt` を新しい `secrets.yaml` の Kubernetes の CA(`certs.k8s.crt` を base64 で戻したもの)にする |
| Application が `OutOfSync / Missing` のまま | `retry`(約 33 分)で自力で戻る。30 分以上動かなければ `kubectl -n argocd patch application <名前> --type=merge -p '{"operation":{"sync":{"revision":"HEAD"},"initiatedBy":{"username":"me"}}}'`。**chart のものは `HEAD` ではなく `spec.source.targetRevision` の値** |
| inlineManifest を直したのに効かない | `render.sh` → `apply-config` → **`upgrade-k8s`**([../talos/README.md](../talos/README.md)「上げ方 / 当て直し方」) |
