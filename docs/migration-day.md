# 移行当日の手順

**この 1 枚を上から順にやる。** 中身の説明は各所にあるので、ここには**順番と、
その場で見るもの**だけ置く。詳しい理由が要るときだけリンクを踏む。

**なぜこの順番か**が要るなら [ROADMAP.md](../ROADMAP.md) の Phase 2 と
[decisions.md](decisions.md)「Talos の起動順序をどう組むか」。
**移行は今の DL360 でやる。** Z440 へ移すのはそのあと([talos.md](talos.md)「Z440 に移すときに変わるもの」)。

---

## 0. 前日までに

- [ ] `./talos/render.sh /tmp/talos-config` が**手元で通る**
      (`valid for metal mode` まで出ること)
- [ ] 生成物に **inline 9 つ + CRD の URL 5 つ**が入っている
      ([talos/README.md](../talos/README.md)「上げ方 / 当て直し方」)
- [ ] `talos/versions.yaml` の版が意図どおり(**上げるなら今日ではない日に**)。
      Kubernetes は k3s の v1.36.2 ではなく **`versions.yaml` の `kubernetes:` の版**で建つ。
      git から建て直す(k3s は sqlite で etcd を持ち越さない)ので、版が上がっても in-place の飛び級ではない
- [ ] **作業中は何も見せない。** 決定済み(ROADMAP の Phase 2)。メンテナンス画面は用意しない
- [ ] **やめどきの時刻を決めておく**(下の「やめどき・戻せないこと」)
- [ ] **手元の PC に道具がそろっている。** 移行後は**ノードにシェルが無い**ので
      `ssh main 'kubectl …'` が使えなくなる。5 以降は全部手元から叩く

      | | 用途 |
      | --- | --- |
      | `talosctl` | 3〜5。版はクラスタに合わせなくてよい |
      | `kubectl` | 5〜9。**`versions.yaml` の `kubernetes:` と同じ版**(tools の Dockerfile が同じ depName で揃えている) |
      | `restic` | 8 でスナップショット ID を選ぶ |
      | `helm` / `sops` / `age` | 3(`render.sh`)と調べもの |
      | `jq` | 調べもの(手元に winget で入れてある。tools のコンテナには無い) |

      jq 以外は [tools/t.ps1](../tools/t.ps1) のコンテナに入っている([tools/README.md](../tools/README.md))。
      **コンテナの `/tmp` は実行ごとに消える**ので、t.ps1 で `render.sh` を回すなら出力先は
      `talos/clusterconfig/`(`.gitignore` 済み)にする。

      **6 は GitHub Actions がやる。** 3〜5 は Talos の API(50000)が LAN からしか届かず USB とコンソールが物理なので、
      8 は PVC に書き戻す操作を GitHub から実行できる状態を作らないため、どちらもワークフローに寄せない。

## 1. 経路の確保

- [ ] **LAN(10.0.0.2 / 10.10.0.4)か iLO(10.0.0.3)から作業する。**
      cloudflared 経由の ssh は落ちる
- [ ] iLO にログインできることを**先に**確かめる。
      **USB で焼く場合も、コンソールの代わりに使えるので開けておく**
      (`talosctl` は手元の PC から LAN 越しに叩く。実機の前に立つのは
      ブートデバイスを選ぶのと maintenance mode の IP を読むときだけ)

## 2. 最終バックアップ

```shell
sudo systemctl start k3s-backup.service     # ホストのぶん
```

- [ ] `restic check` が通る
- [ ] **k8up の通知が OK ✅**(FAILED が出ないこと)([apps/k8up/README.md](../apps/k8up/README.md)
      「失敗したときに気づけるようにする」。`notify` の CronJob を手で 1 回回すのが早い)

## 3. machine config を作る

```shell
./talos/render.sh /tmp/talos-config
```

**秘密は 2 つとも repo にある**(`talos/secrets.yaml` / `talos/registries.yaml`)。
`secrets.yaml` を作り直すと**別のクラスタになる**ので触らない。

## 4. 焼く

**前もって USB を作っておく。** ISO はハイブリッドなのでそのまま書けばよい。
Windows なら Rufus で ISO を選び、**DD イメージモード**(balenaEtcher でもよい)。
WSL からは USB が見えない(usbipd で渡す必要がある)ので Windows 側でやる方が早い。
URL の版と schematic は [talos/versions.yaml](../talos/versions.yaml) と揃える(下は 2026-10-13 の値)。

```shell
curl -LO https://factory.talos.dev/image/96371c8f956f7f5f9d09925bb49fe096c0cad05c5cf5bdb464790982c0b067ca/v1.15.0-alpha.1/metal-amd64.iso
sudo dd if=metal-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

**焼いた ISO の schematic は気にしなくてよい。** ISO が決めるのは maintenance mode の
カーネルだけで、**ディスクに書かれるのは machine config の `--install-image`**
(`factory.talos.dev/installer/96371c8f…:v1.15.0-alpha.1`。[render.sh](../talos/render.sh))。
ドリル用の `2d61dd07…` で起動しても、入るのは本番用の schematic。

- [ ] **Secure Boot が Disabled** であること(RBSU は POST 中に F9 →
      Server Security → Secure Boot Settings)。通常 ISO は署名されていない。
      Boot Mode は UEFI のまま
- [ ] USB を挿して電源を入れ、POST 中に **F11(Boot Menu)** で USB を選ぶ。
      iLO の Virtual Media を使うなら、Remote Console → Virtual Drives → Image File CD-ROM/DVD で ISO を選び
      (factory の URL を直接貼ってもよい)、Power → Reset して F11 で "iLO Virtual USB 3 : iLO Virtual CD-ROM"
- [ ] maintenance mode の IP をコンソールで確認
- [ ] `talosctl get links --insecure -n <IP> -e <IP>` で**インタフェース名が
      `eno1` / `eno2` / `eno4` であること**を確かめる。違ったら
      `talos/patches/cluster.yaml` を直して 3 に戻る
- [ ] `talosctl get disks --insecure -n <IP> -e <IP>` で**インストール先が `/dev/sda`(447 GB の SSD)であること**を確かめる。
      違ったら `talos/patches/main.yaml` の `diskSelector` を直して 3 に戻る(**書いたら消える**)

```shell
talosctl apply-config --insecure -n <IP> -f /tmp/talos-config/controlplane.yaml
```

**`UnattendedInstallConfig` があるのでディスクに書かれる。** ここから先は k3s に戻せない(下の「やめどき・戻せないこと」)。

- [ ] **書き終わって再起動したら USB を抜く。** 挿したままだと、ブート順によっては
      また maintenance mode で上がってくる

## 5. クラスタを起こす

```shell
TC=/tmp/talos-config/talosconfig
talosctl --talosconfig $TC -n 10.0.0.2 -e 10.0.0.2 bootstrap
talosctl --talosconfig $TC -n 10.0.0.2 -e 10.0.0.2 kubeconfig
```

- [ ] `talosctl get volumestatus` に **EPHEMERAL(64GiB 上限)と u-local-path** が出る。
      **ここが違ったら入れ直すしかない**([talos/patches/volumes.yaml](../talos/patches/volumes.yaml))
- [ ] `kubectl get nodes` が **Ready / control-plane / `versions.yaml` の `kubernetes:` の版**
- [ ] `kubectl get pods -A` で **cilium・coredns・metrics-server・local-path・
      argocd・cert-manager・infisical** が Running
      ([talos.md](talos.md)「ブートドリル 4 回目」と同じ絵)

## 6. 残りの bootstrap/ を当てる

GitHub Actions の **bootstrap apply** を `workflow_dispatch` で回す。

- [ ] `ClusterIssuer`・Gateway・auth・`InfisicalSecret` が入る
- [ ] **SOPS 済みの 4 ファイルは CI が当てない。**
      `infisical/secrets.yaml` と `cert-manager/cloudflare-secret.yaml` は
      **machine config に入っている**ので何もしなくてよい。残り 2 つは chart なので同じ
- [ ] Gateway に証明書が付く(`kubectl get certificate -A`)
- [ ] **ワークフローが TLS で落ちないこと。** `bootstrap/apiserver/ca.crt` に k3s と Talos の
      CA を 2 枚入れてあるので何もしなくてよい(2026-10-05。1 枚だけだった頃はここで落ちて、
      最後の nodePort 80/443 の当て直しが走らず公開経路が戻らなかった)

## 7. アプリが戻るのを待つ

**先に 2 つだけ戻す。** どちらも下の 8 のやり方で、ほかのアプリより前に。

1. **Infisical の DB(`infisical-postgresql.sql`)。** 空のままだと `InfisicalSecret` を使う
   アプリが Secret をもらえず、ここが「全部 Healthy」にならない
2. **Forgejo(`forgejo-postgres.sql` と PVC `forgejo-repos`)。** 1 が済んで GitHub 側の
   Application が立つと Forgejo も上がってくるが、**中身が空**。非公開アプリは
   **イメージ(fj.doany.io のレジストリ。中身は `forgejo-repos`)も、Argo CD が読む
   マニフェストも、それを読むトークン(Forgejo の DB の中)も全部 Forgejo にある**ので、
   戻すまで 1 本も上がらない。2026-09-15 に入れたもので、**ドリルでは一度も通っていない**

ArgoCD が `apps/` と各リポジトリの `deploy/argocd.yaml` を同期する。
ApplicationSet は 2 つに分けてある(`repos` = GitHub、`repos-forgejo` = Forgejo)。
**2 を戻すまで `repos-forgejo` が `ErrorOccurred` なのは想定どおり**で、`repos` 側は止まらない
(同居させていた頃は、ここで GitHub 側も含めて Application が 1 本も作られなかった。
[bootstrap/argocd/repos.yaml](../bootstrap/argocd/repos.yaml))。

```shell
kubectl -n argocd get applicationset -o custom-columns='NAME:.metadata.name,ERR:.status.conditions[?(@.type=="ErrorOccurred")].status,MSG:.status.conditions[?(@.type=="ErrorOccurred")].message'
```

- [ ] `repos` の ERR が `False`(1 のあと)
- [ ] `repos-forgejo` の ERR が `False`(2 のあと。Forgejo の Pod を作り直すと早い)
- [ ] `kubectl -n argocd get applications` が全部 Synced / Healthy
- [ ] **PVC が Bound になる**(`local-path` が要る。5 で確認済み)

**待てば戻る。** CRD より先に同期しにいった Application は昔ここで諦めていたが、
`retry`(15s から倍々、上限 5 分、10 回 = 約 33 分)を入れたので自力で回復する。
それでも `OutOfSync / Missing` のまま 30 分以上動かないものだけ叩く:

```shell
kubectl -n argocd patch application <名前> --type=merge \
  -p '{"operation":{"sync":{"revision":"HEAD"},"initiatedBy":{"username":"me"}}}'
```

**Helm の chart から入れているものは `HEAD` が通らない。** `revision` は
chart の版として読まれ、`improper constraint: HEAD` で落ちる(2026-10-05 に erpnext で踏んだ)。
`spec.source.targetRevision` の値(chart の版)を渡す。

## 8. PV データを戻す

**順番が決まっている。** 手順は [apps/k8up/README.md](../apps/k8up/README.md)「戻し方」。
スナップショット ID は**手元の `restic snapshots`** で見る ── ホストにはもう入れない。
資格情報は Infisical の `/k8up/k8up-global`(`endpoint` / `bucket` / 鍵 2 つ / `repoPassword`)。

1. アプリを止める(`kubectl scale deploy/… --replicas=0`)
2. `Restore` を作る。**スナップショット ID を明示する**
3. **中身を見る。** `Succeeded` は「戻った」の意味ではない
4. アプリを戻す

**SQL のダンプは先にロールを作る** ── アプリを普通に起動してから流すのが早い。

## 9. 疎通確認

公開している名前は全部これで一度に見る(クラスタが正本)。**手元の PC から叩くこと** ──
ノードの上からは 80/443 に届かない(Gateway の nodePort が L7LB リダイレクトとして
載っているため。[decisions.md](decisions.md)「本番での実施結果」)。

```shell
kubectl get httproute,grpcroute -A -o jsonpath='{range .items[*]}{range .spec.hostnames[*]}{@}{"\n"}{end}{end}' \
  | grep -v '^\*' | sort -u | while read h; do
      printf '%-24s %s\n' "$h" "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$h/" 2>/dev/null || echo ERR)"
    done
```

移行前(2026-09-09)に流したときの答え。**同じ形になれば通っている**
(その後 `en` `mm` は畳み、`m` `e` `lk` `fj` `rt` などが増えた。見るのは 302 / 401 / ERR の形):

| | |
| --- | --- |
| 200 | 大半(`doany.io` `ac` `h` `il` `l` `nb` `ts` `w` `x` `y` `yk` など) |
| **302** | `a` / `ah` / `hl` ── oauth2-proxy が Entra へ飛ばしている |
| **401** | `dp` ── **これが正しい。** 公開側から来た通信を denpa が弾いている。200 が返ったら X-Forwarded-For が壊れていて、住所判定が効いていない |
| ERR | `dp.l.doany.io` ── 宅内専用の名前。AdGuard を引く端末からしか通らない |

- [ ] **上の表と同じ形になる**
- [ ] Infisical → operator → 各アプリの `Secret` が埋まる
      (`kubectl get infisicalsecret -A` が全部 `Synced`)
- [ ] `talosctl get links bond0` の MAC が **`e6:2c:1b:1a:a0:39`**(ルーターの IPv6 ホスト公開がこの MAC を指している。
      [talos/patches/cluster.yaml](../talos/patches/cluster.yaml)。VM では効いた([talos.md](talos.md) のドリル 7 回目)。実機の NIC でも同じかをここで見る)
- [ ] **別の回線の IPv6 だけで 443 に届く**(A レコードもあるので、ブラウザで名前を開くだけでは IPv4 に落ちて確かめにならない。アドレスを直接開くのも駄目で、SNI が無いと Gateway が TLS を切る(2026-10-17 に確かめた)。J:COM 側の PC から `curl -6 -so /dev/null -w "%{http_code} %{remote_ip}\n" https://fj.doany.io/` で `200 240f:6d:842b:1::2` が出れば届いている。[router.md](router.md)「IPv6 はノードだけを公開する」)
- [ ] `talosctl get routes -o yaml | grep -B10 'protocol: ra'` に `dst: ""` が残っている(IPv6 の既定経路。クラスタが上がってから見る)
- [ ] DNS(cloudflare-ddns が A/AAAA を書く)。**AAAA が `::2`** で、SLAAC のアドレスではないこと(`bond0` の `autoconf=0` が効いていれば SLAAC は付かない。Ubuntu 期は SLAAC を書いていた)。**sysctl より先に RA が届くと SLAAC が一度付いて残りうる**ので、`talosctl get addresses` を起動直後・数分後・再起動後の 3 回見る
- [ ] netbird(外から VPN に入れる)。**ここだけブラウザでは確かめられない**
- [ ] AdGuard の公開リゾルバ(`dig @10.10.0.4 example.com`)
- [ ] **`/dev/dvb/adapter*` と B-CAS リーダーが見える**(`talosctl ls /dev/dvb`、`talosctl ls /dev/bus/usb`)。
      denpa の tuner-agent が上がって録画できる。**PT3 のために alpha に乗せている**ので、ここが通らなければ意味が無い
      ([decisions.md](decisions.md)「PT3 チューナー」)
- [ ] bond0 の片方を抜いて通信が続き、挿し直して `/proc/net/bonding/bond0` の両方が `MII Status: up` に戻る
      (`talosctl read /proc/net/bonding/bond0`。復旧方向は VM で確かめられていない)
- [ ] Renovate の CronJob が次の回で動く(`kubectl -n renovate get jobs`。[apps/renovate/](../apps/renovate/README.md))

## 10. 後始末

- [ ] ホストの `k3s-backup` はもう無い(Talos にシェルが無い)。**k8up だけが残る**
- [ ] **k8up の通知が `main/…` を「25 時間以上更新されていない」と言い出すが、これは想定どおり。**
      ホストのスクリプトが止まったため。notify は過去 8 日に出てきた経路を「あるべきもの」と
      みなす作りなので、**8 日で勝手に鳴りやむ**([apps/k8up/notify.yaml](../apps/k8up/notify.yaml))。
      慌てて消しに行かないこと ── その 8 日ぶんが移行前の最後の退避でもある
- [ ] **etcd の日次スナップショットを有効にする。** k3s には CRD が無いので
      `talos/after-migration/` に置いてある。移して PR にする:

      ```shell
      git mv talos/after-migration/etcd-snapshot.yaml apps/k8up/
      ```

      マージされたら 1 回だけ手で回して、R2 に入ることを見る:

      ```shell
      kubectl -n k8up get secret etcd-snapshot          # Talos が talosconfig を書いている
      kubectl -n k8up create job --from=cronjob/etcd-snapshot etcd-snapshot-first
      kubectl -n k8up logs -f job/etcd-snapshot-first -c upload
      ```
- [ ] **`bootstrap/apiserver/ca.crt` から k3s の CA(1 枚目、`CN=k3s-server-ca@…`)を消す**

---

## やめどき・戻せないこと

- **4 の `apply-config` で SSD が上書きされる。** k3s をその場で戻す手は無い。それより前なら USB を抜いて再起動すれば Ubuntu に戻る
- **やめどきの時刻を前日に決めておく**(例: 開始から何時間)。その時刻に 7 が終わっていなければ、どちらかを選ぶ:
  - **Talos のまま直して進む**(既定)。git と restic は手つかずなので、詰まったところだけ直せばよい
  - **Ubuntu を入れ直して restic から戻す**([recovery/README.md](../recovery/README.md) の `restore.sh`。k3s 期のホストを丸ごと戻す)。
    2 の最終バックアップが戻り先になる
- 迷ったら前者。後者は Ubuntu の導入からやり直しで、当日中に終わる保証が無い

## 詰まったときに見るところ

| | |
| --- | --- |
| ノードが上がらない | コンソール(iLO)。ダッシュボードに版と健全性が出る |
| Pod が Pending | **PSA のラベル**([talos.md](talos.md)「PSA のラベル」)か、control-plane の taint |
| PVC が Bound しない | local-path の ConfigMap に `setup`/`teardown` があるか |
| private イメージが引けない | `talos/registries.yaml` が machine config に入っているか |
| inlineManifest を直したのに効かない | `render.sh` → `apply-config` → **`upgrade-k8s`**。順番が要る |
