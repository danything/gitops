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

### Phase 1.5 — k3s のまま LB / Ingress を試す(Talos より先)

**OS 交換・コントローラ交換・API モデル移行を同時にやらない**([docs/decisions.md](docs/decisions.md)「段階移行」)。
単一ノードなので、同時にやると障害の切り分けができない。Gateway API は可搬なので各段階で戻せる。

- [ ] **Entra ID の生の ID トークン長を測る(最優先)。** ブラウザでログインして `IdToken` Cookie の長さを見るのが早い。
      4096 を超えると Envoy Gateway の OIDC が無言で落ちる(envoyproxy/gateway#7315)。
      参考: oauth2-proxy が redis に持つセッション(3 トークン + メタデータをまとめて暗号化)は **4293 バイト**だった(2026-09-06 実測)。
      個々のトークンは 4096 を下回っているはずだが余裕は小さい。4 KB 超ならクレームを削るか、Envoy Gateway の OIDC を諦めて
      oauth2-proxy を残す(その場合 B の主要な動機が消えるので A の継続も再検討する)。
- [ ] Gateway API の CRD を自前で入れる。
- [ ] **ServiceLB を MetalLB に置き換える**(`--disable servicelb`)。Talos には ServiceLB 相当が無いので、
      この差分を k3s のうちに埋めておくと OS 交換時の変数が減る。**単一ノードなら Envoy Gateway を hostNetwork にして
      LB コントローラ無しで済ませる案もある**ので、両方試して決める。
- [ ] Envoy Gateway を入れる。**Traefik は止めない**(`--disable traefik` は不要)。GatewayClass が別なので並走でき、
      HTTPRoute を 1 つずつ移せる。まず 1 サービスだけ移して観察する。
- [ ] cert-manager を Gateway API 対応で入れる(`config.enableGatewayAPI=true` の明示が要る。**まだ Beta**)。
- [ ] `externalTrafficPolicy` かクライアント IP の保持方法を先に決める(`Cluster` だと SNAT されてレート制限や IP 制限が壊れる)。

### Phase 2 — k3s → Talos(停止を伴う。**Ingress 構成は変えない**)

OS 交換だけに集中する。Ingress は Phase 1.5 で落ち着いた構成のまま持っていく。

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

### Phase 2.5 — Ingress 15 本を HTTPRoute に移す(落ち着いてから)

- [ ] `ingress2gateway` で機械変換 → 各 repo の `deploy/` に **Ingress と並置**でコミット。
- [ ] `IngressRoute` 4 本と `Middleware` 4 つを手で移す(ここが実工数。中身の棚卸しが要る)。
- [ ] `IngressRouteTCP`(3proxy)は TLSRoute か TCPRoute へ。
- [ ] 全部 Gateway API に揃った時点で Ingress 側と Traefik を落とす。HTTPRoute はコントローラを差し替えてもそのまま動く。

### Phase 3 — Talos 定常運用

- [ ] k8up のスケジュールと保持(`keep-daily 7 / weekly 4 / monthly 6`)、失敗通知。
- [ ] etcd スナップショットを定期化(talosconfig を Secret にした CronJob か、手元マシンの timer)。同じバケットへ。
- [ ] 四半期ごとに VM で復元リハーサル(PV + etcd の両方)。
- [ ] `talosctl upgrade` / `upgrade-k8s` の手順を README に。


## 未決事項

いまのところ無し(2026-09-06 時点)。決着したものは [`docs/decisions.md`](docs/decisions.md) に移した。
