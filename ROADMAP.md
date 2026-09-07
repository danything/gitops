# ROADMAP — バックアップ方式と Talos Linux への移行

いまの「Ubuntu + k3s(sqlite)」は暫定構成で、最終形は **Talos Linux**(ホストに repo も clone も置かない)。
ここには**やること と 進捗**だけを置く。**なぜそうしたかは [`docs/decisions.md`](docs/decisions.md)**、
Talos のインストールメディアは [`docs/talos.md`](docs/talos.md)、
復元リハーサルは [`docs/restore-drill.md`](docs/restore-drill.md)。

## ロードマップ

### Phase 0 — k3s のまま restic 化(完了、2026-09-06)

暫定構成のまま「ホストに repo を置かず、パスフレーズ 1 つで戻せる」状態にした。

- **バックアップ**: `backup/k3s-backup` + systemd timer(毎日 04:00 JST)。対象 namespace を scale down →
  state.db を sqlite でホットバックアップ → PVC データ・k3s の証明書・ホスト設定・timer 一式を restic で
  Cloudflare R2(`doany-restic`)へ → scale up → `forget --prune` → `check`。結果は Mattermost 通知。
- **復元**: `recovery/restore.sh`(秘密なし)+ `recovery/env.age`。age のパスフレーズ 1 つで戻る。GitHub ログイン不要。
- **秘密**: repo 内の平文は SOPS + age で暗号化(`.sops.yaml`)。鍵は `recovery/sops-age.key.age` に同じパスフレーズで封じた。
- **リハーサル 2 回**: [docs/restore-drill.md](docs/restore-drill.md)。1 回目で 3 件の欠陥を発見して修正、2 回目で全て解消を確認。
- **容量**: R2 実サイズ 3.3 GiB / 無料枠 10 GB。AdGuard のクエリログ保持を 7d に、保持世代を 13 に(decisions.md)。
- **ghcr**: pull 認証をノード単位(`/etc/rancher/k3s/registries.yaml`)に寄せ、`imagePullSecrets` を全廃。
- 旧方式(tar + rclone の `backup.sh` / `init.sh` / `setup-network.sh`)は削除済み。

### Phase 0.5 — `k3s/` ディレクトリの改名(完了、2026-09-06)

k3s 固有の名前をやめて `deploy/` に統一。8 repo の PR をマージ(denpa#66、lgtm#17、blog#20、yuzuriha#8、
tamasagashi#63、worklog-cloud#106、xool#128、k3s-gitops#2)、`k3s-gitops` は `gitops` に改名、
ApplicationSet も `deploy/argocd.yaml` だけを見る形にした。ArgoCD の全 Application が Synced/Healthy を確認済み。

### Phase 1 — Talos の検証(本番に触らない)

- [x] QEMU/KVM(サーバ上)で v1.14.0 を起動 → `apply-config` → `bootstrap` → kubeconfig 取得まで通した(2026-09-06)。
      **`inlineManifests` が効くこと、デュアルスタック、local-path での PVC 作成を確認**。
      1.14 の machine config の作法(複数ドキュメント、service の IPv6 は `/108` 以下、PSA が既定 `baseline`)は
      [docs/talos.md](docs/talos.md) の「machine config の作法」にまとめた。
- [x] `talos/` を 1.14 の形に書き直した(2026-09-06)。talhelper はやめて `talosctl gen config` + パッチだけにし、
      **`talosctl validate -m metal` が通ることを確認**。カーネル引数は Image Factory の schematic
      (`32820716…`)に移した。手順は [talos/README.md](talos/README.md)。
- [x] **実機固有の確認は VM を待たずにほぼ片付いた(2026-09-07)。**
      - **ドライバは Talos のカーネルに全部ある**(siderolabs/pkgs の `config-amd64` で確認)。
        NIC は Broadcom BCM5719(HP 331i 4 ポート)で `CONFIG_TIGON3=m`、`CONFIG_BONDING=y`、
        `CONFIG_WIREGUARD=y`。wg-easy で Ubuntu の AppArmor 回避が要ったのは Talos では不要。
      - **IPv6 は「token `::2` 相当が無い」という前提が誤りだった。** 実機の NetworkManager も
        `ipv6.address1: 240f:6d:842b:1::2/64` を静的に書いているだけで、`ip token` はどの
        インタフェースにも設定されていない。Talos にもそのまま静的アドレスとして書いた。
      - `talos/patches/cluster.yaml` を実機の `ip -brief addr` と `/proc/net/bonding/bond0` から
        起こし直し、**`talosctl validate -m metal` が通ることを確認**。
- [x] **残っていた 3 つを QEMU で実際に起動して確かめた(2026-09-07)。**
      **tap/bridge は要らなかった。** `-netdev hubport` で QEMU の中だけに L2 セグメントを作れば
      ホストに何も生やさずに bond のメンバー 2 本を同じセグメントに挿せるし、`-netdev user` の
      `ipv6=on` は RA を送ってくるので RA 由来の既定経路も試せる(以前「user-mode では試せない」と
      書いていたのは誤り)。`patches/*.yaml` からの読み替えはインタフェース名とディスクだけ。
      - bond0 は `balance-alb` / `miimon 100` で上がり、片方の carrier を落とすとフェイルオーバーした。
      - 静的 IPv6 `::2` は載る。**が、`net.ipv6.conf.bond0.accept_ra: "2"` が無いと
        Kubernetes 起動後(forwarding=1)に RA の既定経路が消える。** `patches/cluster.yaml` を修正。
        ついでに `addr_gen_mode: "2"` が `stable_secret` 未設定で EINVAL のまま失敗し続けていたのを
        `"3"` に直した。
      - wireguard はカーネル組み込み(`/sys/module/wireguard/version` = 1.0.0)で、
        privileged + hostNetwork の Pod から `wg-quick up` が通った。AppArmor 回避は不要。
      手順・証拠・VM では確かめられない残りは [docs/talos.md](docs/talos.md)「VM ブートドリル」。
- [x] **PSA のラベルが要る namespace を洗い出して manifest に入れた(2026-09-07)。** 走っている Pod の spec を
      直接数えたら想定より多く、9 つあった。**baseline は hostPort も弾く**のを見落としていた。
      一覧と洗い出しのコマンドは [docs/talos.md](docs/talos.md)「PSA のラベル」。
- [ ] HelmChart CRD 依存を ArgoCD の Application に書き直す。
      - [x] cloudflare-ddns・infisical-secrets-operator・infisical-push-bridge(2026-09-07)。
            **Pod を入れ替えずに引き取れる**ことと、**CR を消すとアンインストールが走る**ことが分かった。
            手順は [docs/decisions.md](docs/decisions.md)「HelmChart CRD から ArgoCD の Application へ」。
      - [x] yosegaki(PVC 持ち。blog リポジトリ側、2026-09-07)。
      - [x] erpnext(2026-09-07)。`jobs.createSite` と `jobs.configure` を止めてから移した。
            描き出しの差は**その 2 つの Job だけ**で、Pod は入れ替わっていない。
      - [ ] infisical(Postgres の PVC 持ち。ArgoCD に預けると鶏卵になるので Talos では inlineManifests)。
      - argocd は移さない(自分自身。Talos では inlineManifests)。
- [ ] k8up を導入し、Phase 0 と同じ restic リポジトリに PVC バックアップと `backupcommand` の dump が取れること。
      - [x] operator を入れて、**`backend` を書かずにグローバル設定へ寄せれば R2 へ書ける**ことを確認(2026-09-07)。
            endpoint も含めて秘密は git に置かない形にできた。`backend.envFrom` だけでは動かない
            (k8up が空の `RESTIC_REPOSITORY` を必ず入れて上書きする)。詳細は [apps/k8up/README.md](apps/k8up/README.md)。
      - [x] **`Prune` はタグを書かないとリポジトリ全体を消す**ことを確認(2026-09-07)。
            `retention.tags` が無いと `restic forget` がリポジトリ全体に効く。バックアップに
            `tags: [k8up]`、prune に `retention.tags: [k8up]` を付けて、ホストのスクリプト
            (`--tag k3s-host`)と隔離した。
      - [x] **mattermost の postgres を `k8up.io/backupcommand` で論理バックアップ**(2026-09-07)。
            R2 に 9.3 MB の `pg_dump` が入ることまで確認済み。PVC には `k8up.io/backup: "false"` を
            付けて、ファイルはホスト側、論理バックアップは k8up、と分けてある。
      - [x] **erpnext の MariaDB(2026-09-07)。** chart の `mariadb-sts` に `podAnnotations` が無いので、
            gunicorn の Pod から `mariadb-dump` を打つ形にした。`site_config.json` から接続情報を読むので
            root のパスワードも要らない。実測 10.7 MB。
      - [x] **infisical の Postgres(2026-09-07)。** **クラスタで一番失えないデータ。** 実測 3.97 MB。
            本体は bootstrap に居るが、`Schedule` は apps に置いた(バックアップはアプリ層の関心事)。
      - [x] operator を `skipWithoutAnnotation: true` にして「注釈の無い PVC は取らない」側に倒した。
            k8up は論理バックアップ専用、ファイルはホストのスクリプト、という切り分け。
      - [ ] 残りの namespace の PVC をどうするか決める。いまはホストのスクリプトが全部見ているので、
            **Talos に移る時点で k8up 側に寄せる**(ホストにシェルが無くなるため)。
- [x] `talosctl etcd snapshot` → **空のディスクから `bootstrap --recover-from` で復旧するところまで確認**(2026-09-06)。
      k8s オブジェクトは戻るが **PV の中身は戻らない**ので、Talos 期の復元は etcd → PV データ(restic/k8up)の 2 段になる。
      詳細は [docs/talos.md](docs/talos.md)。

### Phase 1.5 — k3s のまま Cilium + Gateway API に寄せる

**決定 2026-09-06**: CNI を Cilium にして、kube-proxy・ServiceLB・Traefik をまとめて置き換える
(理由と検証結果は [docs/decisions.md](docs/decisions.md)「ルーティングの選定」)。
**Talos で後から替えるのが高いのは CNI だけ**なので、k3s のうちにここを済ませて OS 交換時の変数を減らす。
VM では一通り動くことを確認済み。**本番は CNI 交換で全 Pod の通信が一度切れる**ので、段階を分ける。

- [x] **Gateway API v1.6.1 の CRD を入れた**(Cilium 1.20 はこのバージョンを要求する。v1.4.0 だと
      GatewayClass が `Waiting for controller` のまま止まる)。gatewayclasses / gateways / httproutes /
      referencegrants / grpcroutes / backendtlspolicies / tlsroutes、必要なら tcproutes / udproutes。
- [x] **段階 1: CNI を Cilium に替えた(2026-09-06)。** 全 50 Pod Running、全サイト応答、KubeProxyReplacement 有効。
      詰まった点(flannel の残骸が VXLAN と衝突、grace period の長い Pod は強制削除が要る)は
      [docs/decisions.md](docs/decisions.md)「本番での実施結果」。戻すときは `config.yaml.pre-cilium` に戻して k3s 再起動。
- [x] **段階 2: ServiceLB をやめて hostPort に寄せた(2026-09-06)。** LB-IPAM ではなく hostPort を選んだ理由と
      詰まった点は [docs/decisions.md](docs/decisions.md)「LoadBalancer をどう置き換えるか」。
      Cilium 側は `hostPort.enabled` / `nodePort.enabled` / `externalIPs.enabled` を有効にする必要がある(既定は無効)。
- [x] **段階 3 の土台(2026-09-06)**: cert-manager(Cloudflare DNS-01)と Cilium Gateway を導入し、
      **yk.doany.io を Traefik と並走で HTTPRoute に載せて実際に配信できることを確認**(Let's Encrypt 証明書付き)。
      Gateway の待ち受けは LB-IPAM + L2 アナウンス(作業用に 10.10.0.50-55)。
      AdGuard の DoT 証明書も Traefik の acme.json 監視(acme-watcher)をやめて cert-manager 発行の Secret に移した。
- [x] **Web の 15 ホストすべてを HTTPRoute に並置し、Gateway 経由で Traefik と同じ応答を確認(2026-09-06)。**
      証明書はワイルドカード 1 枚、HTTP → HTTPS の 301 リダイレクトも Gateway 側に用意した。
- [x] **切り替え前に残っていたもの**:
      - [x] `px.doany.io`(3proxy)は Gateway を使わず、Pod のサイドカー(nginx stream)が TLS を終端して
        ホストのポートで直接受ける形にした。443 では HTTPS 終端と TLS passthrough が同居できない
        (ProtocolConflict)ため。当初 8444 だったが、分かりにくいので **3129**(平文 3128 の隣)に移した
        (2026-09-07)。クライアントの設定変更が要ったが完了済み。
      - [x] forward-auth の 2 本。`sub`(`*.s.doany.io`)は **oauth2-proxy を前段プロキシにする方式**で移した
        (専用インスタンス `auth-sub` が `--upstream` で LAN のホストへ中継。コールバックは既存の
        a.doany.io 側が受け、cookie secret を共有)。Traefik ダッシュボードは Traefik ごと消えるので対処不要
      - [x] yuzuriha の `compress` はアプリ側(Caddy ではなく `server.ts`)で zstd/gzip を返す形に置き換えた
- [x] **切り替え本番(2026-09-06 完了)。** Traefik の hostPort 80/443 を外し、Gateway の Service を
      80/443 の nodePort として同時に開いた。15 ホストすべてを LAN(10.10.0.4)と公開 IP の両方で確認済み。
      詰まった点(Cilium は nodePort 範囲内の hostPort を張らない、Traefik の Service に残った externalIPs が
      10.10.0.4:80/443 を黒穴にする)は [docs/decisions.md](docs/decisions.md)「切り替え本番」。
- [x] **Traefik の撤去(2026-09-07)。** `disable: [traefik]`、`Ingress` 15 本・`IngressRoute` 4 本・
      `Middleware` 4 つ・`IngressRouteTCP` 1 本と PVC `traefik-acme` を削除。マニフェストは gitops と
      アプリ 6 repo から消した。**ここで切り戻しの道は閉じた**(戻すなら Traefik を入れ直すところから)。
      **取りこぼし**: denpa と yosegaki は自分で配っている chart 側で公開していたので、
      `Ingress` を数えるだけでは見つからなかった(`dp.doany.io` が一時 404)。chart に
      `httpRoute.enabled` を足して移した。`dp.l.doany.io` 用に `*.l.doany.io` のリスナーも足した。
      **障害 1 件**: d.doany.io の backend を平文の 80 にしたら AdGuard の DoH が死に、
      これをセキュア DNS にしていたブラウザの名前解決が全部止まった(2026-09-07 06:34〜10:20)。
      nginx サイドカー経由に直した。詳細は decisions.md「AdGuard の DoH は backend が HTTPS でないと出ない」。
- [x] **クライアント IP は保たれている(2026-09-07 確認)。`externalTrafficPolicy` は `Cluster` のまま**。
      単一ノードでは backend が必ず同じノードに居るので Cilium は SNAT しない。
      証拠と、ノードを足すときにやることは [docs/decisions.md](docs/decisions.md)「クライアント IP」。

### Phase 1.7 — 運用まわりの整備(2026-09-07)

Traefik の撤去と前後してまとめて片付けたぶん。**どれも Talos 移行の前提になる。**

- [x] **HelmChart CRD をアプリ層から一掃した。** 残るのは `argocd` と `infisical` の 2 つだけで、
      どちらも Talos では `inlineManifests` に載せるので意図的に据え置き。
      **CR を消すと helm がアンインストールされる**(finalizer 駆動。外しても付け直される)ので、
      移すときは「Application を作る → helm のリリース Secret を消す → CR を消す」の順。
- [x] **Cilium の Helm 値を git に入れた。これが今日いちばん危なかった。**
      値が git に無く、`node-port-range: "80,443"` と `enable-l2announcements: true` は
      ConfigMap の直接編集で当たっていて Helm に記録されていなかった。つまり
      **素で `helm upgrade` すると黙って元に戻り、公開している Web が全部落ちる**状態だった。
      あるべき値は [bootstrap/cilium/values.yaml](bootstrap/cilium/values.yaml)。以後 ConfigMap は直接いじらない。
- [x] **Entra の認可をグループからアプリロールへ移し、redis を廃止した。**
      「グループクレームが大きいからセッションが Cookie に収まらない」という前提は**誤りだった**
      (所属グループは 2 つだけ)。効いたのは oauth2-proxy の `--session-cookie-minimal` のほう。
      テナントに P1 が無いのでロールの割り当てはユーザー単位。手順は [docs/entra.md](docs/entra.md)。
- [x] **PSA のラベルを入れた**(9 namespace。`baseline` は hostPort も弾く)。
- [x] **依存更新の範囲を決めた。** メジャーと Helm chart は自動マージしない。
      **版の番号は中身の大きさを表さない**(erpnext は「patch」で Dragonfly を Valkey に入れ替え、
      values のチューニングを無効にした)。Renovate の PR に Claude のレビューが効いていなかったのも直した
      (bot を一律除外していたので、自動マージしないものだけ `needs-review` ラベルで拾う)。
- [x] **Talos の更新ポリシーを決めた。** 版は [talos/versions.yaml](talos/versions.yaml) に寄せて
      Renovate に追わせる。**検知は自動、適用は手動。** 単一ノードでは上げること自体が全停止を伴う
      再起動になるので、コントローラ(tuppr / system-upgrade-controller)は 2 台目が入るまで使えない
      (どちらも「自分が乗っているノードは自分で上げない」設計)。
- [x] **R2 が無料枠を超えていたのを直した。** 3.3 GiB だったリポジトリが 13.92 GiB になっていた。
      原因は生 TS の作業領域(`denpa-recorded`)が 14 GB に育ったこと。除外した。
      保持世代が回れば実サイズも戻る。

### Phase 2 — k3s → Talos(停止を伴う。**ネットワーク構成は変えない**)

OS 交換だけに集中する。Cilium と Gateway API は Phase 1.5 で落ち着いた構成のまま持っていく。
Talos 側は machine config で `cni.name: none` と `proxy.disabled: true` にして、Cilium は
`k8sServicePort: 7445`(KubePrism)、`cgroup.autoMount.enabled: false` + `hostRoot: /sys/fs/cgroup` を足すだけ。

- [ ] 作業は LAN(10.0.0.2 / 10.10.0.4)か iLO(10.0.0.3)から。cloudflared 経由の ssh は使えない。
      作業中の見せ方は未定(Cloudflare のワイルドカード CNAME を proxied にすれば全サブドメインを Cloudflare 受けにできるが、
      読めるページを出すには Worker か Pages が要る。詳細は decisions.md)。
- [ ] 最終バックアップを取り、`restic check` を通す。
- [ ] Talos を実機にインストール(`talos/README.md` の手順、schematic `32820716…`)。
- [ ] **service の IPv6 CIDR を `fd43::/108` に変える**(Talos は `/64` を受け付けない)。ClusterIP が振り直しになる。
- [ ] PSA のラベルは manifest 側に入れてある。`local-path-storage` だけは Talos 側で作る namespace なので、
      local-path-provisioner を入れるときに一緒に付ける。
- [ ] k8s オブジェクトは etcd 復元ではなく **git から ArgoCD で再構築**(k3s 固有の HelmChart 等が etcd に混ざっているため)。
- [ ] PV データを restic から Job で復元(PVC 名 / namespace を合わせる)。
- [ ] ghcr の資格情報を machine config(`machine.registries.config."ghcr.io".auth`)へ。k3s の registries.yaml は役目を終える。
- [ ] **PT3**: 上流 PR が間に合わなければ KubeVirt にパススルーして tuner-agent だけ VM で動かす。
- [ ] Infisical → operator → 各アプリの順で疎通確認。DNS(cloudflare-ddns)、wireguard、AdGuard の公開リゾルバを確認。

### Phase 3 — Talos 定常運用

- [ ] k8up の失敗通知。スケジュールと保持(`keep-daily 7 / weekly 4 / monthly 6`、タグは `k8up`)は
      Phase 1 で入れた 3 本(mattermost / erpnext / infisical)に既に入っている。
      **PVC のファイルを k8up 側に寄せるのはここ**(Talos ではホストのスクリプトが使えない)。
- [ ] etcd スナップショットを定期化(talosconfig を Secret にした CronJob か、手元マシンの timer)。同じバケットへ。
- [ ] 四半期ごとに VM で復元リハーサル(PV + etcd の両方)。
- [ ] `talosctl upgrade` / `upgrade-k8s` の手順を README に。


## 積み残し

- ~~**復元リハーサルを Cilium 構成でやり直す。**~~ **2026-09-07 に実施、3 問とも Yes**
  ([docs/restore-drill.md](docs/restore-drill.md))。Cilium は k3s 起動の 40 秒後に自分で CNI 設定を書いて上がり、
  Gateway は `PROGRAMMED=True` で LB-IPAM も L2 アナウンスも初回で決まり、AdGuard の hostPort も張られた。
  移行のときに要ったエージェント再起動や Pod 作り直しは**一度きりの手当て**で、復元では要らない。
  47 Running / 15 Completed、起動しなかったのは前回と同じ `denpa/tuner-agent` と `wireguard/wg-easy` の 2 つだけ。
- ~~**`Schedule` に `SkipDryRunOnMissingResource=true` を付ける。**~~ **対処済み(2026-09-07)。**
  git に `k8up.io/v1` の `Schedule` があるのに復元先に CRD がまだ無いと、Argo CD は `apps/` の同期を
  **丸ごと**失敗させる(CRD を入れる Application 自身が同じ同期の中にあるので抜けられない)。
  子 Application 5 つが作られないまま止まった。3 つの `Schedule` に注釈を付けて解決。
  **「git がバックアップより進んでいる」状態は復元では普通に起きる**ので、snapshot が古かったから、では済まない。
- ~~**`k8up-global` Secret は git だけからは再建できない。**~~ **対処済み(2026-09-07)。**
  バックアップの資格情報そのものなので公開リポジトリには置けない。値は復元した `/etc/k3s-backup/env` に
  あるので `restore.sh` が作り直すようにした。リハーサルモードでは作らない(VM の k8up が本番の
  リポジトリに書きに行くため)。**Talos ではホストに env ファイルが無くなるので Infisical に移すこと。**

## 未決事項

- **`local-path-retain` をやめて「git で消したものは消える」に寄せる(方針は決定、実施は順番待ち)。**
  今日の掃除で 35 日・44 日放置された Released の PV が 3 本見つかった。**Retain は追われない状態を作る。**
  ただし外すと誤削除の復旧手段がバックアップ 1 本になるので、**復元リハーサルが通ってから**やる
  (2026-09-07 に通った)。やることは 3 つ:
  - PVC 22 本中 19 本に付いている `Prune=false,Delete=false` を外す。**これが本丸**(これが無いと git から消しても消えない)
  - 既存 PV の `persistentVolumeReclaimPolicy` を `Retain` → `Delete` にパッチする(PV は変更可能)
  - **`storageClassName` はバインド済み PVC では変更も削除もできない**(API が拒否する)。
    マニフェストから消すのは **Talos の再構築時**。そのとき既定の `local-path`(reclaim は `Delete`)になる
- **ネットワークを見る画面(着手予定)。** 外部公開の全体像と、内部でどのコンテナ同士が通信しているかの両方。
  前者はクラスタから生成する一枚、後者は **Hubble**。認証は `*.s.doany.io` と同じ oauth2-proxy 前段方式。
  **Hubble を入れない判断は撤回した**(2026-09-07。「見たい」という要件が出たため)。
  Cilium 側の Hubble は既に有効で `:4244` で待ち受けているので、足りないのは Relay と UI の 2 Pod だけ。
