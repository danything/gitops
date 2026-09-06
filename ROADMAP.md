# ROADMAP — バックアップ方式と Talos Linux への移行

いまの「Ubuntu + k3s(sqlite)」は暫定構成で、最終形は **Talos Linux**(ホストに repo も clone も置かない)。
ここには**やること と 進捗**だけを置く。**なぜそうしたかは [`docs/decisions.md`](docs/decisions.md)**、
Talos のインストールメディアは [`docs/talos-install-media.md`](docs/talos-install-media.md)、
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
      [docs/talos-install-media.md](docs/talos-install-media.md) の「machine config の作法」にまとめた。
- [ ] `talos/talconfig.yaml` を 1.14 の形に書き直す(talhelper + SOPS)。いまの内容は 1.13 以前の書き方で通らない。
- [ ] 実機固有の確認: bond0(balance-alb、eno1+eno2)、eno4 の static、**IPv6 の token `::2` 相当**(無ければ
      stable-privacy + cloudflare-ddns で代替)、wg-easy の hostNetwork UDP 51820。QEMU の user-mode では試せない。
- [ ] PSA のラベルが要る namespace を洗い出して manifest に入れる(`local-path-storage`、`wireguard`、`denpa`)。
- [ ] HelmChart CRD 依存(argocd / infisical / push-bridge)を ArgoCD の Application に書き直す。
- [ ] Envoy Gateway + cert-manager + MetalLB を組み、`ingress2gateway` で HTTPRoute を作って各 repo に **Ingress と並置**でコミットする。
- [ ] k8up を導入し、Phase 0 と同じ restic リポジトリ(別 path / tag)に PVC バックアップと `backupcommand` の dump が取れること。
- [ ] `talosctl etcd snapshot` → 別 VM で `talosctl bootstrap --recover-from` の復元リハーサル。

### Phase 2 — 切り替え(停止を伴う)

- [ ] 作業中の見せ方は未定(メンテページは一旦見送り)。調べた事実だけ残す:
      サブドメインは `*.doany.io` のワイルドカード CNAME 1 本でほぼ全部賄われていて(明示レコードは apex と
      `l` `ts` `w` `x` `y` の 5 つだけ)、**このワイルドカードの proxied を倒すだけで全サブドメインが Cloudflare 受けになる**。
      ただし Cloudflare 単体では 521 画面しか出ないので、読めるページを出すには Worker か Pages が要る。
      proxied にすると HTTP/HTTPS 以外(WireGuard の UDP、AdGuard の DNS/DoT、3proxy の TCP)は通らない。
- [ ] **作業は LAN(10.0.0.2 / 10.10.0.4)か iLO(10.0.0.3)から行う。** cloudflared 経由の ssh は使えない。
- [ ] **Ingress を Traefik から Envoy Gateway に載せ替える**(理由は decisions.md「ルーティングの選定」)。
      Phase 1 で用意した HTTPRoute を有効化し、cert-manager(Cloudflare DNS-01)で証明書を出し、
      MetalLB で LoadBalancer 型 Service(adguardhome-dns、mattermost-calls)を賄う。
      `SecurityPolicy` の OIDC に寄せて `auth` namespace の oauth2-proxy と redis、forward-auth の Middleware を撤去する。
      IngressRouteTCP(3proxy)は TLSRoute に、`traefik-acme` の PVC は cert-manager の Secret に置き換わる。
- [ ] **service の IPv6 CIDR を `fd43::/108` に変える**(Talos は `/64` を受け付けない)。ClusterIP が振り直しになる。
- [ ] **PT3**: 上流 PR が間に合わなければ KubeVirt にパススルーして tuner-agent だけ VM で動かす(decisions.md「PT3 チューナー」)。
- [ ] **ghcr の資格情報を machine config に移す**(`machine.registries.config."ghcr.io".auth`)。k3s の registries.yaml は役目を終える。
- [ ] 最終バックアップ(Phase 0 のホスト側 restic)を取り、`restic check` を通す。
- [ ] Talos を実機にインストール、machine config 適用。
- [ ] k8s オブジェクトは etcd 復元ではなく **git から ArgoCD で再構築**(k3s 固有の HelmChart 等が etcd に混ざっているため)。
- [ ] PV データを restic から新しい local-path ディレクトリへ Job で復元(PVC 名 / namespace を合わせ、`pvc-<uid>` の付け替えは PV を手で作って bind)。
- [ ] Infisical → operator → 各アプリの順で疎通確認。DNS(cloudflare-ddns)、wireguard、AdGuard の公開リゾルバを確認。
- [ ] 旧ホストのスクリプトと timer を廃止。この repo の k3s 期のファイルを削除。

### Phase 3 — Talos 定常運用

- [ ] k8up のスケジュールと保持(`keep-daily 7 / weekly 4 / monthly 6`)、失敗通知。
- [ ] etcd スナップショットを定期化(talosconfig を Secret にした CronJob か、手元マシンの timer)。同じバケットへ。
- [ ] 四半期ごとに VM で復元リハーサル(PV + etcd の両方)。
- [ ] `talosctl upgrade` / `upgrade-k8s` の手順を README に。


## 未決事項

いまのところ無し(2026-09-06 時点)。決着したものは [`docs/decisions.md`](docs/decisions.md) に移した。
