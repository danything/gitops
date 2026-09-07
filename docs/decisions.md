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

移行前に Traefik に依存していたもの: 標準 `Ingress` 15、`IngressRoute` 4、`IngressRouteTCP` 1(3proxy)、
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

### LoadBalancer をどう置き換えるか(2026-09-06 決定・実施済み)

Talos には k3s の ServiceLB(klipper)が無いので、その差分を k3s のうちに埋めた。**hostPort を選んだ。**

ServiceLB は**ノード自身の IP**(`10.0.0.2` / `10.10.0.4` / `240f:6d:842b:1::2`)をそのまま EXTERNAL-IP にする作りで、
ルータの DMZ 転送先と AdGuard の split-horizon がこの IP に固定されている。Cilium LB-IPAM で仮想 IP を払い出すと
**クラスタ外(ルータと DNS)の変更が必要**になり、IPv6 のプレフィックスは RA 由来で変わりうるため `externalIPs` への
固定書きも危うい。hostPort ならノードの全アドレスで受けられ、送信元 IP も保たれ、Talos でも同じ形が使える。
ノードが増えたときに VIP が要るなら、そのとき LB-IPAM に移ればよい。

| 対象 | hostPort |
| --- | --- |
| Gateway(`cilium-gateway-doany`) | 80 / 443。ここだけ hostPort ではなく nodePort |
| adguardhome | 53 UDP・53 TCP・853 TCP |
| mattermost(calls) | 8443 UDP・8443 TCP |
| 3proxy(tls-terminator サイドカー) | 3129 TCP |

**詰まった点 3 つ:**

1. **Cilium の hostPort は既定で無効。** `hostPort.enabled=true`(あわせて `nodePort.enabled` と `externalIPs.enabled`)を
   有効にしないと、Pod は Running なのにホストのポートに何も来ない。`ss` には現れない(eBPF なので)。
   確認は `cilium-dbg service list | grep HostPort`。
2. **hostPort は Pod のサンドボックス作成時に設定される。** 設定を有効にしたあと、対象の Pod を作り直す必要がある。
3. **hostPort と RollingUpdate は両立しない。** 新旧の Pod が同じホストポートを奪い合い、新しい方が Pending で止まる。
   AdGuard と 3proxy は `strategy: Recreate` にして解決した(当時の Traefik は `deployment.kind: DaemonSet`)。

### Gateway API の土台で分かったこと(2026-09-06)

- **Cilium 1.20 は Gateway API v1.6.1 の CRD を要求する。** k3s の Traefik が v1.5.1 を入れているので
  `--server-side --force-conflicts` で上書きが要る。バージョンが合わないと GatewayClass が
  `Waiting for controller` のまま無言で止まる。CRD を入れ替えたあと **cilium-operator の再起動**も要る。
- **Gateway はアドレスが付くまで `Programmed=False` のまま**で、Envoy にリスナーが載らない。
  hostPort ではアドレスが付かないので、`CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy` が要る。
- **`l2announcements.enabled` は ConfigMap に入るだけでは効かない。** cilium エージェント(DaemonSet)の
  再起動が必要。再起動前は ARP に応答せず「No route to host」になる。
- **LB IP は ICMP に応答しない。** `ping` では確認できないので TCP で叩く。
- cert-manager は `config.enableGatewayAPI=true` で Gateway の `cert-manager.io/cluster-issuer` 注釈を見る。
  Cloudflare のトークンは **cert-manager の namespace にも** Secret が要る(ClusterIssuer は自分の namespace しか読まない)。

### 3proxy(TLS 終端 + 素の TCP)は Cilium の Gateway では素直に移せない

Traefik では `IngressRouteTCP` が `HostSNI(px.doany.io)` で受けて **TLS をここで終端し、中身を素の TCP として
3proxy:3128 に流して**いた。Gateway API で同じことをしようとすると詰まる。

- `protocol: TLS` + `mode: Terminate` のリスナーに **TCPRoute は付けられない**
  (`No matching listener protocol; route requires one of: [TCP]`)
- Cilium はそのリスナーに **TLSRoute しか許さず**、TLSRoute は本来 passthrough 用
  (`Listener not valid. None of the Allowed Route Kinds are supported.`)

取りうる形は 3 つ。

**なぜ Traefik では 443 のまま両立できていたのか。** Traefik は 443 のエントリポイントが 1 つあり、
接続ごとに TLS の ClientHello を覗いて **SNI で HTTP ルーターと TCP ルーターに振り分けて**いた。
Gateway API では TLS の扱いが**リスナーの属性**なので、同じポートに Terminate と Passthrough を同居させると
どちらとして扱うか決まらず **ProtocolConflict** になる(実際に試して 443 の `https` リスナーごと落ちた)。

**ただし仕様上は 443 のままでも書ける。** `protocol: TLS` + `mode: Terminate` のリスナーに TCPRoute を付ける形は
Traefik と同じ意味で、終端するリスナーが 1 つあるだけなので他の HTTPS リスナーとも衝突しない。
**通らないのは Cilium がその組み合わせを実装していないから**で、ポートの制約ではない。
Envoy Gateway はこれを実装しているので、443 のままにしたいなら選択肢になる。

**採った形(2026-09-06): Gateway を使わず、Pod のサイドカーがホストのポートを直接受ける。**

- 3proxy の Pod に nginx(stream)のサイドカーを足し、`3129` で TLS を終端して `127.0.0.1:3128` に渡す
- 証明書は cert-manager が `px.doany.io` で発行し、サイドカーがマウントする(Traefik 内蔵 ACME の置き換え)
- サイドカーは **hostPort 3129** で公開する。443 は Gateway が使うため。当初は 8444 だったが
  (8443 は Mattermost calls が先に取っている)分かりにくいので、3proxy の平文 3128 の隣に移した(2026-09-07)
- **クライアント側の設定変更が要る**(`px.doany.io:443` → `px.doany.io:3129`)。
  SNI で振り分けるより**ポートで分ける方が構成として素直**なので、これを本採用とした(2026-09-06 判断)。
  443 のままにしたい場合の代案は、px 専用の IP を LB-IPAM で払い出してルータ側で振り分けるか、
  Envoy Gateway に替えて TLS 終端リスナー + TCPRoute を使うか

### クライアント IP(2026-09-07 確認、`Cluster` のままでよい)

Gateway の Service は `externalTrafficPolicy: Cluster`(Cilium の `gateway-api-service-externaltrafficpolicy`)。
一般には `Cluster` は別ノードへ回すときに SNAT するが、**単一ノードでは backend が必ず同じノードに居るので
SNAT されない**。実際にクライアント IP は端まで届いている。

確かめ方(どちらも実測):

- **denpa** は `TRUSTED_NETWORKS=10.10.0.0/16` と `ADDRESS_HEADER=x-forwarded-for` で動いている。
  公開側から `dp.doany.io` を叩くと **401**、LAN から叩くと **200**。SNAT されていれば
  X-Forwarded-For がノードの `10.10.0.4` になり、公開側からでも通ってしまう。**通らない**ので届いている。
- **AdGuard の DoH** のクエリログに、Gateway 経由でも端末のグローバル IPv6 がそのまま残っている。
  サイドカーは `$http_x_forwarded_for` をそのまま渡し、AdGuard は `trusted_proxies` に
  `127.0.0.0/8` を持っているので、loopback からの接続でもヘッダ側を採る。

**ノードを足すときにやること**: `externalTrafficPolicy: Local` に変える
(Cilium の Helm 値 `gatewayAPI.externalTrafficPolicy`)。そうしないと Envoy が居ないノードに
届いたぶんが SNAT されて、AdGuard のクライアント別統計と denpa の住所判定が壊れる。
`Local` にすると Envoy の居るノードだけが応答するので、L2 アナウンスか外側の振り分けもそれに合わせる。

### AdGuard の DoH は backend が HTTPS でないと出ない(2026-09-07 障害)

**切り替えの翌朝、ブラウザの名前解決が全部死んだ。** 原因は d.doany.io の backend を平文の 80 にしたこと。
AdGuard は **DoH(`/dns-query`)を HTTPS の口(443)でしか出さない**。80 は 404 を返す。
Edge の「セキュア DNS」に `https://d.doany.io/dns-query` を入れていたので、DoH が死んだ時点で
そのブラウザからは何も引けなくなった。クエリログでは 06:34 を最後に DoH の問い合わせが止まっている
(DoT と plain は生きていたので、OS の名前解決は動いたまま**ブラウザだけ**死ぬ、という分かりにくい形になった)。

Traefik では `serversscheme: https` + `insecureSkipVerify` の `ServersTransport` で backend も HTTPS に繋いでいた。
その置き換えを「クラスタ内なので平文でよい」と判断したのが誤り。**DoH は平文の口には出ない。**

試して駄目だったもの:

| 案 | 結果 |
| --- | --- |
| `BackendTLSPolicy`(Gateway API 標準) | **Cilium 1.20.1 は Accepted にするだけで実装していない。** Envoy の cluster に `transport_socket` が付かず、backend へ平文のまま繋ぐ。`sectionName` をポート名にしても番号にしても同じ。Web UI まで 400 になった |
| AdGuard の `tls.allow_unencrypted_doh: true` | **AdGuard は停止時に設定ファイルを書き直す**ので、Pod を止めずに足した値は消える。入れるには Pod を止めてから編集する必要がある |

**採った形: nginx のサイドカーを足して `/dns-query` だけをそこへ回す。** サイドカーは同じ Pod の
`https://127.0.0.1:443` へ渡す(loopback なので証明書の検証はしない)。Web UI は 80 のまま。
3proxy と同じ形なので、Cilium が `BackendTLSPolicy` を実装したら両方まとめて消せる。

**教訓**: 前段の置き換えでは「同じ URL が同じものを返すか」だけでなく、**その backend が
何をポートごとに出し分けているか**を見る。HTTP のステータスだけ見ていると気付けない。

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

### 切り替え本番と Traefik の撤去(2026-09-06 / 2026-09-07)

Traefik の hostPort 80/443 を外すのと Gateway をそこへ出すのは**同時にしかできない**(片方が握っている間は
もう片方が Pending になる)。Gateway 側は `CiliumGatewayClassConfig` ではなく Service の 80/443 を
**nodePort として開く**形にした。これでノードのどのアドレスでも受けられる。

**詰まった点 2 つ:**

1. **Cilium は nodePort の範囲に入っている hostPort を張らない。** nodePort の範囲を `80-32767` に広げたら、
   AdGuard の 853 と Mattermost calls の 8443、3proxy の TLS ポートが一斉に落ちた。範囲を `80,443` の
   2 つだけに絞る(`nodePort.range`)ことで両立する。
2. **Traefik を消したあとも Service に残った `externalIPs: [10.10.0.4]` が 10.10.0.4:80/443 を黒穴にする。**
   DaemonSet を消しても Service は残り、Cilium はそのまま宛先無しの転送先を作り続ける。
   削除は `service.kubernetes.io/load-balancer-cleanup` finalizer で止まるので、finalizer を null にして消した。

**自分で配っている Helm chart の分を取りこぼした(2026-09-07)。** denpa は gitops 側の `Ingress` ではなく
**chart(`charts/denpa`)の `IngressRoute`** で公開していたので、Traefik の CRD を消した時点で
`dp.doany.io` が 404 になっていた。gitops の `Ingress` を数えるだけでは足りない。
chart に `httpRoute.enabled` を足して移した(denpa#70)。`ingress.enabled` と `traefik.enabled` は
外にも配っている chart なので残してある。yosegaki の chart も同じ形にした。
宅内向けの `dp.l.doany.io` は 2 段のワイルドカードなので、`*.l.doany.io` のリスナーと証明書を別に足した。

翌 2026-09-07 に `Ingress` 15 本・`IngressRoute` 4 本・`Middleware` 4 つ・`IngressRouteTCP` 1 本と
PVC `traefik-acme` を削除し、gitops とアプリ 6 repo からマニフェストも消した。
Traefik が持っていた ACME(`mydnschallenge`)は cert-manager の ClusterIssuer `letsencrypt` が引き継いでいる。
`bootstrap/traefik/` にあった `sub-backend` の Service と EndpointSlice は `bootstrap/auth/sub-backend.yaml` へ、
Cloudflare のトークンは `bootstrap/cert-manager/cloudflare-secret.yaml` へ移した。

### Traefik の sticky cookie に代替が無い(2026-09-07 調査)

撤去した Traefik の Middleware / IngressRoute のうち、**Service の sticky cookie
(`traefik.ingress.kubernetes.io/service.sticky.cookie.*`)だけは Cilium 側に受け皿が無い。**
使っていたのは tamasagashi(`ts.doany.io`)1 本で、ローリング更新中に新旧 2 Pod が同時に配信される窓で
「HTML を新 Pod から受けたブラウザが、ハッシュ付きの CSS/JS を旧 Pod に取りに行って 404」を防ぐためのものだった。

- **Gateway API の session persistence(GEP-1619、`HTTPRoute.spec.rules[].sessionPersistence`)は使えない。**
  入っている Gateway API CRD は **v1.6.1 の standard チャネル**で、`httproutes` の v1 の rule には
  `backendRefs / filters / matches / name / timeouts` しか無い。`BackendLBPolicy` の CRD も入っていない
  (どちらも experimental チャネル限定)
- **Cilium 1.20.1 が未実装。** v1.20.1 タグのソースに `SessionPersistence` の文字が無く、ドキュメントのページも無い。
  実装は cilium/cilium#48029 で 2026-09-01 に main へマージ(v1.20.1 のリリースは 2026-08-18)なので **1.21 から**。
  GatewayClass `cilium` の `status.supportedFeatures` にも該当 feature は載っていない
- **`Service.spec.sessionAffinity: ClientIP` は Gateway 経路には効かない。** 生成される
  `CiliumEnvoyConfig/cilium-gateway-doany` の cluster は **type EDS**(lbPolicy 既定 = ROUND_ROBIN)で、
  Envoy が EndpointSlice の Pod IP を直接見て振り分ける。sessionAffinity を実装している ClusterIP のデータパスを通らない。
  仮に通っても Envoy から見た送信元 IP は全クライアント同じ(Gateway の Pod)なので per-client の固定にならない。
  `service.cilium.io/affinity`(clustermesh の local/remote)や `service.cilium.io/lb-algorithm`(eBPF の random/maglev)も同じ理由で無関係

**いまは穴が開いたまま受け入れている。** tamasagashi は replicas 1・状態なしで、影響は更新中の 15 秒ほどの窓に限られ、
アプリ側の SvelteKit の版チェックと Cloudflare の Browser Cache TTL 設定で緩和してある(danything/tamasagashi の `deploy/README.md`)。
**Cilium 1.21 に上げるときに、Gateway API CRD を experimental チャネルへ入れ替えたうえで
`apps/gateway-routes/tamasagashi-tamasagashi.yaml` に `sessionPersistence` を足す**のが本筋。
CRD 入れ替えの際は、いまの Gateway API CRD が Traefik 撤去後も `traefik-crd` の Helm リリース所有のまま
(`helm.sh/resource-policy: keep` で残存)であることに注意。

**Cookie を使う他のアプリ(auth の oauth2-proxy など)は影響を受けない。** どれも replicas 1 で、
セッションは Cookie 自体か外部ストアに入っていて Pod のメモリに無い。**将来どれかを複数 replica にするなら、
Cilium 1.21 未満のあいだは Gateway 越しのセッション固定が無いことを先に確認すること。**

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

## chart を配るときと、chart で入れるとき(2026-09-07)

**「HelmChart」は 2 つの別物を指す。** ここを混ぜると話が噛み合わない。

| | 何か | この構成での扱い |
| --- | --- | --- |
| `HelmChart` CRD(`helm.cattle.io/v1`) | **k3s の入れ方**。helm-controller が CR を見て helm を Job で走らせる | **やめた**(下記) |
| Helm chart そのもの | **配る形**。`Chart.yaml` + `templates/` を OCI で push する | **続ける**。denpa と yosegaki は今も配っている |

### `HelmChart` CRD をやめた理由

chart が悪いのではなく、**入れ方**が合わなくなった。

- **k3s 固有で Talos に無い。** OS を替える時点で全部書き直しになる
- **CR を消すと helm がアンインストールされる。** finalizer 駆動なので外しても付け直される。
  CRD を `templates/` に置く chart だと CRD ごと消えて CR が巻き添えになる
- **ArgoCD と二重管理になる。** 同じリソースを 2 つのリコンサイラが見ることになり、
  差分も同期状態も prune の制御も ArgoCD 側から見えない
- **Job で走るので chart 側の事情が漏れる。** erpnext は Job 名に描き出した時刻を入れるので、
  同期のたびに作り直される

ArgoCD が居ない k3s 単体なら悪い選択ではない。**居るなら重複でしかない。**

### 配る chart で気を付けること

**このセッションで実際に踏んだものだけ**を挙げる。自分の chart(denpa / yosegaki)は
どれも該当していない(CRD 無し、名前は固定、`podAnnotations` と `resources` を出せる)。

| やらないこと | 踏んだ例 |
| --- | --- |
| **リソース名に時刻や乱数を入れない** | erpnext の `erpnext-new-site-20260907103337`。GitOps のリコンサイラは同期のたびに別物として作り直す。一度きりの Job なら名前を固定して、再実行は利用者に任せる |
| **CRD は `templates/` ではなく `crds/` に置く** | infisical の `secrets-operator`。`templates/` にあるとアンインストールで CRD ごと消え、CR が全部巻き添えになる。`crds/` なら helm は消さない |
| **全ワークロードに `podAnnotations` を出す** | erpnext の `mariadb-sts` に無く、k8up の `backupcommand` を付けられなかった。注釈は operator(k8up・Infisical・ArgoCD)が振る舞いを足す口 |
| **`resources` を出す。既定を空にしない** | erpnext 8.0.78 が連れてきた valkey subchart が `resources: {}` かつ `maxmemory` 無し。ノードの空きまで伸びうる |
| **patch で中身を入れ替えない** | erpnext 8.0.15 → 8.0.78(patch)が Dragonfly を Valkey に差し替え、values に書いたチューニングが黙って無効になった |
| **入口を既定で作らない** | `Ingress` を既定 true にしない。denpa / yosegaki は `httpRoute` / `ingress` / `traefik` を全部既定 false にして選ばせている |

### 入れ方は利用者に選ばせる

chart 側は入れ方を知らなくていい。`helm install` でも ArgoCD の `Application` でも
Flux の `HelmRelease` でも同じものが入るのが正しい。**このクラスタは ArgoCD の
`Application` に統一した。**

## HelmChart CRD から ArgoCD の Application へ(2026-09-07)

`HelmChart`(`helm.cattle.io`)は k3s の helm-controller が提供するもので **Talos には無い**。
OS 交換時の変数を減らすため、k3s のうちに ArgoCD の `Application` へ移す。

**移す前に必ず `helm template` の出力と live を突き合わせる。** リリース名まで揃えれば
描き出されるものは一致し、引き取っても Pod は入れ替わらない(実測: cloudflare-ddns・
infisical-operator・infisical-push-bridge の 3 つとも `kubectl diff` が空、Pod の AGE も変わらなかった)。
`secrets-operator` のように名前を切り詰める chart があるので、**リリース名を変えると別物として作り直しになる**。

### **CR を消すと helm がアンインストールされる**

helm-controller は `wrangler.cattle.io/on-helm-chart-remove` finalizer で削除ジョブを走らせる。
finalizer を先に外しても**すぐ付け直される**ので効かない。しかも `secrets-operator` は
CRD を `crds/` ではなく `templates/` に置いているため、**アンインストールすると CRD ごと消えて
`InfisicalSecret` 15 本が巻き添えになる**(Secret は `creationPolicy: Orphan` なので残るが、
値の同期は止まる)。

**手順(この順番でやる)**:

```shell
# 1. Application を先に作って Synced になるのを確かめる(diff が空なら Pod は入れ替わらない)
kubectl apply -f apps/<name>/application.yaml
# 2. helm のリリース Secret を消す。これでアンインストールが「対象なし」になる
kubectl -n <targetNamespace> delete secret -l owner=helm,name=<releaseName>
# 3. HelmChart CR を消す。削除ジョブは走るが何も消さない
kubectl -n kube-system delete helmchart <name>
```

`apps/` に置いたものは ArgoCD が prune するので、git から消すだけで CR も消える。
その場合はアンインストールが走るので、**状態を持つものでは必ず先に 2 をやる**
(cloudflare-ddns では手を抜いて走らせたら Deployment が一度消えて、ArgoCD が数秒で作り直した)。

### 残り

| chart | 状態 | 扱い |
| --- | --- | --- |
| cloudflare-ddns | 移行済み | `apps/cloudflare-ddns/application.yaml` |
| infisical-secrets-operator | 移行済み | `apps/infisical-operator/` |
| infisical-push-bridge | 移行済み | `apps/infisical-push-bridge/` |
| yosegaki | 移行済み | blog リポジトリの `deploy/yosegaki-application.yaml`。PVC 持ちなので上の手順で移した |
| erpnext | 移行済み | `apps/erpnext/application.yaml`。**サイト作成と conf-bench の Job は止めてある**(下記) |
| infisical | 未 | Postgres の PVC を持つ。**Infisical より下の層**なので ArgoCD に預けると鶏卵になる |
| argocd | 移さない | 自分自身。Talos では machine config の `inlineManifests` に載せる |

### erpnext だけは素直に移せない

chart が **Job の名前に描き出した時刻を入れる**(`erpnext-new-site-20260907103337`、
`erpnext-conf-bench-20260907103337`)。ArgoCD は同期のたびに描き直すので、そのまま Application にすると
**毎回名前の違う Job を作っては前のを prune する**。サイト作成ジョブがそれをやるので受け入れられない。

取りうる形は 2 つ。

1. **ジョブを止める。** サイトはもう出来ているので `jobs.createSite.enabled: false` と
   `jobs.configure.enabled: false`(既定は true)にする。まっさらから入れ直すときだけ 1 回有効にして、
   終わったら戻す。**Talos で作り直すときの手順に書いておくこと。**
2. **`jobs.<name>.jobName` で名前を固定する**(chart に値がある)。ただし Job の spec は不変なので、
   中身が変わったときに `Replace=true` が要る。Application 全体に付けると StatefulSet まで
   置き換わるので、そこは慎重に。

**1 の形で移した(2026-09-07)。** `jobs.createSite` と `jobs.configure` を `false` にして
ArgoCD の Application にした。描き出しを突き合わせると**消えるのはその 2 つの Job だけ**で、
残り 25 個は同一だった。引き取っても Pod は入れ替わっていない。

**まっさらから入れ直すときは 1 回だけ `true` にする。** `jobs.configure` は
`common_site_config.json`(DB と Redis の宛先)を書くので、chart を大きく上げて
その宛先が変わるときも 1 回有効にして戻すこと(8.0.78 の Dragonfly → Valkey が実例)。

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


## 依存の更新をどこまで自動で入れるか(2026-09-07)

Renovate は共有プリセット(`5ym/renovate-config`)を使っていて、**全部を 1 つの PR にまとめて自動マージ**する
設定だった。`separateMajorMinor: false` も付いていたので、**postgres 17 → 18 が nginx のパッチと
同じ PR に入り、自動マージの対象になっていた**(danything/gitops#7)。そのまま入っていたら Mattermost が落ちる。

**直したこと**: プリセット側でメジャーを別の PR に分け、`automerge: false` にした(5ym/renovate-config#2)。
パッチとマイナーはこれまでどおり 1 つにまとめて自動マージする。小さくて頻繁で、タグを戻せば済むため。

いまの自動マージの範囲(プリセット `5ym/renovate-config`):

| まとまり | 自動マージ |
| --- | --- |
| `all dependencies`(メジャー以外の全部) | する |
| `major dependencies` | しない |
| `helm charts`(更新の種類を問わない) | しない |

**PostgreSQL は 17 の線に固定した**(`renovate.json` の `allowedVersions: "<18"`)。理由は 2 つ:

- Mattermost が公表しているのは**下限(14.0+)だけ**で、18 を検証したとは書いていない
- PostgreSQL はメジャーが変わるとデータディレクトリの互換が切れる。イメージのタグを差し替えると
  `database files are incompatible with server` で起動を拒否する。上げるには dump と restore が要る
  (この DB は 89 MB なので作業自体は短いが、Mattermost を止める必要がある)

17 のサポートは 2029-11 まであるので急がない。Mattermost が 18 を明記したらそのとき外す。

### メジャーを分けるだけでは足りない(2026-09-07 実例)

プリセットを直した直後に Renovate が #7 を作り直し、**自分でマージした**。残ったのは
postgres 17.10 → 17.11(パッチ、無害)と **erpnext 8.0.15 → 8.0.78**。後者は版の付け方が
パッチなので、メジャーを分ける設定では止まらない。中身は下記のとおり Dragonfly → Valkey の
入れ替えで、values に書いてあったチューニングが丸ごと無効になった。

**版の番号は中身の大きさを表さない。** chart の場合はとくにそうで、自動マージに任せる範囲を
決めるときは「メジャーかどうか」だけでは足りない。

**そこでプリセット側で `helm` の datasource を丸ごと自動マージから外した**
(5ym/renovate-config#3)。chart は更新の種類を問わず人が見る。`helm charts` という別の
グループにしてあるのは、chart を止めることで `all dependencies` の PR まで自動マージ
されなくなるのを避けるため。

### erpnext 8.0.78 は Dragonfly をやめて Valkey になる

chart の 8.0.15 → 8.0.78 は patch に見えるが、**キャッシュとキューが Dragonfly から Valkey に入れ替わる**。
`erpnext-dragonfly-cache` / `-queue` が消えて `erpnext-valkey-cache` / `-queue` になり、
worker の接続先も変わる。いまの values にある Dragonfly のチューニング
(`--proactor_threads=4` と `--maxmemory=1gb`、2026-08 の事故対応)は**丸ごと効かなくなる**。

Valkey は Redis 系なので io_uring の RLIMIT_MEMLOCK 問題は無く、`proactor_threads` は要らない。
ただし chart の既定は `resources: {}` で上限が無いので、**メモリの上限は自分で入れる**こと。
mariadb は `mariadb:10.6` のままなので DB のメジャーは動かない。

## バックアップに何を含めるか

R2 の無料枠(10 GB)に対して実サイズは 3.3 GiB。容量を削るために外した / 外さなかったもの:

| 対象 | 判断 |
| --- | --- |
| AdGuard のクエリログ(`querylog.json`) | **保持を 90d → 7d に短縮**(2026-09-06)。単体で 2.0 GB あった。純粋な計測データで、復元時に無くても困らない。いま 8.8 MB |
| 録画データ(`denpa-recorded`、1.6 GB) | **含める**。放送は取り直せないので、容量より価値を優先する(2026-09-06 本人判断) |
| 保持世代 | 17 → **13**(`--keep-daily 7 --keep-weekly 4 --keep-monthly 2`)。遡れる範囲は約 2 か月 |
| 消した namespace の PV(epg / vpn / opengist、541 MiB) | 退避のうえ削除済み。バックアップ対象外 |
