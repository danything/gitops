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
- [ ] PSA のラベルが要る namespace を洗い出して manifest に入れる(`local-path-storage`、`wireguard`、`denpa`)。
- [ ] HelmChart CRD 依存(argocd / infisical / push-bridge)を ArgoCD の Application に書き直す。
- [ ] Envoy Gateway + cert-manager + MetalLB を組み、`ingress2gateway` で HTTPRoute を作って各 repo に **Ingress と並置**でコミットする。
- [ ] k8up を導入し、Phase 0 と同じ restic リポジトリ(別 path / tag)に PVC バックアップと `backupcommand` の dump が取れること。
- [x] `talosctl etcd snapshot` → **空のディスクから `bootstrap --recover-from` で復旧するところまで確認**(2026-09-06)。
      k8s オブジェクトは戻るが **PV の中身は戻らない**ので、Talos 期の復元は etcd → PV データ(restic/k8up)の 2 段になる。
      詳細は [docs/talos.md](docs/talos.md)。

### Phase 1.5 — k3s のまま Cilium + Gateway API に寄せる

**決定 2026-09-06**: CNI を Cilium にして、kube-proxy・ServiceLB・Traefik をまとめて置き換える
(理由と検証結果は [docs/decisions.md](docs/decisions.md)「ルーティングの選定」)。
**Talos で後から替えるのが高いのは CNI だけ**なので、k3s のうちにここを済ませて OS 交換時の変数を減らす。
VM では一通り動くことを確認済み。**本番は CNI 交換で全 Pod の通信が一度切れる**ので、段階を分ける。

- [ ] **Gateway API v1.6.1 の CRD を入れる**(Cilium 1.20 はこのバージョンを要求する。v1.4.0 だと
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
      本番トラフィックはまだ Traefik(hostPort 80/443)が捌いている。
- [ ] **切り替え前に残っているもの**:
      - `px.doany.io`(3proxy)。**TLS 終端 + 素の TCP は Cilium の Gateway では直接書けない**ことが判明
        (decisions.md「3proxy は素直に移せない」)。Pod 側に TLS 終端のサイドカーを足して passthrough にする案が有力
      - forward-auth の 2 本(Traefik ダッシュボードと `sub`)。**Cilium の Gateway では賄えない**ので、
        oauth2-proxy を前段プロキシにするか、この 2 本のためだけに Traefik を残すか決める
      - yuzuriha の `compress` ミドルウェア(Gateway API に相当機能なし。諦めるかアプリ側で)
- [ ] **切り替え本番**: Traefik の hostPort 80/443 を外し、Gateway の待ち受けをそこに移す(同時に行う)。
      そのあと `disable: [traefik]` と Ingress の削除。
      `IngressRoute` 4 本と `Middleware` 4 つ、`IngressRouteTCP`(3proxy → TCPRoute)は手で移す。
      **forward-auth は Cilium の Gateway では賄えない**(OIDC 内蔵なし、ExternalAuth も未実装)。
      該当は Traefik ダッシュボードと `sub` の 2 本だけなので、oauth2-proxy を前段プロキシにするか、
      そのルートだけ別コントローラに残す(decisions.md「認証は Cilium の Gateway では賄えない」)。
- [ ] 全部移ったら Gateway の待ち受けを 80/443 の hostPort(または本番アドレス)に移し、
      Traefik を落とす(`disable: [traefik]`)。**Traefik が hostPort 80/443 を持っている間は Gateway と共存できない**ので、
      切り替えは同時に行う。
- [ ] クライアント IP の保持を決める(`externalTrafficPolicy: Local` か PROXY protocol)。
      `Cluster` のままだと SNAT されて AdGuard のクライアント別統計や IP 制限が壊れる。

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
- [ ] PSA のラベルを付ける(`local-path-storage`、`wireguard`、`denpa`)。
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

- **Entra ID のトークンを小さくして redis を廃止できるか。** いまの forward-auth は oauth2-proxy + redis で、
  redis はセッション(トークン)を持つためだけに居る。Entra 側で**グループクレームを全部載せるのをやめて
  アプリロールに切り替える**と `roles: ["admin"]` の数十バイトになり、oauth2-proxy を Cookie セッション
  (`--session-store-type=cookie`)に変えられて redis が消せる。実測ではいまのセッションが 4293 バイトで、
  Cookie の 4096 バイト制限に収まっていない。手順は Entra の アプリの登録 > トークン構成 で
  groups クレームを外し、アプリロールを定義してユーザー/グループを割り当てる。
  副次的に、将来 Gateway 内蔵の OIDC(Envoy Gateway など)を使う道も開く。
- **Hubble を入れるか。** Cilium に同梱の可視化(フローログ、サービスマップ、UI)。CNI を Cilium にしたので
  追加インストールは Helm の値 2 つ(`hubble.relay.enabled` と `hubble.ui.enabled`)で済む。
  判断材料: 単一ノードでは Relay + UI で Pod が 2 つ増える、フローログはメモリを食う(既定のバッファは 4095 flow/ノード)、
  一方で Cilium の NetworkPolicy を書くときに「何が落ちているか」が見えないと実質デバッグできない。
  **NetworkPolicy を書き始めるなら実質必須、書かないなら不要**、という切り分けで決める。
