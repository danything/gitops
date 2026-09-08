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
- [x] **HelmChart CRD 依存を ArgoCD の Application に書き直した(2026-09-07)。**
      **アプリ層からは無くなった。** 残る 2 つ(argocd 自身と infisical)は**移さないという決定**で、
      Talos では machine config の inlineManifests に載る(Phase 2)。
      - [x] cloudflare-ddns・infisical-secrets-operator・infisical-push-bridge(2026-09-07)。
            **Pod を入れ替えずに引き取れる**ことと、**CR を消すとアンインストールが走る**ことが分かった。
            手順は [docs/decisions.md](docs/decisions.md)「HelmChart CRD から ArgoCD の Application へ」。
      - [x] yosegaki(PVC 持ち。blog リポジトリ側、2026-09-07)。
      - [x] erpnext(2026-09-07)。`jobs.createSite` と `jobs.configure` を止めてから移した。
            描き出しの差は**その 2 つの Job だけ**で、Pod は入れ替わっていない。
      - **infisical と argocd は移さない。** infisical は Postgres の PVC を持ち、ArgoCD に
        預けると鶏卵になる。argocd は自分自身。どちらも Talos では inlineManifests(Phase 2)。
- [x] **k8up を導入した(2026-09-07)。** Phase 0 と同じ restic リポジトリに `backupcommand` の
      dump が入るところまで確認済み。**ファイルはホストのスクリプト、論理バックアップは k8up**、と
      切り分けた。ホストのスクリプトを畳むのは Talos に移る時点(Phase 2)。
      - [x] operator を入れて、**`backend` を書かずにグローバル設定へ寄せれば R2 へ書ける**ことを確認(2026-09-07)。
            endpoint も含めて秘密は git に置かない形にできた。`backend.envFrom` だけでは動かない
            (k8up が空の `RESTIC_REPOSITORY` を必ず入れて上書きする)。詳細は [apps/k8up/README.md](apps/k8up/README.md)。
      - [x] **`Prune` の効く範囲を確かめた(2026-09-07)。** `restic/cli/prune.go` は
            `--host=<自分の namespace>` を必ず渡すので、他の namespace にもホストのスクリプト
            (`host=main` / `--tag k3s-host`)にも届かない。`--tag` は `retention.tags` が
            あるときだけ渡るので、`tags: [k8up]` は二重の歯止めとして付けている。
            **同じ理由で prune は namespace ごとに要る**(1 本にまとめても他には効かない)。
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
      - [x] **SQLite を持つ 6 つを `backupcommand` に寄せた(2026-09-07)。**
            lgtm / xool / worklog / denpa / yosegaki / netbird。ファイルをそのままコピーすると
            本体と `-wal` がずれるので、`bun -e` の `serialize()` で整合したコピーを標準出力に出す。
            **イメージには何も足していない** ── 自前アプリは全部 bun で動いていて `bun:sqlite` が
            最初から使える(当初は「`sqlite3` を足す PR が 5 本要る」と見積もっていた)。
            netbird だけ上流イメージに何も無いので `oven/bun` のサイドカーを足した。
            実測は [apps/k8up/README.md](apps/k8up/README.md)。
      - [x] **`Schedule` を [apps/k8up/schedules.yaml](apps/k8up/schedules.yaml) に 9 本まとめた。**
            中身は名前と namespace と時刻しか違わないので、アプリごとに置くと同じ注意書きが 9 回並ぶ。
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
- [x] **Gateway を hostNetwork にして LB-IPAM と L2 アナウンスを撤去した(2026-09-07)。**
      Envoy がノードの 80/443 を bind する(`gatewayAPI.hostNetwork` + `NET_BIND_SERVICE`)。
      LoadBalancer Service が 0 になったので `bootstrap/gateway/lb-ipam.yaml` と
      `l2announcements` を削除。Gateway の住所はノードの `10.0.0.2` になる。
      - **狙いの半分は外した(2026-09-08 訂正)。** 「手で当てた nodePort 80/443 が要らなくなる」
        つもりだったが、実測すると **Envoy のホストソケットに直接来た接続は通らない** ──
        実通信は Cilium の L7LB リダイレクト(NodePort フロントエンド)経由で入る。
        port-80 の nodePort を 30080 に振り直したら**外部・LAN・Pod・ホストのすべてから
        80 番が死んだ**(443 は無事)。よって `nodePort.range: "80,443"` も k3s の
        `service-node-port-range` も外せず、**`recovery/restore.sh` の当て直しも要る**
        (#91 で消したのを戻した)。副作用として**ホスト自身**からノードの 80/443 に繋げない
        (ホスト上に使っているものは無い)。
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
Talos 側は **`KubeFlannelCNIConfig` を `$patch: delete` で消して `KubeProxyConfig` を
`enabled: false`** にし([talos/patches/cni.yaml](talos/patches/cni.yaml))、Cilium は
`k8sServicePort: 7445`(KubePrism)、`cgroup.autoMount.enabled: false` + `hostRoot: /sys/fs/cgroup` を足すだけ。
**v1alpha1 の `cni.name: none` はもう書けない**(型付きドキュメントと衝突する)。

- [ ] 作業は LAN(10.0.0.2 / 10.10.0.4)か iLO(10.0.0.3)から。cloudflared 経由の ssh は使えない。
      作業中の見せ方は未定(Cloudflare のワイルドカード CNAME を proxied にすれば全サブドメインを Cloudflare 受けにできるが、
      読めるページを出すには Worker か Pages が要る。詳細は decisions.md)。
- [ ] 最終バックアップを取り、`restic check` を通す。
- [x] **`talos/registries.yaml` を作った(2026-09-08)。** ghcr.io の PAT。
      無いまま焼くと private なイメージが全部 `ImagePullBackOff` になる。
      **`talos/secrets.yaml`(クラスタの CA 一式)も同日に作った** ── そちらも
      未作成で、`render.sh` が動かなかった。
- [ ] Talos を実機にインストール(`talos/README.md` の手順、schematic `32820716…`)。
- [ ] **service の IPv6 CIDR を `fd43::/108` に変える**(Talos は `/64` を受け付けない)。ClusterIP が振り直しになる。
      **設定は入っていて、VM で出ることも確かめた**(2026-09-08 のドリル。
      `kube-dns` が `["10.43.0.10","fd43::a"]` / `ipFamilyPolicy: RequireDualStack`)。
      当日やることは「振り直された ClusterIP で困るものが無いか見る」だけ。
- [x] **k3s の組み込みアドオンのうち、Talos に無いものを用意した(2026-09-08)。**
      `kubectl -n kube-system get addons.k3s.cattle.io` で洗い出した。
      - **local-path-provisioner** … 入れないと **PVC が 1 つも bind しない**。
        [talos/manifests/local-path.yaml](talos/manifests/local-path.yaml)。
        `local-path-storage` の PSA ラベル(privileged)もここで付く。
        **`local-path-retain` も同じ名前で出す** ── 21 本の PVC が参照していて、
        バインド済みでは変更できないため。
        データの置き場は **`/var/mnt/local-path`(専用パーティション)**
        ([talos/patches/volumes.yaml](talos/patches/volumes.yaml))。
        **ディスクの割り方は入れ直さないと変えられない**ので、当日の焼き込み前に確定させること
      - **metrics-server** … 入れないと `kubectl top` と各 UI の使用量表示が消える
        (HPA は 0 個なので停止はしない)。[talos/metrics-server-values.yaml](talos/metrics-server-values.yaml)。
        **`--kubelet-insecure-tls` が要る**(Talos の kubelet は自己署名の証明書)
      - coredns は Talos が自前で入れる(`KubeCoreDNSConfig`)。ccm と rolebindings は k3s 固有
      - **k3s が置いている RuntimeClass 10 個**(crun / wasm* / nvidia など)は
        **どの Pod も使っていない**ので、消えて構わない(2026-09-08 に確認)
      - **クラスタスコープのものを一通り数え直した(2026-09-08)。** APIService は
        metrics-server の 1 つだけ、PriorityClass は k8s 組み込みのみ、IngressClass は無し、
        webhook は cert-manager だけ。**残っていたのは Gateway API の CRD で、それが下の項目**
- [x] **Gateway API の CRD を自分で入れる(2026-09-08)。** いま入っているものは
      **消したはずの Traefik の `traefik-crd` chart が置いていったもの**で
      (`meta.helm.sh/release-name: traefik-crd`)、**Talos には当然無い。**
      無いと `Gateway` も 12 本の `HTTPRoute` も `GRPCRoute` も適用できず、
      **公開経路が丸ごと消える。** Cilium の chart は CRD を同梱しない。
      [talos/render.sh](talos/render.sh) が `KubeExternalManifestConfig` で URL を渡す
      (1.1 MB あるので inline にはしない)。版は [talos/versions.yaml](talos/versions.yaml)。
- [ ] k8s オブジェクトは etcd 復元ではなく **git から ArgoCD で再構築**(k3s 固有の HelmChart 等が etcd に混ざっているため)。
      **git に無いものが動いていないことは確認済み(2026-09-08)。** ArgoCD の
      `tracking-id` も Helm のラベルも k3s の `objectset` も owner も持たない
      オブジェクトを全 namespace で数えたところ、出てきた 11 個は**全部 `bootstrap/` の
      ファイル**だった(CI が `kubectl apply` で当てるので追跡の注釈が付かないだけ)。
      唯一の例外 `infisical/data-postgresql-0` は StatefulSet の
      `volumeClaimTemplate` が作るもので、chart が作り直す。
      **手で当てたまま git に入れ忘れたものは無い。**
- [ ] PV データを restic から復元。**手順は [apps/k8up/README.md](apps/k8up/README.md)「戻し方」**
      (k8up の `Restore` を作るだけ。2026-09-08 に実際に流して中身が開けるところまで確認済み)。
      **順番が決まっている:**
      1. ArgoCD が上がってアプリが同期され、**PVC が作られる**(`Restore` は書き込む先の
         PVC が要る。`local-path` の StorageClass はもう machine config が持っている)
      2. アプリを止める(`Restore` は動いているアプリの足元にファイルを置く)
      3. `Restore` を流す。**スナップショット ID を明示する** ── 省略すると最新が選ばれ、
         移行中に取ったものを掴みうる
      4. **中身を見る。** `Succeeded` は「中身が戻った」の意味ではない ── 空のスナップショットを
         戻したときも `Succeeded` で、ログだけが `Restored 0 files/dirs (0 B)` と言う
      5. アプリを戻す
      **`backupcommand` で取ったもの**(SQLite・pg_dump)は 1 個のファイルとして出るので、
      アプリのファイル名に置き換えるか、`psql` に流し込む一手間が要る。
- [x] **ghcr の資格情報を machine config(`machine.registries.config."ghcr.io".auth`)へ(2026-09-08)。**
      [talos/render.sh](talos/render.sh) が `talos/registries.yaml`(SOPS)を復号して足す。
      **中身を書くのは残作業**(上の「`talos/registries.yaml` を作る」)。k3s の registries.yaml は役目を終える。
- [x] **起動順序を組み直した(2026-09-08)。** k3s の `HelmChart` CRD は Talos に無いので、
      **[talos/render.sh](talos/render.sh) が `helm template` して inlineManifest にする**
      (inlineManifests 自体は Helm を実行できないので、描くのは手元)。
      **本物の値で焼いたドリルで、`apply-config` 1 回で bootstrap 層が全部立ち上がることを
      確認済み**([docs/talos.md](docs/talos.md)「ブートドリル 4 回目」)。
      層の分け方と根拠は [docs/decisions.md](docs/decisions.md)「Talos の起動順序をどう組むか」。
      - [x] ~~Cilium を inlineManifests に~~ **[talos/render.sh](talos/render.sh) が描く(2026-09-08)。**
            `bootstrap/cilium/` から `helm template` して `KubeInlineManifestConfig` に包む
            (machine config に値を二度書かない)。**Talos 固有の上書き**
            ([talos/cilium-values.yaml](talos/cilium-values.yaml)、KubePrism と cgroup)も
            ここで重ねる。local-path と metrics-server も同じ仕組み。CI も同じスクリプトを
            使うので「CI は通るが当日は通らない」が起きない。**`upgrade-k8s` の前には必ず描き直す** ── 古いまま流すと
            走っている Cilium が巻き戻る(docs/decisions.md「machine config と Cilium の chart」)。
            **inlineManifests は「作りっぱなし」ではない**(2026-09-08 に VM で実測) ──
            `talosctl upgrade-k8s` を通せば**更新も削除もされる**。だから Talos では
            `helm upgrade` を使わず、`render.sh` → `upgrade-k8s` が更新経路になる
            (docs/talos.md「inlineManifests は『更新できない』ではない」)
      - [x] **ArgoCD と infisical を inlineManifests に(2026-09-08)。**
            [talos/render.sh](talos/render.sh) が `bootstrap/<name>/helmchart.yaml`(SOPS)を
            復号して `chart` / `repo` / `version` / `values` を取り出し、`helm template` する。
            **値をここに写さない**のは Cilium と同じ方針。
            **ArgoCD の CRD 3 つだけは URL で渡す** ── 1.83 MB あって描き出しの 95% を占め、
            埋めると machine config が 271 KB → 2 MB になる(`crds.install: false` +
            `KubeExternalManifestConfig`。版は chart の `appVersion` から引く)。
            **`version:` が入るまでは警告して飛ばす**(下の項目)。
            **CI 側には置かない** ── 導入に CRD/ClusterRole/Secret が要り、
            狭く保っている CI の RBAC の意味が消えるため
      - [x] **SOPS 済みの Secret を inlineManifests に(2026-09-08)。**
            `infisical/secrets.yaml`(**infisical はこれが無いと起動しない**)と
            `cert-manager/cloudflare-secret.yaml`。残る 2 つ
            (`argocd/helmchart.yaml` / `infisical/helmchart.yaml`)は Secret ではなく
            chart なので、上の項目で描いている。**machine config はもともと SOPS 済み**なので
            信頼水準は変わらず、CI に age 鍵を渡さない方針も保てる
      - [x] **cert-manager も inlineManifests に(2026-09-08)。** k3s 期は
            `helm upgrade --install` で入れていた。**無いと証明書が 1 枚も発行されず、
            Gateway の HTTPS リスナーに載せる Secret ができない。**
            CRD 6 つ(1.30 MB、描き出しの 97%)は URL で渡す
      - [x] **`bootstrap/apiserver/rbac.yaml` も inlineManifests に(2026-09-08)。**
            [talos/render.sh](talos/render.sh) が `bootstrap/apiserver/rbac.yaml` から描く
            (写さない)。CI が自分の権限を作れない ── bootstrap-apply.yml は
            `bootstrap/apiserver/` を除外している(自分の権限を書き換えられるため)ので、
            k3s 期は手で当てていた
      - [x] ~~infisical を `apps/` の ArgoCD Application に移す~~ **移さないと決めた(2026-09-08)。**
            鶏卵は確かに無かった(ArgoCD は Secret が無くても起動し、SSO だけが効かない)が、
            **chart が DB と Redis のパスワードを Deployment の平文 env に焼き込む**ので、
            ArgoCD の Application には値を置けない。`existingSecret` は subchart には効くが
            **本体の接続文字列には効かず、chart の既定値で自分の DB に繋げなくなる**
            (`helm template` で確認)。Redis 側には逃げ道すら無い。
            **ArgoCD 本体と同じく inlineManifests に載せる。**
            経緯は [docs/decisions.md](docs/decisions.md)「infisical だけは ArgoCD に移せない」
- [x] **ファイルの PVC バックアップを k8up 側に寄せた(2026-09-08)。** ホストの `k3s-backup` は
      **Talos にはシェルが無い**ので持っていけない。**全 11 namespace で成功を確認済み** ──
      SQLite 6 本は `backupcommand`、ファイルは PVC の注釈。`denpa-data` は DB とファイルが
      同居しているので `k8up.io/backup-restic-args` で `denpa.db*` を除外している。
      portainer(boltdb・シェル無し)だけは整合を保証できないファイルコピーで割り切った。
      対象の切り分けは [apps/k8up/README.md](apps/k8up/README.md)。
      **残るのはホストのスクリプトを畳むことだけで、それは Talos に移る時点。**
- [ ] **`bootstrap/storageclass.yaml`(`local-path-retain`)を消す。** いま 21 本の PVC が名前を
      参照していて、**バインド済み PVC の `storageClassName` は API が変更を拒否する**ので今は消せない。
      PV 側の reclaim policy は全部 `Delete` に揃えてあるので挙動はもう既定の `local-path` と同じ。
      再構築でストレージを引き直すときに、各アプリのマニフェストから `local-path-retain` の指定ごと外す。
- [ ] **PT3**: 上流 PR が間に合わなければ KubeVirt にパススルーして tuner-agent だけ VM で動かす。
- [x] **git と実機の helm 値がずれていないことを確認した(2026-09-08)。**
      cert-manager / argocd / infisical の 3 つとも一致。**machine config は git の値で
      描く**ので、ずれていると移行した瞬間に別物が入る。
      **CI では自動化できない**(helm の値はリリースの Secret の中で、`bootstrap-applier` に
      Secret の権限は意図的に無い)。手順と注意は [bootstrap/README.md](bootstrap/README.md)。
- [x] **argocd と infisical の chart の版を固定した(2026-09-08)。**
      argo-cd 10.8.1 / infisical-standalone 1.10.0。それまでは `HelmChart` CR に
      `version:` が無く、**そのときの最新**が入っていた。手順は
      [bootstrap/README.md](bootstrap/README.md)「Helm で入れるもの」。
- [ ] Infisical → operator → 各アプリの順で疎通確認。DNS(cloudflare-ddns)、netbird、AdGuard の公開リゾルバを確認。

### Phase 3 — Talos 定常運用

- [x] ~~k8up の失敗通知~~ **入れた(2026-09-08)。** [apps/k8up/notify.yaml](apps/k8up/notify.yaml) の
      CronJob が日次で Mattermost に投げる。**見るのは restic の中身**で、k8up のオブジェクトは
      掃除されるので証拠にならない。「失敗した」だけでなく「そもそも走らなかった」も拾う。
      `restic check` も [schedules.yaml](apps/k8up/schedules.yaml) に 1 本置いた。
      **PVC のファイルを寄せるほうも済んでいる**(上の Phase 2)。
- [ ] etcd スナップショットを定期化(talosconfig を Secret にした CronJob か、手元マシンの timer)。同じバケットへ。
- [ ] 四半期ごとに VM で復元リハーサル(PV + etcd の両方)。
- [x] **`talosctl upgrade` / `upgrade-k8s` の手順を README に(2026-09-08)。**
      [talos/README.md](talos/README.md)「上げ方 / 当て直し方」。
      **`upgrade-k8s` は inlineManifests の reconcile も兼ねる**(2026-09-08 に VM で実測。
      [docs/talos.md](docs/talos.md))ので、Talos 期の「bootstrap 層を当て直す」操作でもある。


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
  受け皿は [apps/k8up/k8up-secrets.yaml](apps/k8up/k8up-secrets.yaml)(2026-09-08)。
  **Infisical の `/k8up/k8up-global` に 6 つのキーを入れるまで当てない** ── operator は
  Infisical にあるものだけを書くので、足りないとバックアップが全部落ちる。

## 未決事項

- ~~**`local-path-retain` をやめて「git で消したものは消える」に寄せる。**~~ **実施した(2026-09-07)。**
  `Prune=false,Delete=false` は全 PVC から外し、既存 PV の reclaim policy も `Delete` にパッチ済み。
  **残るのは `storageClassName` の指定を消すことだけ**で、バインド済み PVC では API が拒否するため
  Talos の再構築時(Phase 2)。誤削除の後ろ盾は日次の restic 1 本になった。
- **外部公開の一覧を出す画面(未着手)。** 内部の通信は **Hubble** を入れて解決した
  (2026-09-07、`hl.doany.io`。認証は `*.s.doany.io` と同じ oauth2-proxy 前段方式)。
  残っているのは「何がインターネットに出ているか」の一枚で、いまは
  `kubectl get httproute,grpcroute -A` が唯一の正確な索引。
