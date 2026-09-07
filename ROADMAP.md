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
- [ ] 実機固有の確認: bond0(balance-alb、eno1+eno2)、eno4 の static、**IPv6 の token `::2` 相当**(無ければ
      stable-privacy + cloudflare-ddns で代替)、wg-easy の hostNetwork UDP 51820。QEMU の user-mode では試せない。
- [x] **PSA のラベルが要る namespace を洗い出して manifest に入れた(2026-09-07)。** 走っている Pod の spec を
      直接数えたら想定より多く、9 つあった。**baseline は hostPort も弾く**のを見落としていた。
      一覧と洗い出しのコマンドは [docs/talos.md](docs/talos.md)「PSA のラベル」。
- [ ] HelmChart CRD 依存を ArgoCD の Application に書き直す。
      - [x] cloudflare-ddns・infisical-secrets-operator・infisical-push-bridge(2026-09-07)。
            **Pod を入れ替えずに引き取れる**ことと、**CR を消すとアンインストールが走る**ことが分かった。
            手順は [docs/decisions.md](docs/decisions.md)「HelmChart CRD から ArgoCD の Application へ」。
      - [x] yosegaki(PVC 持ち。blog リポジトリ側、2026-09-07)。
      - [ ] erpnext。**chart が Job 名に描き出した時刻を入れる**ので、そのままでは同期のたびに
            サイト作成ジョブが作り直される。`jobs.createSite` と `jobs.configure` を止めてから移す
            (decisions.md「erpnext だけは素直に移せない」)。
      - [ ] infisical(Postgres の PVC 持ち。ArgoCD に預けると鶏卵になるので Talos では inlineManifests)。
      - argocd は移さない(自分自身。Talos では inlineManifests)。
- [ ] k8up を導入し、Phase 0 と同じ restic リポジトリに PVC バックアップと `backupcommand` の dump が取れること。
      - [x] operator を入れて、**`backend` を書かずにグローバル設定へ寄せれば R2 へ書ける**ことを確認(2026-09-07)。
            endpoint も含めて秘密は git に置かない形にできた。`backend.envFrom` だけでは動かない
            (k8up が空の `RESTIC_REPOSITORY` を必ず入れて上書きする)。詳細は [apps/k8up/README.md](apps/k8up/README.md)。
      - [ ] `Schedule` を namespace ごとに置く。**`Prune` がリポジトリ全体を見るかどうかを先に確かめる**
            (ホストのスクリプトのスナップショットを消しかねない)。
      - [ ] DB は `k8up.io/backupcommand` で dump を流す。ホストのスクリプトには無い利点で、ここが本当の動機。
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
        **hostPort 8444** で直接受ける形にした。443 では HTTPS 終端と TLS passthrough が同居できない
        (ProtocolConflict)ため。8443 は Mattermost calls が先に取っている。**クライアントのポート変更が要る**
      - [x] forward-auth の 2 本。`sub`(`*.s.doany.io`)は **oauth2-proxy を前段プロキシにする方式**で移した
        (専用インスタンス `auth-sub` が `--upstream` で LAN のホストへ中継。コールバックは既存の
        a.doany.io 側が受け、cookie secret と redis を共有)。Traefik ダッシュボードは Traefik ごと消えるので対処不要
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

- [ ] k8up のスケジュールと保持(`keep-daily 7 / weekly 4 / monthly 6`)、失敗通知。
- [ ] etcd スナップショットを定期化(talosconfig を Secret にした CronJob か、手元マシンの timer)。同じバケットへ。
- [ ] 四半期ごとに VM で復元リハーサル(PV + etcd の両方)。
- [ ] `talosctl upgrade` / `upgrade-k8s` の手順を README に。


## 未決事項

- **redis を捨てられるか(検証待ち)。** **「グループクレームが大きいから redis が要る」は誤りだった**
  (2026-09-07)。所属グループは 2 つだけで、4293 バイトのセッションの中身は ID / アクセス /
  リフレッシュの各トークンそのもの。`--session-cookie-minimal` でその 3 つを落とし、
  Cookie セッションに切り替え済み。**実機でログインし直して通ることを確かめたら redis を消す。**
  それまで redis は動かしたままにしてある。経緯は [docs/entra.md](docs/entra.md)。

- ~~**Hubble を入れるか。**~~ **入れないと決めた(2026-09-07 本人判断)。** 単一ノードで Relay と UI の
  Pod が 2 つ増えるわりに、NetworkPolicy を書き始めるまでは見る場面が無い。書き始めるときに入れ直す。
