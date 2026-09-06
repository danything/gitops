# ROADMAP — バックアップ方式と Talos Linux への移行

今の「Fedora + k3s(sqlite)+ bootstrap repo を clone して init.sh」は暫定構成。
最終形は **Talos Linux** で、ホストに repo も clone も置かない。
このファイルは、その移行を前提にしたバックアップツールの選定理由と手順の記録(2026-09-06 時点)。

## 移行の前後で変わらないもの・捨てるもの

移行の途中でバックアップの互換性が切れないように、「不変にするもの」を先に決める。

| 不変(移行をまたいで同じ) | 捨てる(k3s 期限定) |
| --- | --- |
| restic リポジトリ形式・パスフレーズ・バケット | ホスト側 backup スクリプト + systemd timer |
| local-path provisioner の PV ディレクトリ構造(`pvc-<uid>_<ns>_<name>`) | state.db の sqlite `.backup` スナップショット |
| `bootstrap/` の中身(Argo CD・Infisical・Traefik・auth の定義)。Talos では machine config の `cluster.inlineManifests` に載せる(下記) | |
| 公開の復元手順(秘密を含まない、`curl \| sh` できる)という**性質** | setup-network.sh / k3s-server-config.yaml / init.sh / **restore.sh**(k3s 期専用。Talos 期は machine config + etcd + k8up の Job に置き換わる) |
| Infisical のデータ(Postgres PVC)と `ENCRYPTION_KEY` | HelmChart CRD(helm.cattle.io)、k3s 同梱の Traefik / ServiceLB |
| ArgoCD + ApplicationSet(repos.yaml)+ 各 repo の `argocd.yaml`(ディレクトリ名は改名予定、下記) | firewalld 無効化などホストの手作業 |
| | **Traefik**(k3s 同梱だから使っていただけ。IngressRoute / Middleware(forward-auth)/ mydnschallenge ACME は Talos では持ち込まない) |

Talos ではホストに触れないので、「k8s オブジェクト」は etcd スナップショット、「ホスト設定」は machine config(git 管理)、
「PV データ」だけが従来どおりバックアップツールの仕事になる。**ツール選定は PV データの部分にしか効かない。**

## ツール選定(比較の結論)

判断基準は、(1) k3s 期は ホスト側で、Talos 期は in-cluster で動かせること、(2) その両方で **同じリポジトリ・同じ復元コマンド** が使えること、
(3) 復元の依存物が「バイナリ 1 つ + 秘密 1 組」で済むこと、の 3 つ。

| 候補 | k3s 期(ホスト) | Talos 期(in-cluster) | 判定 |
| --- | --- | --- | --- |
| **restic** | systemd timer で直接 | **k8up**(restic の operator)か restic イメージの CronJob | ◎ 両期で同じ repo 形式。手動復元も `restic restore` 1 本 |
| kopia | 同上 | Velero の node-agent が kopia だが Velero 固有のレイアウトで、kopia CLI からの手動復元が素直でない | ○ 単体性能は上だが後継が繋がらない |
| Velero | 使えない(ホスト対象外) | k8s オブジェクトも一緒に取れる | △ Talos では etcd スナップショットと役割が被り、復元に Velero 自体の導入が要る |
| k8up 単体 | 使えない | ○ | k3s 期のホスト側(state.db、`/etc`)を別途どうにかする必要がある |
| tar + rclone crypt | ○ | 使えない | △ 変更最小だが Talos に持っていけない、整合性 `check` が無い |
| borg / duplicacy | ○ | 使えない or ライセンス | × |
| Longhorn 等のストレージ層バックアップ | ストレージ入れ替え | ○ | × 単一ノードには過剰 |

**結論: restic。** k3s 期はホストの systemd timer、Talos 期は k8up に乗り換えるが、リポジトリもパスフレーズも復元コマンドも変えない。
k8up の中身は素の restic なので、k8up が気に入らなければ CronJob + restic イメージに落とせるし、k8up の取った
スナップショットも手元の restic CLI で読める。将来 rustic(restic 互換の Rust 実装)へ逃げる道もある。

### 手で持つもの(根っこ)

これ以外は全部バックアップか git から復元できる状態を保つ。パスワードマネージャ + オフライン 1 部(紙か USB)。

1. age のパスフレーズ(決定 2026-09-06: `/etc/k3s-backup/env` を `age -p` で暗号化した `env.age` をこの repo の `recovery/` に置く。
   env の中身 = restic のパスフレーズ + R2 の access key / secret key + エンドポイント)
2. Talos 期のみ: `talosctl gen secrets` の secrets.yaml(同じく age で repo に置く)

秘密 gist や平文コミットにしなかった理由: R2 の鍵は「バックアップを消せる鍵」で、GitHub のトークンはあちこちに
散っている(`~/.git-credentials`、gh、Actions、ArgoCD の App 資格情報)ので、GitHub 側が丸ごと漏れても
バックアップだけは無事な状態を残す。

リモートは Cloudflare R2 のバケット `doany-restic`(APAC、Standard)に決定(2026-09-06)。API トークンは
Object Read & Write をこのバケットだけに絞った Account API token。
復元時に `rclone config` の対話が要らなくなり、in-cluster(k8up)からも同じ設定で使える。

## DB の整合性の取り方

- **k3s 期**: 今の backup.sh どおり、対象 namespace の Deployment/StatefulSet を scale down してからコピー。
  停止時間を縮めたければ scale down → LVM/btrfs スナップショット → scale up → スナップショットから restic、にする(FS を要確認)。
- **Talos 期**: scale down せず、k8up の `k8up.io/backupcommand` 注釈で `pg_dump` / `mariadb-dump` を取るアプリ整合方式に切り替える。
  対象: infisical(Postgres)、mattermost(Postgres)、erpnext(MariaDB)。ファイルだけの PV(メディア、adguard、wireguard)はそのまま。

## ロードマップ

### Phase 0 — k3s のまま restic 化(暫定構成の安全確保)

- [x] R2 にバケット `doany-restic` を作成(2026-09-06)。
- [x] R2 の API トークン発行 → `/etc/k3s-backup/env` を作り `age -p -o backup/env.age` でコミット(2026-09-06)。
- [x] パスフレーズを Edge と紙へ(本人作業、2026-09-06)。
- [x] `install.sh` を実機(Ubuntu 26.04)で実行、`restic init` 済み、timer 有効(毎日 04:00 JST)。2026-09-06。
- [x] R2 の使用量は 3.28 GiB(重複排除・圧縮後、論理 12.28 GiB)で無料枠 10 GB 内。操作回数と egress は桁違いに余裕。
      通知に実サイズとスナップショット数を出すようにした。増えるとしたら `denpa-recorded` と `adguardhome-work`。
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
- [ ] **ghcr の pull 認証を node 単位に寄せる**(下記)。imagePullSecrets と `ghcr-pull` の CR 2 つが消える。
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

**2026-09-06 に QEMU/KVM で v1.14.0 を起動して分かったこと(machine config は未完成):**

- **Talos 1.14 の machine config は複数ドキュメント形式**になっていて、v1alpha1 の同じ項目と**併記できない**。
  `KubeNetworkConfig`(podSubnets/serviceSubnets)、`KubeletConfig`、`UnattendedInstallConfig` などが自動生成され、
  `cluster.network` / `machine.kubelet` / `machine.install` を v1alpha1 側に書くと apply 時に弾かれる。
  片方に寄せるか、要らないドキュメントを `$patch: delete` で消す。`talconfig.yaml` は talhelper が面倒を見るが、
  手書きのパッチはこの形に合わせる必要がある。
- **`machine.kubelet.extraMounts` は `KubeletConfig` ドキュメントに無い。** local-path 用の bind mount を入れるには
  `KubeletConfig` を `$patch: delete` してから v1alpha1 の `machine.kubelet` に書く。
- **service の IPv6 CIDR `fd43::/64` は Talos では通らない。** `service subnets: invalid subnet: fd43::/64 is too large,
  it must be at least /108` と言われる。いまの k3s は通っているので、**移行時に `fd43::/108` 等へ変更が要る**
  (Service の ClusterIP が振り直しになるので、切り替えの一部として扱う)。
- ISO は Image Factory の schematic `2d61dd07…` から起動。UEFI(OVMF)で問題なく上がり、maintenance mode の
  API はポート 50000 で応答した。

- [ ] Hyper-V に Talos を 1 台(ISO の作り方と実機の iLO 手順は [docs/talos-install-media.md](docs/talos-install-media.md))。
      talhelper + SOPS で machine config を生成し、talconfig とパッチをこの repo に置く。
- [ ] 確認項目: bond0(balance-alb、eno1+eno2)、eno4 の static、dual-stack、**IPv6 の token `::2` 相当が設定できるか**(できなければ EUI-64 か DDNS で代替)、
      wg-easy の hostNetwork UDP 51820。
- [ ] local-path-provisioner(`/var/local-path-provisioner`)、ArgoCD を helm source で導入し、ApplicationSet が動くこと。
      HelmChart CRD 依存(argocd/infisical/push-bridge)を ArgoCD の Application に書き直す。
- [ ] **Ingress / LoadBalancer の置き換え(比較は下の「ルーティングの選定」)。** k3s 同梱の ServiceLB が無くなるので
      LoadBalancer 型 Service(adguardhome-dns、mattermost-calls)のために MetalLB(L2)がどの案でも要る。
- [ ] k8up を導入し、Phase 0 と同じ restic リポジトリ(別 path / tag)に対して PVC バックアップと `backupcommand` の dump が取れること。
- [ ] `talosctl etcd snapshot` → 別 VM で `talosctl bootstrap --recover-from` の復元リハーサル。
- [ ] Talos 期の公開復元手順を書く: ISO boot → `apply-config` → etcd 復元(または git から ArgoCD 再構築)→ Job で restic から PV を戻す。

### Phase 2 — 切り替え(停止を伴う)

- [ ] 作業中の見せ方は未定(メンテページは一旦見送り)。調べた事実だけ残す:
      サブドメインは `*.doany.io` のワイルドカード CNAME 1 本でほぼ全部賄われていて(明示レコードは apex と
      `l` `ts` `w` `x` `y` の 5 つだけ)、**このワイルドカードの proxied を倒すだけで全サブドメインが Cloudflare 受けになる**。
      ただし Cloudflare 単体では 521 画面しか出ないので、読めるページを出すには Worker か Pages が要る。
      proxied にすると HTTP/HTTPS 以外(WireGuard の UDP、AdGuard の DNS/DoT、3proxy の TCP)は通らない。
- [ ] **作業は LAN(10.0.0.2 / 10.10.0.4)か iLO(10.0.0.3)から行う。** cloudflared 経由の ssh は使えない。
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

## Talos では `bootstrap/` をどう適用するか

いまの `bootstrap/` は「Argo CD より下の層」なので Argo CD が同期できず、手で `kubectl apply` している。
Talos ではホストにログインできないが、**machine config の `cluster.inlineManifests`** がその役をそのまま引き受ける。

- `inlineManifests` は machine config に YAML を埋め込む形式で、**クラスタの bootstrap 時に Talos 自身が apply する**
  (kubectl を打てるようになる前に終わっている)。URL から取る `extraManifests` もあるが、外部依存が増えるので使わない。
- 追加専用の性質がある(Talos は一度作ったリソースを消さない)。**種を蒔く仕組み**であって継続的な reconcile ではないので、
  以後の変更は Argo CD に任せる。Argo CD 自身の install が inlineManifests に入っていれば、そこから先は自走する。
- 秘密も machine config に入るが、machine config は talhelper + SOPS(いまの age 鍵と同じ)で暗号化して git に置くので、
  公開 repo のままで問題ない。`bootstrap/` の SOPS ファイルと鍵が共通になる。
- 結果として **「手で apply する層」が消える**。復元も `talosctl apply-config` 一発になり、
  `restore.sh` のような k3s 期専用のスクリプトは要らなくなる。

移行時の作業は、`bootstrap/*/*.yaml` を talhelper の patch に流し込む変換(1 ファイル 1 inlineManifest)。
HelmChart CRD 依存(argocd / infisical / push-bridge)は Argo CD の Application に書き換えるので、
inlineManifests に載るのは「Argo CD 本体 + repo-creds + apps Application + Infisical の根っこ」だけになる見込み。

## ルーティングの選定(2026-09-06 に再検討)

いま Traefik に依存しているもの: 標準 `Ingress` 15 個(annotation で entrypoints / certresolver)、`IngressRoute` 4、
`IngressRouteTCP` 1(3proxy、SNI で TLS 終端して 3128 へ)、`Middleware` 4(redirect-https、forward-auth、
forward-auth-errors、yuzuriha)、ACME は Traefik 内蔵の mydnschallenge(Cloudflare DNS-01)。forward-auth の先は oauth2-proxy + redis(auth ns)。

前提: `Ingress` API は凍結済みで、ingress-nginx は 2026-03-24 に EOL(リポジトリ read-only、CVE 修正なし)。新規に組むなら Gateway API。

| 案 | 書き換え | 認証(forward-auth 相当) | TCP/UDP | 証明書 | 所感 |
| --- | --- | --- | --- | --- | --- |
| **A. Traefik v3 を Helm で継続** | ほぼ 0(HelmChart CRD → ArgoCD の helm source だけ) | Middleware のまま(oauth2-proxy + redis を維持) | IngressRouteTCP/UDP | 内蔵 ACME のまま | 最小工数。Traefik 固有 CRD に縛られ続ける。Gateway API 対応は部分的 |
| **B. Envoy Gateway + cert-manager + MetalLB** | Ingress 15 → HTTPRoute(ingress2gateway で機械変換可)、IngressRoute 4、TCP 1 → TLS 終端 + TCPRoute、Middleware → SecurityPolicy と HTTPRoute filter | **SecurityPolicy の OIDC が内蔵**(Entra に直接。oauth2-proxy と redis を撤去できる)。ExtAuth もある | TCPRoute / UDPRoute / TLSRoute | cert-manager(Cloudflare DNS-01、Gateway に annotation) | Gateway API の参照実装で機能が最も揃う。部品は増えるが auth ns の 2 Deployment が消える |
| C. Cilium(CNI + Gateway API + L2 LB) | B と同程度 + **CNI 交換**(flannel → Cilium、kube-proxy 置換) | HTTPRoute の ExternalAuth(GEP-1494)が 1.20 pre-release で入ったばかり。fail-open のバグ報告あり。OIDC 内蔵は無い | TLSRoute のみ(TCPRoute/UDPRoute は非対応) | cert-manager | 1 つで flannel + ServiceLB + Ingress を置き換えられて魅力的だが、OS 交換と同時に CNI 交換は blast radius が大きい。ExternalAuth も生煮え |
| ingress-nginx | — | — | — | — | EOL。対象外 |
| HAProxy / Kong / Istio | — | — | — | — | 単一ノードには過剰、または Gateway API 対応が B に劣る |

**結論: B(Envoy Gateway + cert-manager + MetalLB)を採用。** Talos への移行で manifest をどうせ触るので、そのタイミングで
Gateway API に寄せる。決め手は SecurityPolicy の OIDC 内蔵で、forward-auth の Middleware 2 つと oauth2-proxy と redis が丸ごと消えること。
Cilium は CNI として後から入れてもよく(Gateway は Envoy Gateway のまま共存できる)、今回は flannel のままにする。
時間が無ければ A に倒せる(A は Talos 上でも問題なく動く。mydnschallenge も Middleware もそのまま)。

移行の段取り: Phase 1 の Hyper-V 上で B を組み、`ingress2gateway` で HTTPRoute を生成 → 各 repo の `deploy/` に Gateway API 版を
**Ingress と並置**でコミット(k3s 側の Traefik は Gateway API の CRD が無ければ無視する)→ 切替時に Ingress 側を消す。

## ghcr の pull 認証

いまは repo が private なのでパッケージも private で、名前空間ごとに `ghcr-pull`(PAT の dockerconfigjson)を
Infisical から作って `imagePullSecrets` で参照している(tamasagashi、worklog)。アプリを足すたびに同じものが増える。

| 案 | 中身 | 評価 |
| --- | --- | --- |
| **node 単位の資格情報**(推奨) | k3s なら `/etc/rancher/k3s/registries.yaml`、Talos なら machine config の `machine.registries.config."ghcr.io".auth`。全 namespace に効く | `imagePullSecrets` と `ghcr-pull` の CR が全部消える。Talos では SOPS 暗号化した machine config に載るので、秘密の置き場も統一される。**Talos 移行と同時にやるのが自然** |
| パッケージだけ public にする | GHCR のパッケージ可視性は repo の可視性と独立。public にすれば資格情報ゼロ | いちばん簡単。ただしイメージの中身(ビルド済みのアプリ)が誰でも pull できる |
| GitHub App の短命トークン | CronJob で 1 時間ごとにトークンを発行して Secret を書き換える | いちばん安全だが、動く部品が増える。単一ノードの自宅クラスタには過剰 |
| いまのまま(PAT を Infisical に) | 現状 | 動いてはいる。ローテーションは Infisical 側 1 回で済む |

**結論: Talos 移行のときに node 単位へ寄せる。** それまでは現状維持でよい(復元でも Infisical から戻る)。

## 未決事項

- **PT3 チューナーが Talos で動かない(要決断)。** 実機には Earthsoft PT3(`earth_pt3`、Altera 1172:4c15)が刺さっていて、
  Talos のカーネルは `CONFIG_DVB_PT3` を有効にしておらず、公式 extension にも無い。denpa の tuner-agent はこの箱の
  `/dev/dvb` と B-CAS リーダーに依存している。選択肢:
  1. **チューナーを別の箱に出す。** tuner-agent は denpa とネットワーク越しに話す設計(`docs/agent.md`)なので、
     PT3 と B-CAS リーダーを小さな Linux 機に移して tuner-agent だけそこで動かせば、Talos 側は素のままでよい。一番確実。
  2. **上流に PR 済み(2026-09-06)**: [siderolabs/pkgs#1682](https://github.com/siderolabs/pkgs/pull/1682)
     (`CONFIG_DVB_PT3=m` の 1 行。依存する tc90522 / qm1d1c0042 / mxl301rf は既に `m`)と
     [siderolabs/extensions#1238](https://github.com/siderolabs/extensions/pull/1238)(`dvb/pt3` extension、cx23885 と同じ形)。
     後者は前者が入って Talos のリリースに乗るまでビルドできないので順番待ち。取り込まれれば 1 の VM を畳んで extension に戻せる。
     **DCO の Signed-off-by は git config の `Ruk Doe <info@doany.io>` で入れた。conform が GPG 署名も要求しているので、
     必要なら本人の鍵で commit を作り直す。extension の `compatibility.talos.version` は `>= v1.15.0` と当て推量。**
  3. `imager` で自前のカーネル/extension を焼く。Image Factory が使えなくなり、アップグレードのたびに自前ビルドになるので勧めない。
  1 を軸に 2 を並行、が現実的。

- ~~サーバのファイルシステム~~ → ext4 on LVM、VG の空きが 0 なので LVM スナップショットは使えない。停止時間は scale down 方式のまま(30 秒前後)。
- ~~消した namespace(epg、vpn、opengist)の PV ディレクトリ~~ → Released の PV オブジェクトを削除し、ディレクトリ 16 個(541 MiB)は
  `/var/lib/k3s-storage-trash/` に退避(2026-09-06)。バックアップ対象外になった。問題なければ `rm -rf` する。
  denpa の Released PV 2 つ(mirakc-config、mirakc-epg)と `yosegaki_yosegaki-db`(4K)は namespace が生きている / 指示外なので残した。
- 本番 2 回目の実行で「120 秒待っても Pod が残る」警告が denpa 除外後にも出た。どの namespace かはログに出していなかったので、
  出すように直した。次回(04:00 JST)のログで特定する。
- Talos で IPv6 token が使えなかった場合の AAAA の運用(EUI-64 で MAC を出すか、DDNS に任せるか)。
