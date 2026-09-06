# ROADMAP — バックアップ方式と Talos Linux への移行

いまの「Ubuntu + k3s(sqlite)」は暫定構成で、最終形は **Talos Linux**(ホストに repo も clone も置かない)。
ここには**やること と 進捗**だけを置く。**なぜそうしたかは [`docs/decisions.md`](docs/decisions.md)**、
Talos のインストールメディアは [`docs/talos-install-media.md`](docs/talos-install-media.md)、
復元リハーサルは [`docs/restore-drill.md`](docs/restore-drill.md)。

## ロードマップ

### Phase 0 — k3s のまま restic 化(暫定構成の安全確保)

- [x] R2 にバケット `doany-restic` を作成(2026-09-06)。
- [x] R2 の API トークン発行 → `/etc/k3s-backup/env` を作り `age -p -o backup/env.age` でコミット(2026-09-06)。
- [x] パスフレーズを Edge と紙へ(本人作業、2026-09-06)。
- [x] `install.sh` を実機(Ubuntu 26.04)で実行、`restic init` 済み、timer 有効(毎日 04:00 JST)。2026-09-06。
- [x] R2 の使用量は 3.28 GiB(重複排除・圧縮後、論理 12.28 GiB)で無料枠 10 GB 内。操作回数と egress は桁違いに余裕。
      通知に実サイズとスナップショット数を出すようにした。
- [x] 容量対策(2026-09-06): AdGuard のクエリログ保持を 90d → 7d、保持世代を 17 → 13。
      録画データは価値を優先して**含めたまま**にする(decisions.md「バックアップに何を含めるか」)。
- [x] 初回: `--no-scale` の暖機 51 秒(5.3 GiB)→ 本番 197 秒(うち 120 秒は denpa の Pod 終了待ちで無駄)。
      denpa は terminationGracePeriodSeconds=21900 なので scale down 対象から外した(`SKIP_SCALE_NAMESPACES`)。以後の停止は 30 秒前後の見込み。
- [x] スクリプト一式(`backup/k3s-backup`、`backup/k3s-backup.{service,timer}`、`backup/install.sh`、`restore.sh`)。
- [x] `/usr/local/bin/k3s-backup`: scale down → `sqlite3 .backup` → `restic backup`(PV ディレクトリ、`server/{tls,cred,token}`、state.db スナップショット、
      `/etc/rancher/k3s/config.yaml`、`/etc/NetworkManager/system-connections/`、`conf.d/20-no-auto-default.conf`、スクリプトと unit 自身)→ scale up →
      `restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune`。認証情報は `/etc/backup/env`(root:600)。
- [x] systemd timer で毎日実行。Mattermost への失敗通知(既存の webhook)。
- [x] timer 経由の起動を drop-in で 2 分後に発火させて確認(TriggeredBy=k3s-backup.timer、Result=success、webhook HTTP 200)。2026-09-06。
- [x] `restore.sh` と `env.age` をこの repo の `recovery/` に置いた(2026-09-06)。復元に GitHub ログインは要らない。中身は: restic インストール → `restore latest --target /` → k3s を `INSTALL_K3S_SKIP_START=true` で導入 →
      state.db 差し替え → `systemctl start k3s` → timer 有効化。**init.sh の「clone 先へ symlink」をやめ、ホストに repo を置かない。**
- [x] 復元リハーサル(Hyper-V は権限が無くサーバ上の QEMU/KVM で実施、2026-09-06)。結果と見つかった 3 件は
      [docs/restore-drill.md](docs/restore-drill.md)。backup.sh のスナップショット順序と restore.sh の DNS は修正済み。
- [x] **operator 製 Secret を ArgoCD が prune する問題**(docs/restore-drill.md の 3)→ ArgoCD の `resource.exclusions` で Secret を外した(2026-09-06)。
- [x] 修正後のスナップショットでもう一度リハーサル(2026-09-06、04:00 を待たず手動でバックアップを取って実施)。
      **3 件とも解消**し、Argo CD が Secret を消していたことも確定した([docs/restore-drill.md](docs/restore-drill.md) の「2 回目」)。
- [x] **クラスタにしか無い Secret を Infisical に移す**(docs/restore-drill.md の 5)。CR は
      `apps/wireguard/wg-easy-secrets.yaml` に置いた。`tamasagashi/ghcr-pull` は元から Infisical 管理で対処不要、
      `blog/artalk-secrets` は未使用。
- [x] wireguard は Secret を持たない形にした(2026-09-06)。`INIT_*` はセットアップ済みなら無視され、OIDC は
      Entra が `email_verified` を返さず wg-easy が必須にしているため使えない。どちらの `secretKeyRef` も
      `optional: true` にしたので、復元直後に Secret が無くても起動する。
- [x] **ghcr の pull 認証を node 単位に寄せた**(2026-09-06)。`/etc/rancher/k3s/registries.yaml` に資格情報を置き、
      k3s を再起動して private イメージの pull を確認。`imagePullSecrets` と `ghcr-pull` の CR 2 つ、Secret 2 つを削除
      (tamasagashi#66、worklog-cloud#109)。`registries.yaml` はバックアップ対象に追加済み。
      **Talos では machine config の `machine.registries.config."ghcr.io".auth` に同じものを書く。**
- [x] backup.sh / init.sh / setup-network.sh を削除(2026-09-06、リハーサル通過後)。repo 内の平文秘密
      (Infisical の鍵、GitHub App 秘密鍵、Cloudflare トークン、Postgres パスワード)は **SOPS + age** で
      該当キーだけ暗号化した(`.sops.yaml`)。鍵は `recovery/sops-age.key.age` に env.age と同じパスフレーズで封じてある。

### Phase 0.5 — 各 repo の `k3s/` ディレクトリ改名(k3s 固有の名前をやめる)

対象は `k3s/argocd.yaml` を持つ 8 repo: denpa, lgtm, blog, yuzuriha, tamasagashi, worklog-cloud, xool, k3s-gitops(repo 名も)。
案は `deploy/`(ツール名を含まない。Talos の後に別のものへ移っても名前が古びない)。

- [x] `argocd/repos.yaml` の scmProvider filter と git generator を **両方のパス**(`k3s/argocd.yaml` と `deploy/argocd.yaml`)を見る形にし、
      `preserveResourcesOnDeletion: true` を付けて apply(88a8ed3、クラスタ反映確認済み 2026-09-06)。
- [x] 8 repo で `git mv k3s deploy` + `argocd.yaml` の `sourcePath` を直す PR をマージ(2026-09-06):
      denpa#66、lgtm#17、blog#20、yuzuriha#8、tamasagashi#63、worklog-cloud#106、xool#128、k3s-gitops#2。
      `.dockerignore`、workflow の `paths` フィルタ、README も追従。blog は公開記事 `renewal.md` のパス表記も直した。
      ArgoCD の全 Application が `deploy` パスで Synced/Healthy を確認。
- [x] repos.yaml から `k3s/argocd.yaml` 側を削除。k3s-gitops は `gitops` に repo 名を変更(GitHub がリダイレクトする。手元の clone は `~/dev/gitops`)。

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
