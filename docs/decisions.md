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
| ArgoCD + ApplicationSet(repos.yaml)+ 各 repo の `deploy/argocd.yaml` | firewalld 無効化などホストの手作業 |
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

**手で持つのは age のパスフレーズ 1 つだけ。** 他は全部、そのパスフレーズから辿れるところに置いてある。

| | 置き場 | 開け方 |
| --- | --- | --- |
| R2 の鍵 + restic のパスフレーズ | `recovery/env.age`(公開 repo) | **パスフレーズで直接**(`age -d`) |
| SOPS の age 秘密鍵 | `recovery/sops-age.key.age`(公開 repo) | **パスフレーズで直接**(`age -d`) |
| Talos の `secrets.yaml` | `talos/secrets.yaml`(公開 repo・SOPS 済み) | 上の age 鍵で(`sops -d`) |
| `bootstrap/` の Secret 4 つ | 公開 repo・SOPS 済み | 同上 |

**`recovery/` の 2 つだけ `age -p` なのは、それが「まだ何も無い状態で最初に開けるもの」だから。**
それ以外は age 鍵さえ手に入れば開くので、`bootstrap/` と同じ SOPS に揃えてある(例外を増やさない)。

**`talosconfig` は保存しない。** `secrets.yaml` から `talosctl gen config` で毎回出てくる派生物で、
TTL も付いている。使い捨てにするほうが安全(../talos/README.md)。

### そのパスフレーズをどこに置くか(2026-09-08 決定)

**公開 repo に暗号文が載っている以上、オフラインで無限に総当たりされる。強度がすべて**なので
diceware 6〜7 語相当を使う。置き場は次の 3 つ。**同期ストレージ(OneDrive など)を正本にしない** ──
復元のときに Microsoft アカウントへのログインと MFA デバイスが要るようになり、
「`curl` 1 本とパスフレーズだけ」という前提が崩れる。

| | 何を置くか | 理由 |
| --- | --- | --- |
| **パスワードマネージャ**(正本) | パスフレーズ + **何を開ける鍵かと復元手順の URL** | 携帯から取れる。**クラスタの Entra とは独立した認証**であること(Infisical は循環するので不可) |
| **紙、2 か所**(1 つは家の外) | 同上 + `recovery/*.age` を base64 で印刷 | 火事・盗難・端末紛失に耐える。2 ファイル合わせて **19 行**しかない |
| **記憶** | パスフレーズ | 出先で全部が閉じている状況を消す。ただし単独では信用しない |

**紙に `recovery/*.age` も刷るのは、GitHub が使えない場合のため。** 「GitHub へのログインは要らない」設計では
あるが、**リポジトリが読めることは前提にしている**(公開停止・障害・アカウント凍結)。
`env.age` が 660 バイト、`sops-age.key.age` が 371 バイトなので、印刷しても数分の手間にしかならない。

**紙には必ず「何の鍵か」と `recovery/README.md` への道筋を書く。** 数年後に見つけた自分が、
それが何か分からないのでは意味がない。

**暗号文の副本は OneDrive の Personal Vault でよい。** あれは公開 repo に載っているものなので、
置き場に機密性を求めていない(Microsoft が鍵を持っていても関係ない)。無料プランの
「3 ファイルまで」にも収まる。**ただしパスフレーズは同じ場所に入れない** ── 入れると
Microsoft アカウント 1 つで全部になる。

### 検討して見送ったもの

- **暗号文を公開 repo から外す。** 「パスフレーズ **+** 保管先」の 2 つが要る形になり防御は一段厚くなるが、
  **`curl` 1 本で始められる**という復旧手順の軽さを失う。暗号文が公開でも、パスフレーズが
  diceware 6〜7 語なら総当たりは成立しない。
- **YubiKey(`age-plugin-yubikey`)で SOPS の鍵をハードウェアに置く。** 効くのは保管場所の問題ではなく
  **「復号のたびに秘密が手元の PC の RAM とディスクに載る」ほう**で、そちらのほうが実害の確率は高い。
  ただし YubiKey 2 本 + 紙の復旧用鍵が要り、復旧時に `pcscd` と plugin の導入が増える。
  **入れるとしたら SOPS の鍵だけ**(`recovery/env.age` は最初に開けるものなので軽いまま残す)。
  `age -p` と他の recipient は同じファイルに混ぜられないので、この分け方は技術的にも自然。

秘密 gist や平文コミットにしなかった理由: R2 の鍵は「バックアップを消せる鍵」で、GitHub のトークンはあちこちに
散っている(`~/.git-credentials`、gh、Actions、ArgoCD の App 資格情報)ので、GitHub 側が丸ごと漏れても
バックアップだけは無事な状態を残す。

リモートは Cloudflare R2 のバケット `doany-restic`(APAC、Standard)に決定(2026-09-06)。API トークンは
Object Read & Write をこのバケットだけに絞った Account API token。
復元時に `rclone config` の対話が要らなくなり、in-cluster(k8up)からも同じ設定で使える。


## DB の整合性の取り方

- **k3s 期**: ホストの `backup/k3s-backup` が、対象 namespace を scale down してからコピーする。
- **Talos 期**: **scale down しない。** k8up の `k8up.io/backupcommand` で論理バックアップを取る。
  **2026-09-08 に全 11 namespace で完了**(RDBMS 3 つは `pg_dump` / `mariadb-dump`、SQLite 6 つは
  `bun:sqlite` の `serialize()`、ファイルの PVC は注釈)。**どれが何で取れているかの一覧は
  [../apps/k8up/README.md](../apps/k8up/README.md)** ── ここには写さない(二重に持つと片方が腐る)。


## Talos では `bootstrap/` をどう適用するか

**下の「Talos の起動順序をどう組むか(2026-09-07)」に書き直した。** ここには当初の見立てだけ残す:

- `machine config` の inlineManifests が「Argo CD より下の層」を引き受ける、という筋は変わっていない
- **ただし当初「手で apply する層が消える」と書いたのは外れた。** 実際には二段階になり、
  適用は GitHub Actions に移った([bootstrap/README.md](../bootstrap/README.md))。
  machine config が持つのは「そこへ辿り着くまで」だけ
- **inlineManifests は Talos 自身は更新しない**が、**`talosctl upgrade-k8s` を通せば
  更新も削除もされる**(2026-09-08 に VM で実測。[talos.md](talos.md))。
  当初「create-once で reconcile ではない」と書いたのは**半分誤り**だった

## ルーティングの選定(2026-09-06)

移行前に Traefik に依存していたもの: 標準 `Ingress` 15、`IngressRoute` 4、`IngressRouteTCP` 1(3proxy)、
`Middleware` 4、ACME は Traefik 内蔵(Cloudflare DNS-01)。forward-auth の先は oauth2-proxy + redis(IdP は Entra ID)。
LoadBalancer は k3s 組み込みの ServiceLB(Klipper)。

前提: `Ingress` API は凍結済みで、**ingress-nginx は 2026-03-24 に retire**(read-only、CVE 修正なし)。
新規に組むなら Gateway API。F5/NGINX Inc. の `nginxinc/kubernetes-ingress` は別プロジェクトで継続中。

### 結論: Cilium(CNI + Gateway API)に寄せる

**Talos で後から替えるのが高いのは CNI だけ**なので、そこを先に決める。Ingress コントローラ・LB・証明書は
Gateway API に寄せてあれば後から差し替えられる。単一ノードのうちは Cilium は過剰に見えるが、
ハイブリッド化の見込みがあるならここで払うのが一番安い。**VM で実際に組んで動くことを確認済み**(下記)。

| | 選択 | 置き換わるもの |
| --- | --- | --- |
| CNI | Cilium | flannel |
| kube-proxy | Cilium の kubeProxyReplacement | kube-proxy |
| LoadBalancer | 使わない(hostPort と Gateway の hostNetwork で足りた。下記) | ServiceLB(Klipper)。**MetalLB は不要になる** |
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
  **段階 2 でほぼ解消した**(2026-09-07 実測)。hostPort と Gateway の hostNetwork に寄せた結果、
  Pod からは `10.10.0.4` のどのポートにも届く。ノード自身から届かないのは **80/443 だけ**で、
  これは Gateway の nodePort が L7LB リダイレクトとして載っているため(同上の `nodePort`)。
  そのリダイレクトは**外から来る通信の経路そのもの**なので外せない。

### LoadBalancer をどう置き換えるか(2026-09-06 決定・実施済み)

Talos には k3s の ServiceLB(klipper)が無いので、その差分を k3s のうちに埋めた。**hostPort を選んだ。**

ServiceLB は**ノード自身の IP**(`10.0.0.2` / `10.10.0.4` / `240f:6d:842b:1::2`)をそのまま EXTERNAL-IP にする作りで、
ルータの DMZ 転送先と AdGuard の split-horizon がこの IP に固定されている。Cilium LB-IPAM で仮想 IP を払い出すと
**クラスタ外(ルータと DNS)の変更が必要**になり、IPv6 のプレフィックスは RA 由来で変わりうるため `externalIPs` への
固定書きも危うい。hostPort ならノードの全アドレスで受けられ、送信元 IP も保たれ、Talos でも同じ形が使える。
ノードが増えたときに VIP が要るなら、そのとき LB-IPAM に移ればよい。

| 対象 | hostPort |
| --- | --- |
| Gateway(`cilium-gateway-doany`) | 80 / 443。Envoy が hostNetwork で bind するが、**実通信は nodePort の L7LB リダイレクト経由**(2026-09-08 実測。`bootstrap/cilium/values.yaml` の `nodePort`)。手で当てた 80/443 は今も要る |
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
  当初は LB-IPAM + L2 アナウンスでアドレスを払い出していたが、**`gatewayAPI.hostNetwork` に
  したらノードの IP がそのまま `status.addresses` に入った**ので、どちらも外した(2026-09-07)。
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
`Local` にすると Envoy の居るノードだけが応答するので、外側の振り分けもそれに合わせる
(いまは Envoy が hostNetwork でノードの 80/443 を直接掴んでいるので、宛先はノードの IP そのもの)。

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
アプリ側(ArgoCD、ERPNext、Mattermost、denpa、NetBird)はそれぞれ自前で OIDC を持っている。

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
tamasagashi の HTTPRoute(`danything/tamasagashi` の `deploy/httproute.yaml`)に
`sessionPersistence` を足す**のが本筋。
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

## PVC を守る仕掛けをやめた(2026-09-07)

**「git で消したものは消える」を優先する**、という判断(本人)。それまでは二重に守っていた。

| 仕掛け | やめた理由 |
| --- | --- |
| PVC の `argocd.argoproj.io/sync-options: Prune=false,Delete=false` | **これが本丸。** これがある限り git から消しても PVC は残る。GitOps の一貫性を損なう |
| StorageClass `local-path-retain`(`reclaimPolicy: Retain`) | **追われない状態を作る。** 実際、35 日と 44 日放置された Released の PV が 3 本あった(2026-09-07 の掃除で発見) |

**代わりの後ろ盾はバックアップ。** 日次の restic(R2)に加えて、DB 3 つは k8up が論理バックアップを取る。
誤って消したときの最大損失は 24 時間ぶん。**この判断は復元リハーサルが Cilium 構成で通ってから**行った
([docs/restore-drill.md](restore-drill.md))。通らなければ守りを外す根拠が無かった。

**承知しておくこと**: `Delete=false` も外したので、**Argo CD の Application を消すと PVC も消える**。
マニフェストを消すのは git のレビューを通るが、Application の削除は UI のボタン 1 つで済む。
そこの重みは違う、という点は残る。

**`storageClassName` はバインド済み PVC では変更も削除もできない**(API が拒否する)。
既存ぶんは `local-path-retain` のままで、PV の `persistentVolumeReclaimPolicy` を `Delete` に
パッチして挙動だけ揃えた。マニフェストから消せるのは **Talos の再構築時**で、
そのとき既定の `local-path`(reclaim は `Delete`)になる。

## バックアップに何を含めるか

R2 の無料枠は 10 GB。**もう超えている。**

| 日付 | リポジトリの実サイズ | できごと |
| --- | --- | --- |
| 2026-09-06 | 3.3 GiB | |
| 2026-09-07 | 13.92 GiB | `denpa-recorded` が 14 GB まで育っていた → 除外した |
| **2026-09-08** | **23.2 GiB** | **`denpa-library` が 972 MB → 7.9 GB に育った**(圧縮後 10.1 GiB) |

**除外では解決しない。** `denpa-recorded` を外した効果は保持世代が回れば出るが、
今度は「取ると決めた」`denpa-library` そのものが伸びている。

**決定(2026-09-08): 有料でも取る。** 無料枠に収めることを目的にすると録画を捨てることになり、
本末転倒。超過分は従量課金で、23 GiB なら **月 $0.2 前後**。R2 は下り(egress)が無料なので、
復元のたびに費用が跳ねる心配も無い。**無料枠は制約ではなく目安**として扱う。
容量そのものが問題になるのは、桁が変わったとき(数百 GB)。

容量を削るために外した / 外さなかったもの:

| 対象 | 判断 |
| --- | --- |
| AdGuard のクエリログ(`querylog.json`) | **保持を 90d → 7d に短縮**(2026-09-06)。単体で 2.0 GB あった。純粋な計測データで、復元時に無くても困らない。いま 8.8 MB |
| 録画データ | **エンコード済みの `denpa-library` は含める。** 放送は取り直せないので容量より価値を優先する(2026-09-06 本人判断)。**育っている**ので要監視 ── 2026-09-06 に 972 MB、2026-09-08 の実測で 7.9 GB(restic 上は 10.1 GiB) |
| `denpa-recorded`(生 TS の作業領域) | **除外した(2026-09-07)。** 1.6 GB だったものが **14 GB** まで育ち、リポジトリ実サイズが 13.92 GiB と **R2 の無料枠 10 GB を超えていた**。エンコードが終われば消える置き場で、中身は数時間で入れ替わるので日次のスナップショットに残す意味も薄い |
| 保持世代 | 17 → **13**(`--keep-daily 7 --keep-weekly 4 --keep-monthly 2`)。遡れる範囲は約 2 か月 |
| 消した namespace の PV(epg / vpn / opengist、541 MiB) | 退避のうえ削除済み。バックアップ対象外 |

## VPN を wg-easy から NetBird にした(2026-09-07)

wg-easy を使う理由は **プライバシー(全部を自宅経由にする)・DNS(AdGuard)・iLO(10.0.0.3)に入る**の 3 つだけで、
どれも「自宅の LAN に入れれば済む」もの。UI に不満はあったが、**スマホを足すときの QR は実際よく使う**ので
UI を捨てる方向は取らなかった。

比較したもの:

| | 結論 |
| --- | --- |
| **wg-easy 続投** | 動いてはいる。ただし自前の認証を切れず(要望 [wg-easy#1923](https://github.com/wg-easy/wg-easy/issues/1923) が 2025-06 から open)、SSO の後ろに置いても**二重ログイン**が残る |
| **wg-portal** | star は少ないが機能は足りる。ただし乗り換える動機が wg-easy 比で薄い |
| **Headscale** | 完成度は高い。**が、FAQ が「headscale を動かすマシンをサブネットルータにするな」と明記している。** ノードが 1 台のこの構成では回避できない。コンテナは「サポート対象外」だが放置ではなく(コンテナ/プロキシ関連の PR は 48 本マージ済み、[#3292](https://github.com/juanfont/headscale/pull/3292) は reverse-proxy のドキュメントを書き直している)、境界の引き方の問題 |
| **NetBird** | **採用。** routing peer が独立した概念で、コンテナで動かす前提のドキュメントがある。1 台構成でも上の問題が起きない |

star は headscale が 43.6k、netbird が 29.0k で headscale のほうが多い。**が、動いている量は netbird が上**
(2026-09-07 時点、直近 30 日のコミット 119 対 45、作者 21 人対 10 人、直近 90 日のマージ済み PR 399 対 51、
1 年のリリース 109 対 16)。netbird の open issue 1,583 は放置ではなく分母の差で、
GUI クライアント・IdP 連携・ポリシーまで同じリポジトリに入っている。

**公式 Helm chart は使わない。** [netbirdio/helms](https://github.com/netbirdio/helms) の `charts/netbird` は
2026-04-24 から更新が止まっていて appVersion `0.46.0`(本体は `0.78.1`)。
[#39](https://github.com/netbirdio/helms/issues/39) で指摘され、中の人が「combined に寄せるか両対応か」と
返したきり半年動いていない。archived ではないので廃止ではなく**宙に浮いている**。
上流は v0.65.0 で management/signal/relay を 1 つにまとめた **combined コンテナ**に移っており、
素の Deployment で足りる(`apps/netbird/`)。

組み方で引っかかった点:

- **gRPC と HTTP が同じホスト名・同じポートに混在する。** `management.ManagementService` と
  `signalexchange.SignalExchange` を GRPCRoute に、`/api` `/oauth2` `/relay` `/ws-proxy` を HTTPRoute に、
  残りをダッシュボードに振った。GRPCRoute なら Cilium が backend を h2c 扱いするので、
  `enable-gateway-api-app-protocol` を有効にせずに済む(= Gateway の設定を触らない)。
  同じリスナー・同じホスト名に GRPCRoute と HTTPRoute を同居させても既存の 16 ルートは無傷だった
- **STUN(UDP 3478)はリバースプロキシを通せない**ので hostPort。namespace の PSA が `privileged` なのはこのため
- **`livenessProbe` は付けない。** healthcheck は `localhost:9000` にしか bind されず、kubelet からは必ず落ちる
- **外部 IdP(Entra)は設定ファイルに書けない。** 0.62 以降、外部 IdP は config ではなく**ストアに入るデータ**になった。
  ダッシュボードか `POST /api/identity-providers` で足す。リダイレクト URI は issuer + `/callback` で
  決まる(`idp/dex/connector.go`)ので `https://nb.doany.io/oauth2/callback` 固定、Entra 側を先に作れる

## 公開経路(HTTPRoute)をどこに置くか(2026-09-07)

`apps/gateway-routes/` に全部まとめていたのをやめ、**それぞれが公開しているものと同じ場所**に置いた。

ArgoCD は `sourcePath` 配下を `recurse` で拾い、追跡は `argocd.argoproj.io/tracking-id` 注釈
(`<app名>:<GVK>:<ns>/<name>`)で行うので、**ファイルの場所は挙動に影響しない**。純粋に読み手の都合。

| 行き先 | 対象 |
| --- | --- |
| このリポジトリの `apps/<name>/httproute.yaml` | adguardhome / erpnext / infisical / mattermost / netbird / portainer |
| 各アプリのリポジトリの `deploy/httproute.yaml` | blog / yosegaki / lgtm / tamasagashi / worklog / xool / yuzuriha |
| `bootstrap/` | argocd / auth ×3 / redirect-https |

**`bootstrap/` に移したものが本題。** `argocd` と `auth` の実体はこの層にあり、**ここは ArgoCD が
同期していない**。つまり「ArgoCD が ArgoCD 自身を公開している経路を握っている」状態で、
ArgoCD が壊れているときにその経路を ArgoCD 経由でしか直せない、という順序の逆転があった。

**まとめて 1 か所に置く利点(公開しているものの一覧になる)は失う。** 代わりに
`apps/gateway-routes/README.md` …ではなく、この表と `bootstrap/README.md` が索引になる。
外部露出を一覧したいときは `kubectl get httproute,grpcroute -A` が正確で、git を読むより早い。

### 落とさずに動かす手順

ArgoCD は「git から消えた + 自分が追跡している」ものを prune する。単に移すと**移動の瞬間に
公開経路が落ちる**。使った回避は 2 通り:

- **別リポジトリへ移すもの** — 移送先を**先に**マージする。そのアプリの Application が同じ
  ルートを apply した時点で tracking-id が書き換わり、元の Application の管理から外れる。
  そのあと元から消せば prune は起きない。7 本とも移動後に tracking-id を確認してから消した
- **`bootstrap/` へ移すもの** — 引き取り手が居ないのでこの手が使えない。先に
  `argocd.argoproj.io/sync-options: Prune=false` を live に効かせておき、そのあと移す。
  移し終えたら live の tracking-id 注釈を剥がして、`Prune=false` も外す

## machine config と Cilium の chart をどう連動させるか(2026-09-08 決定)

Talos では Cilium を `inlineManifests` に載せる。**では `bootstrap/cilium/values.yaml` と
machine config の中の Cilium を、人が手で合わせるのか。** 合わせない。**machine config を
「派生物」にする。**

### `gen config` のときに描く

`helm template` の出力を `KubeInlineManifestConfig` に包んで、ただの `--config-patch` として渡す。
**Cilium の値がリポジトリに二度書かれることが無くなる。**

```shell
{
  echo "apiVersion: v1alpha1"; echo "kind: KubeInlineManifestConfig"; echo "name: cilium"
  echo "manifest: |-"
  helm template cilium cilium/cilium --version "$(yq -r .version bootstrap/cilium/version.yaml)" \
    -n kube-system -f bootstrap/cilium/values.yaml --kube-version "$K8S" | sed 's/^/    /'
} > /tmp/cilium-inline.yaml
```

実際に作って確かめた(2026-09-08): 2329 行の manifest が埋まり、`talosctl validate --mode metal` を通る。
生成物では 1 行のエスケープ文字列になるので、machine config 自体は 450 行のまま読める。

**Renovate は `bootstrap/cilium/version.yaml` を見ている**ので、版が上がれば PR が来る。
machine config は毎回そこから描き直されるだけで、追従の作業は無い。

### **罠: `upgrade-k8s` は Cilium も巻き戻す**

`inlineManifests` は **`talosctl upgrade-k8s` を通すと reconcile される**(talos.md)。
`upgrade-k8s` は Kubernetes を上げるときの通常の操作でもあるので、
**machine config の中の Cilium が古いまま流すと、走っている Cilium が巻き戻る。**

したがって **`upgrade-k8s` の前には必ず machine config を描き直す**。手順の一部として書くこと。

### 帰結: Talos 期は `helm upgrade` を使わなくなる

Cilium の更新経路は「`values.yaml` を直す → machine config を描き直す → `upgrade-k8s`」になる。
**`bootstrap/cilium/values.yaml` が正本なのは変わらない**が、当てる道具が替わる。
[cilium-drift.yml](../.github/workflows/cilium-drift.yml) のズレ検出は k3s 期のもので、
Talos では `upgrade-k8s` 自身が差分を出す(`< configured ...` と diff)ので役目を終える。

### 採らなかった案

**Cilium を machine config に載せず、bootstrap のあとに `helm install` する。** 罠は消えるが、
再構築のたびに手作業が 1 つ増える(しかも「CNI が無いので何も動かない」状態での作業)。
Sidero は inline manifest を production 推奨、CLI での install を "least declarative" としている。

## Talos の起動順序をどう組むか(2026-09-07)

k3s の `HelmChart` CRD(`helm.cattle.io/v1`)は **Talos に無い**。いま `bootstrap/` に残っている
argocd と infisical はどちらもそれで入れているので、移行時に置き換えが要る。
「inlineManifests に載せる」と一言で書いていたが、**inlineManifests は Helm を実行できない**ので
そのままでは移せない。

### 前提の確認: ArgoCD は Infisical 無しで起動する

「ArgoCD に infisical を預けると鶏卵になる」としていたが、**実際には循環していない**。
ArgoCD の設定にある `$argocd-oidc:client-secret` のような参照は、
[`util/settings/settings.go`](https://github.com/argoproj/argo-cd/blob/master/util/settings/settings.go) で
こう扱われる:

```go
secretVal, ok := secretValues[secretKey]
if !ok {
    log.Warn("secret key does not exist in secret")   // 警告するだけ
    return val                                         // 文字列をそのまま返す
}
```

**Secret が無くても落ちない。** OIDC が未解決のまま起動し、**SSO ログインだけが効かない**。
そして **同期の動作自体に誰のログインも要らない**。つまり順序は素直に解ける:

**Cilium → ArgoCD 起動 → ArgoCD が Infisical を入れる → operator が Secret を作る → SSO が効くようになる**

**承知しておくこと**: `admin.enabled: false` にしてあるので、**この窓の間は UI に誰も入れない**
(SSO 未解決 + ローカル admin 無効)。困ることがあれば `kubectl` で見る。移行当日に UI が要るなら、
一時的に `admin.enabled` を戻す。

### 層の分け方

| 層 | 中身 | 資格情報 |
| --- | --- | --- |
| **machine config(inlineManifests)** | Cilium(`helm template` の出力)、ArgoCD(同)、`bootstrap-applier` の RBAC、**SOPS 済みの Secret 4 つ** | machine config 自体が SOPS 済みなので同じ信頼水準 |
| **GitHub Actions** | `bootstrap/` の残り(平文のもの) | OIDC。**Secret 権限なし・delete なし**の狭い RBAC |
| **ArgoCD** | `apps/`(**Infisical もここに移す**) | — |

**なぜ ArgoCD を CI 側に置かないか。** ArgoCD の導入には CRD・ClusterRole・Secret が要る ──
つまり実質 cluster-admin。CI の RBAC を狭く保っている意味が消える
([bootstrap/apiserver/rbac.yaml](../bootstrap/apiserver/rbac.yaml))。**入れるものと当てるものを層で分ける。**

**なぜ SOPS の Secret を machine config に入れるか。** CI には age 鍵を渡さない方針なので、
CI からは当てられない。一方 machine config は**もともと SOPS で暗号化して git に置いている**
(クラスタ CA の秘密鍵を含むので当然)。**同じ場所に置いても信頼水準は変わらない**うえ、
起動時点で存在するので順序の問題も消える。復号は手元の `talosctl gen config` のときだけ起きる。

**Helm の出力をコミットすることについて。** Cilium は CNI なので inlineManifests 以外に置きようがなく、
`helm template` の出力を持つのは避けられない(Talos 公式も同じ形)。ArgoCD も同じ扱いにすれば、
**Helm を実行する場所がクラスタの外(手元の生成時)だけ**になり、クラスタ内に Helm コントローラを
持たなくて済む。版の追従は `talos/versions.yaml` と同じく Renovate に見せる。
