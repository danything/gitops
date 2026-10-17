# 決定の記録

なぜこの技術・この形を選んだかをここに置く。手順と進捗は [`../ROADMAP.md`](../ROADMAP.md)。

## 層ごとに戻し方を分ける

ノードにシェルが無いので、「k8s オブジェクト」は **git から ArgoCD で再構築**(etcd スナップショットは近道)、
「ホスト設定」は machine config(git 管理)、「PV データ」だけがバックアップツールの仕事になる
(手順は [../recovery/README.md](../recovery/README.md))。**ツール選定は PV データの部分にしか効かない。**

変えないと決めてあるもの: restic のリポジトリ形式・パスフレーズ・バケット、local-path の PV ディレクトリ構造
(`pvc-<uid>_<ns>_<name>`)、Infisical のデータと `ENCRYPTION_KEY`、ArgoCD + ApplicationSet + 各 repo の `deploy/argocd.yaml`、
**復元手順は公開で秘密を含まない**という性質。

## Z440 へは Talos のまま移す(2026-10-17)

OS の入れ替え(Talos への移行)は DL360 で済ませ、Z440 へは Talos のノードとして移す([z440-migration.md](z440-migration.md))。

- **Z440 は単体の GPU が無いと POST しない**(Xeon E5 に内蔵 GPU は無い)ので、ヘッドレスで組めない。
  Intel Arc A310 を常設する(UEFI + CSM 無効が要る)。これが denpa の QSV / AV1 エンコードも兼ねる
- Z440 の遠隔管理は **AMT 9.x(電源と SOL だけ、KVM なし)**。一番危ない OS の入れ替えは、
  **iLO(10.0.0.3)で画面まで見える DL360** でやった
- Talos なら、箱の違いは schematic(GPU の extension、SOL 用の `console=`)と NIC の名前に閉じる

## bond0 の MAC を固定する(2026-10-17)

ルーターの IPv6 ホスト公開はノードを **bond0 の MAC(`e6:2c:1b:1a:a0:39`)で指している**
([router.md](router.md)「IPv6 はノードだけを公開する」)。固定しないと bond は先頭のメンバーの MAC を引き継ぎ、
**再起動で `3a:43:95:a9:3e:b1` に変わってエントリから外れたことがある。**
[talos/patches/cluster.yaml](../talos/patches/cluster.yaml) の `BondConfig` に `hardwareAddr: e6:2c:1b:1a:a0:39` を書いた。
**bond に固定値を与えるので、NIC の交換でも Z440 への移設でも変わらない。**

## ツール選定(比較の結論)

判断基準は、(1) in-cluster で動かせること、(2) **手元からも同じリポジトリを同じコマンドで読める**こと、
(3) 復元の依存物が「バイナリ 1 つ + 秘密 1 組」で済むこと、の 3 つ。

| 候補 | 判定 |
| --- | --- |
| **restic** | ◎ **k8up**(restic の operator)か restic イメージの CronJob。手動復元も `restic restore` 1 本 |
| kopia | ○ 単体性能は上だが、Velero の node-agent は Velero 固有のレイアウトで、kopia CLI からの手動復元が素直でない |
| Velero | △ git からの再構築と役割が被り、復元に Velero 自体の導入が要る |
| tar + rclone crypt / borg / duplicacy | × in-cluster に持っていけない、整合性 `check` が無い、ライセンス |
| Longhorn 等のストレージ層バックアップ | × 単一ノードには過剰 |

**結論: restic(k8up)。** k8up の中身は素の restic なので、k8up が気に入らなければ CronJob + restic イメージに落とせるし、
k8up の取ったスナップショットも手元の restic CLI で読める(Infisical はそうやって戻す)。将来 rustic(restic 互換の Rust 実装)へ逃げる道もある。

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

**scale down しない。** k8up の `k8up.io/backupcommand` で論理バックアップを取る
(RDBMS は `pg_dump`、SQLite は `bun:sqlite` の `serialize()`、ファイルの PVC は注釈)。**どれが何で取れているかの一覧は
[../apps/k8up/README.md](../apps/k8up/README.md)** ── ここには写さない(二重に持つと片方が腐る)。

## Talos の起動順序をどう組むか(2026-09-07)

argocd と infisical は `bootstrap/` に `HelmChart` CR(`helm.cattle.io/v1`)の形で持っているが、
Talos にその CRD(helm-controller)は無く、**inlineManifests は Helm を実行できない。**
そこで手元の `render.sh` が `helm template` して載せる(下の「層の分け方」)。

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
(SSO 未解決 + ローカル admin 無効)。困ることがあれば `kubectl` で見る。建て直しの最中に UI が要るなら、
一時的に `admin.enabled` を戻す。

### 層の分け方

| 層 | 中身 | 資格情報 |
| --- | --- | --- |
| **machine config** | **`bootstrap/` のほぼ全部。** inline が 9 つ(cilium / local-path / metrics-server / `bootstrap-applier` の RBAC / argocd / cert-manager / infisical / SOPS の Secret 2 つ)、CRD だけ URL で 5 つ(gateway-api / argocd ×3 / cert-manager) | machine config 自体が SOPS 済みなので同じ信頼水準 |
| **GitHub Actions** | `bootstrap/` の残り(`ClusterIssuer`・Gateway・auth・`InfisicalSecret` など、平文のもの) | OIDC。**Secret 権限なし・delete なし**の狭い RBAC |
| **ArgoCD** | `apps/`(**infisical は来ない**。下の「infisical だけは ArgoCD に移せない」) | — |

**CRD だけ URL で渡すのは大きさの都合。** argocd 1.83 MB・cert-manager 1.30 MB・
gateway-api 1.1 MB で、埋めると machine config が 341 KB → 4 MB を超える。
`KubeExternalManifestConfig` は Talos がそのために用意している入口
([talos/render.sh](../talos/render.sh))。

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

**当初の見立てとのずれ**: 「手で apply する層は消える」「inlineManifests は reconcile されない」はどちらも外れ
(上の二段になり、`talosctl upgrade-k8s` を通せば更新も削除もされる。[talos.md](talos.md))。

## machine config と Cilium の chart をどう連動させるか(2026-09-08 決定)

Talos では Cilium を `inlineManifests` に載せる。**では `bootstrap/cilium/values.yaml` と
machine config の中の Cilium を、人が手で合わせるのか。** 合わせない。**machine config を
「派生物」にする。**

### `gen config` のときに描く

`helm template` の出力を `KubeInlineManifestConfig` に包んで、ただの `--config-patch` として渡す
([talos/render.sh](../talos/render.sh) がやる)。**Cilium の値がリポジトリに二度書かれることが無くなる。**
2026-09-08 に確かめた: 2329 行の manifest が埋まり、`talosctl validate --mode metal` を通る。
生成物では 1 行のエスケープ文字列になるので、machine config 自体は 450 行のまま読める。

**Renovate は `bootstrap/cilium/version.yaml` を見ている**ので、版が上がれば PR が来る。
machine config は毎回そこから描き直されるだけで、追従の作業は無い。

### **罠: `upgrade-k8s` は Cilium も巻き戻す**

`inlineManifests` は **`talosctl upgrade-k8s` を通すと reconcile される**(talos.md)。
`upgrade-k8s` は Kubernetes を上げるときの通常の操作でもあるので、
**machine config の中の Cilium が古いまま流すと、走っている Cilium が巻き戻る。**

したがって **`upgrade-k8s` の前には必ず machine config を描き直す**。手順の一部として書くこと。

### 帰結: `helm upgrade` を使わない

Cilium の更新経路は「`values.yaml` を直す → machine config を描き直す → `upgrade-k8s`」。
`upgrade-k8s` 自身も差分を出す(`< configured ...` と diff)が、流し忘れたことは教えてくれないので
[cilium-drift.yml](../.github/workflows/cilium-drift.yml) が週次で live と突き合わせる。

### 採らなかった案

**Cilium を machine config に載せず、bootstrap のあとに `helm install` する。** 罠は消えるが、
再構築のたびに手作業が 1 つ増える(しかも「CNI が無いので何も動かない」状態での作業)。
Sidero は inline manifest を production 推奨、CLI での install を "least declarative" としている。

## ルーティングの選定(2026-09-06)

それまでは Traefik(標準 `Ingress` 15、`IngressRoute` 4、`IngressRouteTCP` 1、`Middleware` 4、ACME 内蔵)と
組み込みの ServiceLB だった。forward-auth の先は oauth2-proxy + redis(IdP は Entra ID)。

前提: `Ingress` API は凍結済みで、**ingress-nginx は 2026-03-24 に retire**(read-only、CVE 修正なし)。
新規に組むなら Gateway API。F5/NGINX Inc. の `nginxinc/kubernetes-ingress` は別プロジェクトで継続中。

### 結論: Cilium(CNI + Gateway API)に寄せる

**Talos で後から替えるのが高いのは CNI だけ**なので、そこを先に決める。Ingress コントローラ・LB・証明書は
Gateway API に寄せてあれば後から差し替えられる。単一ノードのうちは Cilium は過剰に見えるが、
ハイブリッド化の見込みがあるならここで払うのが一番安い。**VM で実際に組んで動くことを確認済み**(2026-09-06)。

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

**Cilium 1.20 は Gateway API v1.6.1 の CRD を要求する**(backendtlspolicies / tlsroutes を含む)。古いと
GatewayClass が `Waiting for controller` のまま止まる。上書きは `--server-side --force-conflicts` と cilium-operator の再起動。

**ノード自身からは 80/443 に届かない。** Gateway の nodePort が L7LB リダイレクトとして載っているためで、
それが外から来る通信の経路そのものなので外せない(他のポートと、Pod からは届く)。
**`terminationGracePeriodSeconds` が長い Pod**(denpa と tuner-agent、6 時間)は Recreate と組むと入れ替わらない。`--grace-period=0 --force` で消す。

### LoadBalancer をどう置き換えるか(2026-09-06 決定・実施済み)

Talos に ServiceLB 相当は無い。**hostPort を選んだ。**

ルータの DMZ 転送先と AdGuard の split-horizon が**ノード自身の IP**(`10.0.0.2` / `10.10.0.4` / `240f:6d:842b:1::2`)に
固定されている。Cilium LB-IPAM で仮想 IP を払い出すと
**クラスタ外(ルータと DNS)の変更が必要**になり、IPv6 のプレフィックスは RA 由来で変わりうるため `externalIPs` への
固定書きも危うい。hostPort ならノードの全アドレスで受けられ、送信元 IP も保たれる。
ノードが増えたときに VIP が要るなら、そのとき LB-IPAM に移ればよい。

| 対象 | hostPort |
| --- | --- |
| Gateway(`cilium-gateway-doany`) | 80 / 443。Envoy が hostNetwork で bind するが、**実通信は nodePort の L7LB リダイレクト経由**(2026-09-08 実測。`bootstrap/cilium/values.yaml` の `nodePort`)。nodePort 80/443 は bootstrap-apply が当て直す |
| adguardhome | 53 UDP・53 TCP・853 TCP |
| matrix の LiveKit(Element Call。もとは Mattermost Calls の番号) | 8443 UDP・8443 TCP |
| 3proxy(tls-terminator サイドカー) | 3129 TCP |

**詰まった点 3 つ:**

1. **Cilium の hostPort は既定で無効。** `hostPort.enabled=true`(あわせて `nodePort.enabled` と `externalIPs.enabled`)を
   有効にしないと、Pod は Running なのにホストのポートに何も来ない。`ss` には現れない(eBPF なので)。
   確認は `cilium-dbg service list | grep HostPort`。
2. **hostPort は Pod のサンドボックス作成時に設定される。** 設定を有効にしたあと、対象の Pod を作り直す必要がある。
3. **hostPort と RollingUpdate は両立しない。** 新旧の Pod が同じホストポートを奪い合い、新しい方が Pending で止まる。
   AdGuard と 3proxy は `strategy: Recreate` にして解決した。

**Gateway はアドレスが付くまで `Programmed=False`** で、Envoy にリスナーが載らない。`gatewayAPI.hostNetwork` に
したらノードの IP がそのまま `status.addresses` に入ったので、LB-IPAM と L2 アナウンスは外した(2026-09-07)。
cert-manager の Cloudflare トークンは **cert-manager の namespace にも** Secret が要る。

### 3proxy(TLS 終端 + 素の TCP)は Cilium の Gateway では素直に移せない

Traefik では `IngressRouteTCP` が `HostSNI(px.doany.io)` で TLS を終端し、中身を素の TCP として 3proxy:3128 に流していた。
Gateway API では `protocol: TLS` + `mode: Terminate` のリスナーに TCPRoute を付ける形が同じ意味になるが、
**Cilium はそのリスナーに TLSRoute しか許さない**(仕様上は書けるが実装が無い。Envoy Gateway は実装している)。
同じ 443 に Terminate と Passthrough を同居させると **ProtocolConflict** になり、443 の `https` リスナーごと落ちた。

**採った形(2026-09-06): Gateway を使わず、Pod のサイドカーがホストのポートを直接受ける。**
3proxy の Pod に nginx(stream)のサイドカーを足し、**hostPort 3129** で TLS を終端して `127.0.0.1:3128` に渡す。
証明書は cert-manager が `px.doany.io` で発行してマウントする。クライアントは `px.doany.io:3129` に向け直した ──
SNI で振り分けるより**ポートで分ける方が構成として素直**なので本採用。

### クライアント IP(2026-09-07 確認、`Cluster` のままでよい)

Gateway の Service は `externalTrafficPolicy: Cluster`。**単一ノードでは backend が必ず同じノードに居るので
SNAT されない**。実測: denpa は公開側からだと 401・LAN からだと 200(SNAT されていれば公開側も通る)、
AdGuard の DoH のクエリログに端末のグローバル IPv6 が残る。

**ノードを足すときにやること**: `externalTrafficPolicy: Local` に変える
(Cilium の Helm 値 `gatewayAPI.externalTrafficPolicy`)。そうしないと Envoy が居ないノードに
届いたぶんが SNAT されて、AdGuard のクライアント別統計と denpa の住所判定が壊れる。
`Local` にすると Envoy の居るノードだけが応答するので、外側の振り分けもそれに合わせる。

### AdGuard の DoH は backend が HTTPS でないと出ない(2026-09-07 障害)

**切り替えの翌朝、ブラウザの名前解決が全部死んだ。** 原因は d.doany.io の backend を平文の 80 にしたこと。
AdGuard は **DoH(`/dns-query`)を HTTPS の口(443)でしか出さない**。80 は 404 を返す。
Edge の「セキュア DNS」に DoH を入れていたので、DoT と plain は生きたまま**ブラウザだけ**死ぬ、という分かりにくい形になった。
Traefik では backend にも HTTPS で繋いでいた。その置き換えを「クラスタ内なので平文でよい」と判断したのが誤り。
**DoH は平文の口には出ない。**

| 試して駄目だった案 | 結果 |
| --- | --- |
| `BackendTLSPolicy`(Gateway API 標準) | **Cilium 1.20.1 は Accepted にするだけで実装していない。** backend へ平文のまま繋ぎ、Web UI まで 400 になった |
| AdGuard の `tls.allow_unencrypted_doh: true` | **AdGuard は停止時に設定ファイルを書き直す**ので、Pod を止めずに足した値は消える |

**採った形: nginx のサイドカーを足して `/dns-query` だけをそこへ回す**(同じ Pod の `https://127.0.0.1:443` へ)。
3proxy と同じ形なので、Cilium が `BackendTLSPolicy` を実装したら両方まとめて消せる。

**教訓**: 前段の置き換えでは「同じ URL が同じものを返すか」だけでなく、**その backend が
何をポートごとに出し分けているか**を見る。HTTP のステータスだけ見ていると気付けない。

### 認証は Cilium の Gateway では賄えない(2026-09-06 調査)

**Cilium には Gateway API の OIDC が無い。** `CiliumEnvoyConfig` で Envoy の `oauth2` フィルタを書く道は未サポート
(cilium/cilium#24848、#30587)、HTTPRoute の `ExternalAuth`(GEP-1494)も未実装(cilium/cilium#45704)。
forward-auth が要るルートは **oauth2-proxy を前段のプロキシとして置く**(HTTPRoute → oauth2-proxy → アプリ)。
アプリ側(ArgoCD、denpa、NetBird など)はそれぞれ自前で OIDC を持っている。
**Entra のトークンを小さくする(グループクレーム → アプリロール)こと自体は独立して価値がある**([entra.md](entra.md))。

### Gateway の 80/443 は nodePort で開く(2026-09-06)

Gateway は Service の 80/443 を **nodePort として開く**。**Cilium は nodePort の範囲に入っている hostPort を張らない**ので
(範囲を `80-32767` に広げたら 853・8443・3proxy が一斉に落ちた)、**`nodePort.range` を `80,443` の 2 つだけに絞る**
([bootstrap/cilium/values.yaml](../bootstrap/cilium/values.yaml))。前段を入れ替えるときは、自分で配っている chart の
入口(denpa の `httpRoute`)も数えること ── gitops の `Ingress` を数えるだけでは取りこぼした。

### Traefik の sticky cookie に代替が無い(2026-09-07 調査)

**Service の sticky cookie だけは Cilium 側に受け皿が無い。** 使っていたのは tamasagashi(`ts.doany.io`)1 本で、
ローリング更新中に「HTML を新 Pod から受けたブラウザが、ハッシュ付きの CSS/JS を旧 Pod に取りに行って 404」を防ぐためのもの。

- **Gateway API の session persistence(GEP-1619)は experimental チャネル限定**で、入っている v1.6.1 standard には無い
- **Cilium 1.20.1 が未実装。** cilium/cilium#48029 で main に入ったので **1.21 から**
- **`Service.spec.sessionAffinity: ClientIP` は Gateway 経路には効かない。** Envoy が EndpointSlice を直接見て振り分け、
  送信元も全クライアント同じ(Gateway の Pod)になる

**いまは穴が開いたまま受け入れている**(replicas 1・状態なし。影響は更新中の 15 秒ほど。緩和は danything/tamasagashi の `deploy/README.md`)。
**Cilium 1.21 に上げるときに、Gateway API CRD を experimental チャネルへ入れ替えて
tamasagashi の HTTPRoute に `sessionPersistence` を足す**のが本筋(CRD は `talos/render.sh` が `standard-install.yaml` の
URL で渡しているので、そこを experimental に替える)。
**将来どれかのアプリを複数 replica にするなら、1.21 未満のあいだは Gateway 越しのセッション固定が無いことを先に確認すること。**

### 却下した案

| 案 | 理由 |
| --- | --- |
| Traefik 継続 | 書き換えは 0 で済むが、Traefik 固有 CRD への依存が続き、ハイブリッド化したときに移植性が無い。Talos では ServiceLB が無いので結局 MetalLB を足すことになり、部品は減らない |
| Envoy Gateway | Gateway API の機能は最も揃うが、単一ノードでは MetalLB と cert-manager を連れてきて部品が増える。内蔵 OIDC は Cookie 4096 バイトの制約(#7315)で当てにできず、主要な動機が消える。マイナーが 2 週間強に 1 回でバージョンマトリクスが重い |
| ingress-nginx | EOL |
| HAProxy / Kong / Istio | 単一ノードに過剰、または Gateway API 対応で劣る |

将来 Envoy Gateway を選ぶなら、OIDC はトークンを Cookie に保存するので次の既知の問題を先に見る:

| Issue | 内容 |
| --- | --- |
| envoyproxy/gateway#7315 | トークンが **4096 文字を超えるとブラウザが Cookie をセットせず**、認証がループする。**Envoy 側にエラーログが出ない** |
| envoyproxy/gateway#8441 | OIDC Discovery が失敗すると毎リクエスト token introspection にフォールバック。IdP 停止時に白画面 |
| envoyproxy/gateway#8649 | Gateway レベルとルートレベルで SecurityPolicy を二重掛けすると CSRF 検証で落ちる |

## chart を配るときと、chart で入れるとき(2026-09-07)

**「HelmChart」は 2 つの別物を指す。** ここを混ぜると話が噛み合わない。

| | 何か | この構成での扱い |
| --- | --- | --- |
| `HelmChart` CRD(`helm.cattle.io/v1`) | helm-controller が CR を見て helm を Job で走らせる入れ方 | **やめた**。ArgoCD と二重管理になる(差分も同期状態も prune も ArgoCD から見えない)うえ、Talos に無い。argocd と infisical の CR は `render.sh` が chart・版・値を読む入れ物として残っているだけ |
| Helm chart そのもの | **配る形**。`Chart.yaml` + `templates/` を OCI で push する | **続ける**。denpa と yosegaki は今も配っている |

### 配る chart で気を付けること

**実際に踏んだものだけ**を挙げる(例の erpnext は 2026-10-06 に撤去したが、教訓は残す)。自分の chart(denpa / yosegaki)は
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

**chart を別のリリース名で入れ直すと別物として作り直しになる**(`secrets-operator` のように名前を切り詰める chart がある)。
入れ方を替えるときは `helm template` の出力と live を先に突き合わせる。

### infisical だけは ArgoCD に移せない(2026-09-08、chart を読んで確定)

**理由は鶏卵ではない。** ArgoCD は Infisical が無くても起動する(Secret が無いと SSO が
効かないだけ)ので、そこは問題にならなかった。**駄目なのは chart の作り。**

`infisical-standalone` 1.10.0 は接続文字列を **Deployment の平文 env に焼き込む**:

```
DB_CONNECTION_URI  postgresql://infisical:<パスワード>@postgresql:5432/infisicalDB
REDIS_URL          redis://default:<パスワード>@redis-master:6379
```

`templates/_helpers.tpl` が `.Values.postgresql.auth.password` と
`.Values.redis.auth.password` をそのまま `printf` している。**ArgoCD の Application は
平文なので、ここに値を書くことはできない。**

**逃げ道は片方にしか無い。** `postgresql.useExistingPostgresSecret` はあるが、

- `postgresql.enabled: true` と併用すると `DB_CONNECTION_URI` が **2 回描き出される**
  (kubelet は後ろ勝ちなので平文の方が勝つ)。使うなら同梱の Postgres を切って
  自前で建てることになる
- **Redis には逃げ道が無い。** `redisConnectionString` は `.Values.redis.auth.password` を
  直接埋めるだけで、Secret を指す分岐が無い

`postgresql.auth.existingSecret` / `redis.auth.existingSecret` は **subchart(bitnami)には
効くが、infisical 本体の env には効かない** ── 指定すると本体側は chart の既定値
(`root` / `mysecretpassword`)で URI を組み立て、**自分のデータベースに繋げなくなる。**
実際に `helm template` して確認した。

**なので `bootstrap/` に残す。** ArgoCD 本体と同じく machine config の
`inlineManifests` に載せる ── [talos/render.sh](../talos/render.sh) は age の鍵を持っている
ので、SOPS 済みの値を復号して `helm template` に渡せる。**生成物は machine config の中に
しか出ないので、git には平文が残らない。**

## ghcr の pull 認証

もとは名前空間ごとに `ghcr-pull` を `imagePullSecrets` で参照していた。2026-09-06 にノード単位の資格情報へ寄せ、
**2026-09-15 からは ghcr.io の資格情報そのものが要らない** ── 非公開のリポジトリを Forgejo に移し(apps/forgejo/README.md)、
ghcr.io に残るイメージは全部公開。**ノード単位で持つのは fj.doany.io の資格情報だけ**(`talos/registries.yaml`、[talos/README.md](../talos/README.md))。

## PT3 チューナー(Talos で動かすための算段)

実機には Earthsoft PT3(`earth_pt3`、Altera 1172:4c15)が刺さっていて、Talos のカーネルは `CONFIG_DVB_PT3` を
有効にしておらず、公式 extension にも無かった。denpa の tuner-agent はこの箱の `/dev/dvb` と B-CAS リーダーに依存している。

**結論(2026-10-13): 上流に入った。** [siderolabs/pkgs#1682](https://github.com/siderolabs/pkgs/pull/1682)
(`CONFIG_DVB_PT3=m`)が v1.15.0-alpha.1 に入り、`siderolabs/dvb-pt3` が Image Factory の公式 extension に出た。
本番の schematic を `96371c8f…`(dvb-pt3 + intel-ucode + IOMMU の引数)に作り直し、Talos を v1.15.0-alpha.1 に上げた
(`talos/versions.yaml`)。extension は `earth_pt3` を blacklist して配るので、`talos/patches/main.yaml` の
`machine.kernel.modules` で読ませる。alpha をノード 1 台の本番に乗せることになるが、正式版を待つより PT3 を先に取った。

**駄目だったときの保険: KubeVirt の VM にパススルー。** 実機で確認済み — VT-d 有効、PT3(05:00.0)は
**IOMMU グループ 36 に単独**、B-CAS は USB(Gemalto GemPC Twin 08e6:3437)。tuner-agent だけ VM(Ubuntu)で動かせば
Talos 本体は素のまま。`intel_iommu=on` は schematic に残してあるが、vfio は 2026-10-13 に
`talos/patches/main.yaml` から外した(PT3 をホストのドライバと取り合う)ので、この道に戻るなら足し直す。

**自前 extension を `imager` で焼く案は採らない。** Image Factory から外れて、アップグレードのたびに自前ビルドになる。

## 依存の更新をどこまで自動で入れるか(2026-09-07)

Renovate は共有プリセット(`5ym/repo-config`。2026-10-07 に `5ym/renovate` から改名)を使っていて、**全部を 1 つの PR にまとめて自動マージ**する
設定だった。`separateMajorMinor: false` も付いていたので、**postgres 17 → 18 が nginx のパッチと
同じ PR に入り、自動マージの対象になっていた**(danything/gitops#7)。

**直したこと**: プリセット側でメジャーを別の PR に分け、`automerge: false` にした(5ym/repo-config#2)。
パッチとマイナーはこれまでどおり 1 つにまとめて自動マージする。小さくて頻繁で、タグを戻せば済むため。

**SOPS で暗号化したファイルは Renovate に触らせない**(2026-09-08)。argo-cd 10.8.2 の PR が暗号文の中の `version: 10.8.1` を
平文置換して自動マージされ、MAC が壊れて `sops -d` が通らなくなった(コミットから戻した)。`renovate.json` の `ignorePaths` で外し、
その 2 ファイルの版は人が見る([../bootstrap/README.md](../bootstrap/README.md))。

Renovate 自体は **2026-10-16 から k8s の CronJob([apps/renovate/](../apps/renovate/))で動かしている**
(GitHub Actions の workflow と Forgejo Actions の `doa/renovate` は 2026-10-17 に削除)。

いまの自動マージの範囲(プリセット `5ym/repo-config`):

| まとまり | 自動マージ |
| --- | --- |
| `all dependencies`(メジャー以外の全部) | する |
| `major dependencies` | しない |
| `helm charts`(更新の種類を問わない) | しない |

**PostgreSQL は 17 の線に固定した**(`renovate.json` の `allowedVersions: "<18"`)。
**PostgreSQL はメジャーが変わるとデータディレクトリの互換が切れる。**
イメージのタグを差し替えると `database files are incompatible with server` で起動を拒否し、上げるには
dump と restore が要る。17 のサポートは 2029-11 まであるので急がない。

### メジャーを分けるだけでは足りない(2026-09-07 実例)

プリセットを直した直後、Renovate は erpnext の chart 8.0.15 → 8.0.78 を自動マージした。版の付け方はパッチだが、
中身は Dragonfly → Valkey の入れ替えで、values に書いてあったチューニングが丸ごと無効になった。

**版の番号は中身の大きさを表さない。** chart の場合はとくにそうで、自動マージに任せる範囲を
決めるときは「メジャーかどうか」だけでは足りない。

**そこでプリセット側で `helm` の datasource を丸ごと自動マージから外した**
(5ym/repo-config#3)。chart は更新の種類を問わず人が見る。`helm charts` という別の
グループにしてあるのは、chart を止めることで `all dependencies` の PR まで自動マージ
されなくなるのを避けるため。

## PVC を守る仕掛けをやめた(2026-09-07)

**「git で消したものは消える」を優先する**、という判断(本人)。それまでは二重に守っていた。

| 仕掛け | やめた理由 |
| --- | --- |
| PVC の `argocd.argoproj.io/sync-options: Prune=false,Delete=false` | **これが本丸。** これがある限り git から消しても PVC は残る。GitOps の一貫性を損なう |
| StorageClass `local-path-retain`(`reclaimPolicy: Retain`) | **追われない状態を作る。** 実際、35 日と 44 日放置された Released の PV が 3 本あった(2026-09-07 の掃除で発見) |

**代わりの後ろ盾はバックアップ。** 日次の restic(R2)に加えて、DB は k8up が論理バックアップを取る。
誤って消したときの最大損失は 24 時間ぶん。**この判断は復元リハーサルが通ってから**行った
(通らなければ守りを外す根拠が無かった。2026-10-17 には実際にこれで全部戻した)。

**承知しておくこと**: `Delete=false` も外したので、**Argo CD の Application を消すと PVC も消える**。
マニフェストを消すのは git のレビューを通るが、Application の削除は UI のボタン 1 つで済む。
そこの重みは違う、という点は残る。

**`storageClassName` はバインド済み PVC では変更も削除もできない**(API が拒否する)。変えるときは PVC を止め、
PV を `Retain` にして古い PVC を消し、PV の `claimRef` を外して書き換え、新しい PVC を `volumeName` で同じ PV に結ぶ
(2026-10-05 に 28 本をこれで `local-path` に付け替えた。データはコピーしていない)。

## バックアップに何を含めるか

R2 の無料枠は 10 GB。**もう超えている。**

| 日付 | リポジトリの実サイズ | できごと |
| --- | --- | --- |
| 2026-09-06 | 3.3 GiB | |
| 2026-10-05 | **37.3 GiB** | 途中 88.6 GiB まで育った(下)。録画はエンコード済みの 1 世代(約 35 GiB)だけにした |

**決定(2026-09-08): 有料でも取る。** 無料枠に収めることを目的にすると録画を捨てることになり、
本末転倒。R2 は下り(egress)が無料なので、復元のたびに費用が跳ねる心配も無い。
**無料枠は制約ではなく目安**として扱う。容量そのものが問題になるのは、桁が変わったとき(数百 GB)。

**前のホストのスクリプト(`host=main`)が全部を二重に持っている(2026-09-10 に気づいた)。**
PV の置き場を丸ごと取っていたので、**k8up が PVC ごとに取っているものと同じ中身**が入っている。
restic は重複を除くので容量は二重にならないが、**片方で世代を減らしてももう片方が同じ blob を掴んでいるので解放されない**
(`denpa-library` を 3 世代 → 1 世代にしても解放されたのは 36 MiB だけ。`restic stats --mode raw-data <snapshot>` は
「そのスナップショットが参照する量」で「そのスナップショットだけが持つ量」ではない)。
**per-PVC の保持設計は `host=main` を消すまで効かない。** 保持を回していたのはスクリプト自身なので、
いまは誰も forget しない(消すかどうかは [../ROADMAP.md](../ROADMAP.md) の Phase 3)。

**料金**: R2 のストレージは**期間中の日次ピークの平均(GB-month)**で課金され、無料枠は 10 GB-month。
いまの規模で月 $0.4 前後(2026-09-10 の見積もり)。操作の回数は桁違いに余っている。

容量を削るために外した / 外さなかったもの:

| 対象 | 判断 |
| --- | --- |
| AdGuard のクエリログ(`querylog.json`) | **保持を 90d → 7d に短縮**(2026-09-06)。単体で 2.0 GB あった。純粋な計測データで、復元時に無くても困らない。いま 8.8 MB |
| 録画データ | **エンコード済み(`denpa-encoded`、旧 `denpa-library`)だけを含める。** 放送は取り直せないので容量より価値を優先する(2026-09-06 本人判断)。ただし**世代は持たない**(2026-09-10、[../apps/k8up/denpa-encoded-forget.yaml](../apps/k8up/denpa-encoded-forget.yaml))── 中身が入れ替わるので、古い世代が消えたファイルを抱え続ける。**2026-10-05 に前のホストのスクリプトからも外した** ── 世代を持つ側が録画を掴んでいて、ライブラリ 39.66 GiB がリポジトリを 90 GiB まで押し上げていた。過去 10 本からも `restic rewrite` で抜いた |
| `denpa-recorded`(生 TS の作業領域) | **除外した(2026-09-07)。** 1.6 GB だったものが **14 GB** まで育ち、リポジトリ実サイズが 13.92 GiB と **R2 の無料枠 10 GB を超えていた**。エンコードが終われば消える置き場で、中身は数時間で入れ替わるので日次のスナップショットに残す意味も薄い |
| 保持世代 | 17 → **13**(`--keep-daily 7 --keep-weekly 4 --keep-monthly 2`)。遡れる範囲は約 2 か月 |
| 消した namespace の PV(epg / vpn / opengist、541 MiB) | 退避のうえ削除済み。バックアップ対象外 |

## VPN を wg-easy から NetBird にした(2026-09-07)

wg-easy を使う理由は **プライバシー(全部を自宅経由にする)・DNS(AdGuard)・iLO(10.0.0.3)に入る**の 3 つだけで、
どれも「自宅の LAN に入れれば済む」もの。UI に不満はあったが、**スマホを足すときの QR は実際よく使う**ので
UI を捨てる方向は取らなかった。

| | 結論 |
| --- | --- |
| **wg-easy 続投** | 動いてはいる。ただし自前の認証を切れず(要望 [wg-easy#1923](https://github.com/wg-easy/wg-easy/issues/1923) が 2025-06 から open)、SSO の後ろに置いても**二重ログイン**が残る |
| **wg-portal** | 機能は足りる。ただし乗り換える動機が wg-easy 比で薄い |
| **Headscale** | 完成度は高い。**が、FAQ が「headscale を動かすマシンをサブネットルータにするな」と明記している。** ノードが 1 台のこの構成では回避できない |
| **NetBird** | **採用。** routing peer が独立した概念で、コンテナで動かす前提のドキュメントがある。1 台構成でも上の問題が起きない |

**公式 Helm chart は使わない。** [netbirdio/helms](https://github.com/netbirdio/helms) の `charts/netbird` は
更新が止まっていて appVersion が本体から大きく遅れている([#39](https://github.com/netbirdio/helms/issues/39))。
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
ArgoCD は `sourcePath` 配下を `recurse` で拾い、追跡は `argocd.argoproj.io/tracking-id` 注釈で行うので、
**ファイルの場所は挙動に影響しない**。純粋に読み手の都合。

| 行き先 | 対象 |
| --- | --- |
| このリポジトリの `apps/<name>/httproute.yaml` | adguardhome / forgejo / headlamp / infisical / matrix / mta-sts / netbird / rybbit など |
| 各アプリのリポジトリの `deploy/httproute.yaml` | blog / yosegaki / lgtm / tamasagashi / worklog / xool / yuzuriha |
| `bootstrap/` | argocd / auth ×3 / redirect-https |

**`bootstrap/` に移したものが本題。** `argocd` と `auth` の実体はこの層にあり、**ここは ArgoCD が
同期していない**。つまり「ArgoCD が ArgoCD 自身を公開している経路を握っている」状態で、
ArgoCD が壊れているときにその経路を ArgoCD 経由でしか直せない、という順序の逆転があった。

**まとめて 1 か所に置く利点(公開しているものの一覧になる)は失う。** 代わりに
この表と `bootstrap/README.md` が索引。外部露出を一覧したいときは `kubectl get httproute,grpcroute -A` が
正確で、git を読むより早い(一覧の一枚は作らない、2026-09-09)。

**落とさずに動かす**: ArgoCD は「git から消えた + 自分が追跡している」ものを prune する。別リポジトリへは
移送先を**先に**マージして tracking-id が書き換わってから元を消す。`bootstrap/` へは引き取り手が居ないので、
先に live に `Prune=false` を効かせてから移し、tracking-id 注釈を剥がして `Prune=false` も外す。

## DNS:直接つなぐアプリと Cloudflare を通すアプリを分ける(2026-10-06)

**社内用や通信量が多いアプリは直接つなぐ。SaaS のように外へ出すアプリは Cloudflare のプロキシを通す**(本人)。

- 直接つなぐもの:`*.doany.io` のワイルドカード(proxied ではない CNAME → `doany.io`)で引ける。明示のレコードは持たない
- Cloudflare を通すもの:アプリのリポジトリの HTTPRoute に `external-dns.kubernetes.io/cloudflare-proxied: "true"` を付け、
  **ExternalDNS**(`apps/external-dns/`)が proxied の CNAME を作る

**DNS もアプリのリポジトリで持つ(疎結合)。** それまでは Cloudflare を通すアプリの CNAME(`l`・`tk`・`ts`・`w`・`x`・`y`)を
手で作っていた。中央の IaC(Pulumi・DNSControl・OctoDNS)に一覧を置く案もあったが、アプリを足すたびに gitops と
アプリのリポジトリの 2 か所を直すことになる。ExternalDNS は HTTPRoute の注釈だけで決まり、自分が作ったレコード
(所有の印の TXT 付き)にしか触れないので、メールや DDNS の apex と同居できる。

比べたもの:ExternalDNS / DNSControl / OctoDNS / Cloudflare の Terraform provider / cloudflare-operator / k8s_gateway /
Crossplane。疎結合にできるのは ExternalDNS・cloudflare-operator・Crossplane だけで、その中で DNS が主役で利用者が多いのは ExternalDNS。

**Entra のリダイレクト URI は中央(`pulumi/entra.ts`)のまま。** 共用のアプリ登録 1 つに全アプリの URI が入るので、
そもそも中央に集まる性質のもの。アプリごとに分けるにはアプリ登録を分ける必要があり、それを Kubernetes から作る
手軽な道具がまだ無い。
