# 決定の記録

なぜこの技術・この形を選んだかをここに置く。手順と進捗は [`../ROADMAP.md`](../ROADMAP.md)。

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


## ルーティングの選定(2026-09-06)

いま Traefik に依存しているもの: 標準 `Ingress` 15、`IngressRoute` 4、`IngressRouteTCP` 1(3proxy)、
`Middleware` 4、ACME は Traefik 内蔵(Cloudflare DNS-01)。forward-auth の先は oauth2-proxy + redis(IdP は Entra ID)。
LoadBalancer は k3s 組み込みの ServiceLB(Klipper)。

前提: `Ingress` API は凍結済みで、**ingress-nginx は 2026-03-24 に retire**(read-only、CVE 修正なし)。
新規に組むなら Gateway API。F5/NGINX Inc. の `nginxinc/kubernetes-ingress` は別プロジェクトで継続中。

### 結論: Cilium(CNI + Gateway API + LB-IPAM)に寄せる

**Talos で後から替えるのが高いのは CNI だけ**なので、そこを先に決める。Ingress コントローラ・LB・証明書は
Gateway API に寄せてあれば後から差し替えられる。単一ノードのうちは Cilium は過剰に見えるが、
ハイブリッド化の見込みがあるならここで払うのが一番安い。**VM で実際に組んで動くことを確認済み**(下記)。

| | 選択 | 置き換わるもの |
| --- | --- | --- |
| CNI | Cilium | flannel |
| kube-proxy | Cilium の kubeProxyReplacement | kube-proxy |
| LoadBalancer | Cilium LB-IPAM + L2 announcement | ServiceLB(Klipper)。**MetalLB は不要になる** |
| Ingress | Cilium Gateway(Gateway API) | Traefik |
| 証明書 | cert-manager(Cloudflare DNS-01) | Traefik 内蔵 ACME |
| 認証 | oauth2-proxy を ext auth で外付け(現状維持) | — |

**認証だけは Gateway 内蔵に寄せない。** Entra のトークンは大きく(oauth2-proxy の redis セッション実測 **4293 バイト**)、
Cookie に載せる方式は 4096 バイトの壁に当たる。oauth2-proxy なら Cookie はセッション ID だけなのでトークン長に依存しない。
これは実装選択と独立に効く判断。

### 検証結果(2026-09-06、QEMU/KVM の k3s で実機同等の CIDR)

`flannel-backend: none` + `disable-kube-proxy` + `disable: [servicelb, traefik]` で k3s を入れ、Cilium 1.20.1 を Helm で導入。

- `KubeProxyReplacement: True`、デュアルスタックの IPAM(IPv4 `10.42.0.0/24` / IPv6 `fd42::/64`)
- **GatewayClass `cilium` が Accepted、Gateway が Programmed**、`CiliumLoadBalancerIPPool` から
  LoadBalancer Service に IP が払い出される(ServiceLB の代替になる)
- **HTTPRoute 経由で実際に HTTP 200**(Host 不一致は 404)。L2 announcement も動作

**詰まった点**: Cilium 1.20 は **Gateway API v1.6.1** の CRD を要求する。v1.4.0 を入れていると
operator が `Required GatewayAPI resources are not found` を出して GatewayClass が `Waiting for controller` のまま止まる。
必要なのは gatewayclasses / gateways / httproutes / referencegrants / grpcroutes / **backendtlspolicies** / **tlsroutes**
(v1.6.1 では TLSRoute が standard チャネルに入っている)。

**メモの訂正**: 引き継ぎメモには「Cilium は TLSRoute のみ。TCPRoute / UDPRoute は非対応」とあったが、
**1.20 のドキュメントは TCPRoute / UDPRoute を optional but supported として挙げていて、CRD も適用できた**。
3proxy の TCP ルートは TCPRoute で移せる見込み(実際の疎通は未確認)。

### 本番での実施結果(段階 1、2026-09-06)

k3s の config に `flannel-backend: none` / `disable-network-policy` / `disable-kube-proxy` を足して再起動し、
Cilium 1.20.1 を Helm で導入。**Traefik と Ingress はこの段階では触っていない。**

- ノードが Ready に戻り、`KubeProxyReplacement: True`、IPAM はデュアルスタックで 45 アドレス払い出し、
  全 50 Pod が Running、外形も全サイト 200/302。**所要は 30 分ほど**(うち大半は下の 2 つの詰まり)
- **詰まり 1: flannel の残骸が Cilium の VXLAN と衝突する。** `flannel.1` / `flannel-v6.1` / `cni0` が
  インターフェースとして残っていると、Cilium が `cilium_vxlan` を作れず `address already in use` で
  datapath 初期化が延々とリトライする。Pod は `FailedCreatePodSandBox` で止まったまま。
  `ip link delete` で 3 つ消したら即座に復旧した。**CNI 設定ファイル(`10-flannel.conflist`)を退避するだけでは足りない。**
- **詰まり 2: `terminationGracePeriodSeconds` が長い Pod は Recreate 戦略と組み合わさると復帰しない。**
  denpa と tuner-agent(21900 秒 = 6 時間)が Terminating のまま残り、通信は既に死んでいるのに
  新しい Pod が作られない。**強制削除(`--grace-period=0 --force`)が要る。** 猶予は「録画を最後まで流す」ためだが、
  CNI を抜いた時点でネットワークは死んでいるので待つ意味は無い。
- **残った差異: ノード自身と Pod から `10.10.0.4`(eno4 の LAN IP)に届かない。** LAN の他のマシンからは届く。
  AdGuard の split-horizon でこの IP に解決される名前だけ、ノード内から引けなくなった。
  ServiceLB(klipper)の hostPort と Cilium の socket-LB の組み合わせが原因と見られる。
  **段階 2 で ServiceLB を Cilium LB-IPAM に置き換えると経路ごと変わる**ので、そこで解消するか再評価する。

### 認証は Cilium の Gateway では賄えない(2026-09-06 調査)

「Entra 側でトークンを小さくして Cilium の Envoy 機能で OIDC を賄う」案を検討したが、**Cilium には
Gateway API の OIDC が無い**。トークンの大きさ以前に機能が無い。

- `CiliumEnvoyConfig` で Envoy の `oauth2` フィルタを直接書く道は、公式に未サポートで
  「フィルタの型を解決できない」という報告がある(cilium/cilium#24848)。HTTPRoute と併用するのも難しい(#30587)
- HTTPRoute の `ExternalAuth`(GEP-1494)は**まだ未実装**で issue が開いたまま(cilium/cilium#45704)。
  引き継ぎメモの「1.20 pre-release で入った」は誤り
- Keycloak で OAuth2 を組もうとした事例も未解決のまま(cilium/cilium#38889)

したがって forward-auth が要るルートは、**oauth2-proxy を「前段のプロキシ」として置く**
(HTTPRoute → oauth2-proxy → アプリ)か、そのルートだけ Traefik か Envoy Gateway に残す。
幸い forward-auth を使っているのは Traefik ダッシュボードと `sub` の 2 本だけで、
アプリ側(ArgoCD、ERPNext、Mattermost、denpa、wg-easy)はそれぞれ自前で OIDC を持っている。

**Entra 側でトークンを小さくすること自体は独立して価値がある。** グループクレームを全部載せるのをやめて
**アプリロール**に切り替えると `roles: ["admin"]` の数十バイトで済む。将来 Envoy Gateway の内蔵 OIDC を
使う場合の前提にもなる。

### 却下した案

| 案 | 理由 |
| --- | --- |
| Traefik 継続 | 書き換えは 0 で済むが、Traefik 固有 CRD への依存が続き、ハイブリッド化したときに移植性が無い。Talos では ServiceLB が無いので結局 MetalLB を足すことになり、部品は減らない |
| Envoy Gateway | Gateway API の機能は最も揃うが、単一ノードでは MetalLB と cert-manager を連れてきて部品が増える。内蔵 OIDC は Cookie 4096 バイトの制約(#7315)で当てにできず、主要な動機が消える。マイナーが 2 週間強に 1 回でバージョンマトリクスが重い |
| ingress-nginx | EOL |
| HAProxy / Kong / Istio | 単一ノードに過剰、または Gateway API 対応で劣る |

### 参考: Envoy Gateway を選ぶ場合に確認が要ること

いまは採らないが、将来 Cilium で足りなくなったときのために残す。Envoy Gateway の OIDC は
トークンをブラウザの Cookie に保存するので、既知の問題がある。

| Issue | 内容 |
| --- | --- |
| envoyproxy/gateway#7315 | トークンが **4096 文字を超えるとブラウザが Cookie をセットせず**、認証がループする。**Envoy 側にエラーログが出ない** |
| envoyproxy/gateway#8441 | OIDC Discovery が失敗すると毎リクエスト token introspection にフォールバック。IdP 停止時に白画面 |
| envoyproxy/gateway#8649 | Gateway レベルとルートレベルで SecurityPolicy を二重掛けすると CSRF 検証で落ちる |

`cookieDomain` はサブドメイン間で共有するなら root domain(`.doany.io`)。後から変えると
ブラウザに残った古い Cookie が優先されて認証が壊れるので、変更時は Cookie クリアが要る。

Envoy Gateway 自体はマイナーが 2 週間強に 1 回出てサポート窓も短い。
**Talos / Kubernetes / Gateway API CRD / Envoy Gateway の 4 つのバージョンマトリクス**を回す前提でコストを見る。

## ghcr の pull 認証

いまは repo が private なのでパッケージも private で、名前空間ごとに `ghcr-pull`(PAT の dockerconfigjson)を
Infisical から作って `imagePullSecrets` で参照している(tamasagashi、worklog)。アプリを足すたびに同じものが増える。

| 案 | 中身 | 評価 |
| --- | --- | --- |
| **node 単位の資格情報**(推奨) | k3s なら `/etc/rancher/k3s/registries.yaml`、Talos なら machine config の `machine.registries.config."ghcr.io".auth`。全 namespace に効く | `imagePullSecrets` と `ghcr-pull` の CR が全部消える。Talos では SOPS 暗号化した machine config に載るので、秘密の置き場も統一される。**Talos 移行と同時にやるのが自然** |
| パッケージだけ public にする | GHCR のパッケージ可視性は repo の可視性と独立。public にすれば資格情報ゼロ | いちばん簡単。ただしイメージの中身(ビルド済みのアプリ)が誰でも pull できる |
| GitHub App の短命トークン | CronJob で 1 時間ごとにトークンを発行して Secret を書き換える | いちばん安全だが、動く部品が増える。単一ノードの自宅クラスタには過剰 |
| いまのまま(PAT を Infisical に) | 現状 | 動いてはいる。ローテーションは Infisical 側 1 回で済む |

**結論: node 単位へ寄せた(2026-09-06、Talos を待たず k3s 側で実施)。** アプリを足すたびに Secret を用意する必要が無くなった。


## PT3 チューナー(Talos で動かすための算段)

実機には Earthsoft PT3(`earth_pt3`、Altera 1172:4c15)が刺さっていて、Talos のカーネルは `CONFIG_DVB_PT3` を
有効にしておらず、公式 extension にも無い。denpa の tuner-agent はこの箱の `/dev/dvb` と B-CAS リーダーに依存している。
**余っている箱は無い**(2026-09-06 本人談)ので、次の 2 本立てで進めている。

1. **上流に PR 済み(本命)**: [siderolabs/pkgs#1682](https://github.com/siderolabs/pkgs/pull/1682)
   (`CONFIG_DVB_PT3=m` の 1 行。依存する tc90522 / qm1d1c0042 / mxl301rf は既に `m`)と
   [siderolabs/extensions#1238](https://github.com/siderolabs/extensions/pull/1238)(`dvb/pt3` extension、cx23885 と同じ形)。
   後者は前者が入って Talos のリリースに乗るまでビルドできないので順番待ち。取り込まれれば Talos 側は素のままで済む。
   DCO の Signed-off-by は git config の `Ruk Doe <info@doany.io>`。conform が GPG 署名も求めるので、必要なら本人の鍵で作り直す。
   extension の `compatibility.talos.version` は `>= v1.15.0` と当て推量。
2. **入らなかった場合の保険: KubeVirt の VM にパススルー。** 実機で確認済み — VT-d 有効(IOMMU グループ 66 個)、
   PT3(05:00.0)は**グループ 36 に単独**、B-CAS は USB(Gemalto GemPC Twin 08e6:3437)。Talos のカーネルは
   `vfio-pci` / `vfio_iommu_type1` / KVM を持っている(`talos/patches/main.yaml` で `intel_iommu=on` と vfio を指定済み)。
   tuner-agent だけ VM(Ubuntu)で動かせば Talos 本体は素のまま、アップグレードも Image Factory のままでいける。

自前 extension を `imager` で焼く案は、Image Factory から外れてアップグレードのたびに自前ビルドになるので採らない。


## バックアップに何を含めるか

R2 の無料枠(10 GB)に対して実サイズは 3.3 GiB。容量を削るために外した / 外さなかったもの:

| 対象 | 判断 |
| --- | --- |
| AdGuard のクエリログ(`querylog.json`) | **保持を 90d → 7d に短縮**(2026-09-06)。単体で 2.0 GB あった。純粋な計測データで、復元時に無くても困らない。いま 8.8 MB |
| 録画データ(`denpa-recorded`、1.6 GB) | **含める**。放送は取り直せないので、容量より価値を優先する(2026-09-06 本人判断) |
| 保持世代 | 17 → **13**(`--keep-daily 7 --keep-weekly 4 --keep-monthly 2`)。遡れる範囲は約 2 か月 |
| 消した namespace の PV(epg / vpn / opengist、541 MiB) | 退避のうえ削除済み。バックアップ対象外 |
