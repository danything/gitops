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


## ルーティングの選定(2026-09-06 に再検討)

いま Traefik に依存しているもの: 標準 `Ingress` 15、`IngressRoute` 4、`IngressRouteTCP` 1(3proxy、SNI で TLS 終端して 3128 へ)、
`Middleware` 4(redirect-https、forward-auth、forward-auth-errors、yuzuriha)、ACME は Traefik 内蔵(Cloudflare DNS-01)。
forward-auth の先は oauth2-proxy + redis(IdP は Entra ID)。LoadBalancer は k3s 組み込みの ServiceLB(Klipper)。

前提: `Ingress` API は凍結済みで、**ingress-nginx は 2026-03-24 に retire**(リポジトリは read-only、CVE 修正なし)。
新規に組むなら Gateway API。なお F5/NGINX Inc. の `nginxinc/kubernetes-ingress` は別プロジェクトで継続中。

| 案 | 書き換え | 認証 | TCP/UDP | 証明書 | 所感 |
| --- | --- | --- | --- | --- | --- |
| **A. Traefik v3 を継続** | ほぼ 0(HelmChart CRD → ArgoCD の helm source だけ) | Middleware のまま(oauth2-proxy + redis を維持) | IngressRouteTCP/UDP | 内蔵 ACME | 最小工数。Traefik 固有 CRD への依存は続くが、**Traefik v3 も Gateway API 実装を持つ**ので後から寄せる経路はある |
| **B. Envoy Gateway + cert-manager(+ LB)** | Ingress 15 → HTTPRoute(`ingress2gateway` で機械変換可)、IngressRoute 4 と TCP 1 は手動、Middleware → SecurityPolicy と HTTPRoute filter | SecurityPolicy の OIDC が内蔵(Entra に直接)。ExtAuth もある | TCPRoute / UDPRoute / TLSRoute | cert-manager(Cloudflare DNS-01)。**ただし Gateway API 対応は Beta 止まりで `--enable-gateway-api` の明示が要る** | Gateway API 実装として機能が最も揃う。要検証事項あり(下記) |
| C. Cilium(CNI + Gateway API + L2 LB) | B と同程度 + **CNI 交換** | HTTPRoute の ExternalAuth(GEP-1494)が 1.20 pre-release。fail-open のバグ報告あり。OIDC 内蔵は無い | **TLSRoute のみ**(TCPRoute/UDPRoute 非対応) | cert-manager | 1 つで CNI + LB + Ingress を賄えるのは魅力だが、OS 交換と同時の CNI 交換は影響範囲が大きい |
| ingress-nginx / HAProxy / Kong / Istio | — | — | — | — | 前者は EOL。後者は単一ノードに過剰か、Gateway API 対応で B に劣る |

**結論: A(Traefik 継続)。Gateway API への移行は保留する。**(2026-09-06 決定)

理由は 3 つ。

1. **いま困っていない。** ingress-nginx の EOL はこの構成に関係がない(使っていない)。`Ingress` API が凍結されたのは
   「新機能が入らない」という意味で、動かなくなるわけではない。Traefik v3 は現役で、Talos でもそのまま動き、
   ACME(mydnschallenge)も Middleware も IngressRouteTCP も今のまま使える。**書き換えは 0。**
2. **移行の主目的は OS の入れ替えであって、ルーティングの刷新ではない。** 単一ノードで 1 人運用なのに、
   OS・LB・Ingress コントローラ・API モデルを同時に動かすと、何かが壊れたときに切り分けができない。
3. **B の主要な動機(oauth2-proxy + redis の撤去)が条件付きだった。** Envoy Gateway の OIDC は
   トークンを Cookie に持つため 4096 バイトの壁があり、超えると**ログすら出ずに**認証がループする。
   さらに MetalLB を入れれば部品数は差し引きゼロ。cert-manager の Gateway API 対応はまだ Beta で、
   Envoy Gateway 自体もマイナーが 2 週間強に 1 回出る。**得るものに対して回すコストが見合わない。**

### ただし LoadBalancer だけは Talos の前に解決が要る

Ingress の選択とは独立した話。**Talos には k3s の ServiceLB(Klipper)に相当するものが無い**ので、
`type: LoadBalancer` の Service(`adguardhome-dns`、`mattermost-calls`、traefik 本体)をどう受けるか決めておく。

| 案 | 中身 | 評価 |
| --- | --- | --- |
| **MetalLB(L2)** | controller + speaker の 2 Pod。`type: LoadBalancer` のまま動く | **推奨。アプリ側のマニフェストを 1 行も変えずに済む**。Talos でよく使われる道 |
| hostNetwork / hostPort | 追加コンポーネント無し | 部品は減るが Service と Deployment の書き換えが要り、ポートの衝突を手で管理することになる |

単一ノードなら hostNetwork でも成立するが、**移行時の差分を最小にする方が大事**なので MetalLB を採る。
PSA のラベル(`pod-security.kubernetes.io/enforce: privileged`)が speaker に要る点だけ注意。

### Gateway API を再検討する条件

保留であって否定ではない。次のどれかが起きたら測り直す。

- cert-manager の Gateway API 対応が **GA** になる(いまは Beta で `--enable-gateway-api` の明示が要る)
- Envoy Gateway の OIDC の既知問題(#7315 の Cookie 4096 バイト、#8441、#8649)が解決する
- Traefik 側で実際に困る(必要な機能が無い、v3 のサポートが切れる、など)
- Ingress を触る用事がまとまって発生する(そのとき `ingress2gateway` で機械変換すればよい)

Traefik v3 自体が Gateway API 実装を持っているので、**コントローラを替えずに API モデルだけ先に移す**道も残っている。

### 参考: B を選ぶなら確認が要ること(保留中)

**Envoy Gateway の OIDC はトークンをブラウザの Cookie に保存する。** redis が要らなくなるのはこのためだが、既知の問題がある。

| Issue | 内容 |
| --- | --- |
| envoyproxy/gateway#7315 | トークンが **4096 文字を超えるとブラウザが Cookie をセットせず**、認証がループして「リダイレクトが多すぎます」で落ちる。**Envoy 側にエラーログが出ない** |
| envoyproxy/gateway#8441 | OIDC Discovery が失敗すると毎リクエスト token introspection にフォールバック。IdP 停止時に白画面 |
| envoyproxy/gateway#8649 | Gateway レベルとルートレベルで SecurityPolicy を二重掛けすると CSRF 検証で落ちる |

Entra ID はグループクレームが増えると 4 KB を容易に超える。**実測(2026-09-06)**: oauth2-proxy が redis に置いている
セッションは **4293 バイト**(1 セッション)。ID・アクセス・リフレッシュの 3 トークンとメタデータをまとめて
暗号化した値なので個々は 4096 を下回っているはずだが、余裕は小さい。B を再検討するときは
生の ID トークン長(ブラウザの `IdToken` Cookie の長さ)を測ってから決める。

`cookieDomain` はサブドメイン間で共有するなら root domain(`.doany.io`)を指定する。後から変えるとブラウザに残った
古い Cookie が優先されて認証が壊れるので、変更時は Cookie クリアが要る。

### 部品数は減らない(当初の説明の訂正)

「auth namespace の 2 Deployment が消える」と書いていたが、**MetalLB を入れると controller + speaker で 2 ワークロード増える**
ので差し引きゼロ。単一ノードなら MetalLB 自体が過剰かもしれない。Envoy Gateway は `EnvoyProxy` CRD でプロキシの
Deployment をパッチできるので、**hostNetwork にすれば LB コントローラは要らない**(Talos では namespace に
`pod-security.kubernetes.io/enforce: privileged` ラベルが必要)。

### 段階移行(同時にやらない)

「OS 交換」「Ingress コントローラ交換」「API モデル移行(Ingress → Gateway API)」を同時にやると、単一ノードでは
障害の切り分けができなくなる。Gateway API の可搬性を活かして各段階でロールバック可能にする。順番は ROADMAP 参照。

### バージョンの回転が速い

Envoy Gateway は 1.9.1(2026-08-28、Envoy 1.39.0 / Gateway API v1.6.1)。マイナーが 2 週間強に 1 回出てサポート窓も短い。
**Talos / Kubernetes / Gateway API CRD / Envoy Gateway の 4 つのバージョンマトリクスを回す前提**でコストを見る。
GitHub スターは約 2.9K と少なく見えるが、2022 年発表と新しいこと、Envoy 本体にスターが吸われていること、
Contour / Emissary を統合した共通コアとして設計され実利用の多くが下流製品経由であることによる。
同カテゴリ(Kong IC、NGINX Gateway Fabric、Contour)も 2〜4K のレンジ。ただし日本語の事例が少ないのは実害。

### 保留中に残る論点(いま決めなくてよい)

- Entra ID の生の ID トークン長(B を再検討するときの前提)
- `IngressRoute` 4 本と `Middleware` 4 つの中身。機械変換できない部分の実工数はここで決まる
- `IngressRouteTCP`(3proxy)は TLS passthrough で足りるか

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
