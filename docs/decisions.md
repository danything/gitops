# 決定の記録

なぜこの技術・この形を選んだかをここに置く。手順と進捗は [`../ROADMAP.md`](../ROADMAP.md)。

## 層ごとに戻し方を分ける

ノードにシェルが無いので、「k8s オブジェクト」は **git から ArgoCD で再構築**(etcd スナップショットは近道)、
「ホスト設定」は machine config(git 管理)、「PV データ」だけがバックアップツールの仕事になる
(手順は [../recovery/README.md](../recovery/README.md))。**ツール選定は PV データの部分にしか効かない。**

変えないと決めてあるもの: restic のリポジトリ形式・パスフレーズ・バケット、local-path の PV ディレクトリ構造
(`pvc-<uid>_<ns>_<name>`)、Infisical のデータと `ENCRYPTION_KEY`、ArgoCD + ApplicationSet + 各 repo の `deploy/argocd.yaml`、
**復元手順は公開で秘密を含まない**という性質。

## Z440 へは Talos のまま移す

OS の入れ替えは **iLO で画面まで見える DL360** で済ませた。Z440 の遠隔管理は AMT 9.x(電源と SOL だけ)なので、
箱の違いは schematic と NIC の名前に閉じ込める([z440-migration.md](z440-migration.md))。

## bond0 の MAC を固定する

ルーターの IPv6 ホスト公開が **bond0 の MAC で指している**ので、`BondConfig` の `hardwareAddr` で固定した
([router.md](router.md)「IPv6 はノードだけを公開する」)。

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
k8up の取ったスナップショットも手元の restic CLI で読める(Infisical はそうやって戻す)。

リモートは Cloudflare R2 のバケット `doany-restic`(APAC、Standard)。API トークンは
Object Read & Write をこのバケットだけに絞った Account API token。下り(egress)が無料なので復元で費用が跳ねない。

### 手で持つもの(根っこ)

**手で持つのは age のパスフレーズ 1 つだけ。** 他は全部、そのパスフレーズから辿れるところに置いてある。

| | 置き場 | 開け方 |
| --- | --- | --- |
| R2 の鍵 + restic のパスフレーズ | `recovery/env.age`(公開 repo) | **パスフレーズで直接**(`age -d`) |
| SOPS の age 秘密鍵 | `recovery/sops-age.key.age`(公開 repo) | **パスフレーズで直接**(`age -d`) |
| Talos の `secrets.yaml` | `talos/secrets.yaml`(公開 repo・SOPS 済み) | 上の age 鍵で(`sops -d`) |
| `bootstrap/` の Secret 4 つ | 公開 repo・SOPS 済み | 同上 |

**`recovery/` の 2 つだけ `age -p` なのは、それが「まだ何も無い状態で最初に開けるもの」だから。**
それ以外は age 鍵さえ手に入れば開くので、`bootstrap/` と同じ SOPS に揃えてある。

**`talosconfig` は保存しない。** `secrets.yaml` から `talosctl gen config` で毎回出てくる派生物で、
TTL も付いている。使い捨てにするほうが安全(../talos/README.md)。

R2 の鍵を GitHub の秘密(gist・Actions)に置かないのは、GitHub のトークンがあちこちに散っているため。
GitHub 側が丸ごと漏れても、バックアップ(を消せる鍵)だけは無事な状態を残す。

### そのパスフレーズをどこに置くか

**公開 repo に暗号文が載っている以上、オフラインで無限に総当たりされる。強度がすべて**なので
diceware 6〜7 語相当を使う。**同期ストレージ(OneDrive など)を正本にしない** ──
復元のときに Microsoft アカウントと MFA デバイスが要るようになり、「`curl` 1 本とパスフレーズだけ」が崩れる。

| | 何を置くか | 理由 |
| --- | --- | --- |
| **パスワードマネージャ**(正本) | パスフレーズ + **何を開ける鍵かと復元手順の URL** | 携帯から取れる。**クラスタの Entra とは独立した認証**であること(Infisical は循環するので不可) |
| **紙、2 か所**(1 つは家の外) | 同上 + `recovery/*.age` を base64 で印刷(19 行) | 火事・盗難・端末紛失、GitHub が読めない場合に耐える |
| **記憶** | パスフレーズ | 出先で全部が閉じている状況を消す。ただし単独では信用しない |

**暗号文の副本は OneDrive の Personal Vault でよい**(公開 repo にあるものなので機密性は要らない)。
**ただしパスフレーズは同じ場所に入れない** ── Microsoft アカウント 1 つで全部になる。

見送ったもの: **暗号文を公開 repo から外す**(`curl` 1 本で始められる軽さを失う。diceware 6〜7 語なら総当たりは成立しない)、
**YubiKey で SOPS の鍵をハードウェアに置く**(効くのは「復号のたびに秘密が手元の PC に載る」ほう。YubiKey 2 本と
復旧時の `pcscd` が増える。入れるなら SOPS の鍵だけで、`recovery/env.age` は軽いまま残す)。

## DB の整合性の取り方

**scale down しない。** k8up の `k8up.io/backupcommand` で論理バックアップを取る
(RDBMS は `pg_dump`、SQLite は `bun:sqlite` の `serialize()`、ファイルの PVC は注釈)。**どれが何で取れているかの一覧は
[../apps/k8up/README.md](../apps/k8up/README.md)** ── ここには写さない(二重に持つと片方が腐る)。

## Talos の起動順序をどう組むか

Talos には helm-controller が無く、inlineManifests は Helm を実行できないので、手元の `render.sh` が `helm template` して載せる。
**ArgoCD は Infisical 無しで起動する。** `$argocd-oidc:client-secret` のような参照は Secret が無いと警告して文字列のまま返す
(`util/settings/settings.go`)ので、SSO が効かないだけで同期は動く。順序は
**Cilium → ArgoCD → ArgoCD が Infisical を入れる → operator が Secret を作る → SSO が効く**。
その窓の間は `admin.enabled: false` なので UI に誰も入れない(要るなら一時的に戻す。`kubectl` で見る)。

### 層の分け方

| 層 | 中身 | 資格情報 |
| --- | --- | --- |
| **machine config** | **`bootstrap/` のほぼ全部。** inline が 8 つ(cilium / local-path / `apiserver/rbac.yaml` / argocd / cert-manager / infisical / SOPS の Secret 2 つ)、CRD だけ URL で 5 つ(gateway-api / argocd ×3 / cert-manager) | 入力(`talos/secrets.yaml` など)が SOPS 済みで、生成物は git に置かない |
| **ArgoCD** | `bootstrap/` の残り(`ClusterIssuer`・Gateway・auth・`InfisicalSecret` など、平文のもの。Application `bootstrap`)と `apps/`(**infisical は来ない**。下の「infisical だけは ArgoCD に移せない」) | — |

- **CRD だけ URL で渡すのは大きさの都合。** 埋めると machine config が 341 KB → 4 MB を超える。
  `KubeExternalManifestConfig` は Talos がそのために用意している入口([talos/render.sh](../talos/render.sh))
- **平文の残りは ArgoCD。** 鶏と卵にならない ──
  ArgoCD が動くのに要るもの(本体・repo の資格情報・入口の `apps`)は全部 machine config にあり、この層に頼っていない。
  この層が要る CRD も machine config が入れる(`InfisicalSecret` の CRD だけ `apps/` から来るので、最初の何回かは retry)。
- **SOPS の Secret を machine config に入れる。** 復号鍵はクラスタにも CI にも渡さないので、ArgoCD からは当てられない。
  machine config の入力(`talos/secrets.yaml`)もクラスタ CA の秘密鍵を含む SOPS なので信頼水準は変わらず、起動時点で存在する
- **Helm を実行する場所はクラスタの外(手元の生成時)だけ。** Cilium は CNI なので inlineManifests 以外に置きようがなく、
  ArgoCD も同じ扱いにすればクラスタ内に Helm コントローラを持たなくて済む。版の追従は Renovate

## machine config と Cilium の chart をどう連動させるか

**machine config を「派生物」にする。** `helm template` の出力を `KubeInlineManifestConfig` に包んで `--config-patch` として渡す
([talos/render.sh](../talos/render.sh))ので、Cilium の値がリポジトリに二度書かれない。Renovate は
`bootstrap/cilium/version.yaml` を見ていて、machine config は毎回そこから描き直されるだけ。

**`helm upgrade` は使わない。** 更新経路は「`values.yaml` を直す → 描き直す → `upgrade-k8s`」。古い machine config のまま
`upgrade-k8s` を流すと走っている Cilium が巻き戻る([../talos/README.md](../talos/README.md)「上げ方 / 当て直し方」)。
流し忘れは [cilium-drift.yml](../.github/workflows/cilium-drift.yml) が週次で live と突き合わせる。
bootstrap のあとに `helm install` する案は、再構築のたびに「CNI が無いので何も動かない」状態での手作業が増えるので採らない。

**描いた結果はコミットしない。** 描き出しを git に置いて Renovate に描き直させる案は採らない:
- **infisical の描き出しは秘密を含む**(下の「infisical だけは ArgoCD に移せない」)。ここだけは手元で描くしかなく、描く道具は結局残る
- 描き出しは machine config で 980 行・310 KB(1 行が長い)。版を上げるたびにその差分が積もる
- 代わりに **描くたびに変わる値を潰した**(Hubble の証明書・infisical の `postgres-password`・`updatedAt`)。
  同じ入力なら生成物はバイト単位で同じなので、`apply-config --dry-run` の差分がそのまま「何が変わるか」になる

**起動に要らないものは ArgoCD に置く**(metrics-server は `apps/cluster/metrics-server.yaml`。版上げが `upgrade-k8s` 無しで済む)。cert-manager は移さない ── CRD を machine config から外すと Talos の prune が CRD を消しうる(消えれば
全 namespace の Certificate が道連れ)。

## ルーティングの選定

**Cilium(CNI + Gateway API)に寄せる。** `Ingress` API は凍結済みで ingress-nginx は retire。
**Talos で後から替えるのが高いのは CNI だけ**なので先に決め、Ingress・LB・証明書は Gateway API に寄せて後から差し替えられるようにした。

| | 選択 |
| --- | --- |
| CNI | Cilium |
| kube-proxy | Cilium の kubeProxyReplacement |
| LoadBalancer | 使わない(hostPort と Gateway の hostNetwork。下記) |
| Ingress | Cilium Gateway(Gateway API) |
| 証明書 | cert-manager(Cloudflare DNS-01) |
| 認証 | oauth2-proxy を前段のプロキシに(下記) |

- **Cilium 1.20 は Gateway API v1.6.1 の CRD を要求する。** 古いと GatewayClass が `Waiting for controller` のまま止まる
- **`terminationGracePeriodSeconds` が長い Pod**(denpa と tuner-agent、6 時間)は Recreate と組むと入れ替わらない。`--grace-period=0 --force` で消す

### LoadBalancer をどう置き換えるか

**hostPort を選んだ。** ルータの DMZ 転送先と AdGuard の split-horizon が**ノード自身の IP**(`10.0.0.2` / `10.10.0.4` /
`240f:6d:842b:1::2`)に固定されていて、LB-IPAM の仮想 IP だとクラスタ外の変更が要り、IPv6 のプレフィックスは RA 由来で変わりうる。
hostPort ならノードの全アドレスで受けられ、送信元 IP も保たれる。ノードが増えて VIP が要るなら、そのとき LB-IPAM に移る。

| 対象 | hostPort |
| --- | --- |
| Gateway(`cilium-gateway-doany`) | 80 / 443。Envoy が hostNetwork で bind し、外からの通信はそこに直接届く。Service の nodePort はランダムなままでよい(`bootstrap/cilium/values.yaml` の `nodePort`) |
| adguardhome | 53 UDP・53 TCP・853 TCP |
| matrix の LiveKit | 8443 UDP・8443 TCP |
| 3proxy(tls-terminator サイドカー) | 3129 TCP |

- **Cilium の hostPort は既定で無効**(`hostPort.enabled`)。有効にしたら対象の Pod を作り直す(サンドボックス作成時に設定される)。
  `ss` には出ないので確認は `cilium-dbg service list | grep HostPort`
- **hostPort と RollingUpdate は両立しない**(新しい Pod が Pending で止まる)。AdGuard と 3proxy は `strategy: Recreate`
- **Gateway はアドレスが付くまで `Programmed=False`。** `gatewayAPI.hostNetwork` でノードの IP が `status.addresses` に入る
- **`nodePort.range` を広げない(既定の 30000-32767)。** Cilium は nodePort の範囲に入る hostPort を張らない(`80-32767` にしたら 853・8443・3129 が一斉に落ちた)。
  前段を入れ替えるときは、自分で配っている chart の入口(denpa の `httpRoute`)も数えること

### 3proxy と AdGuard の DoH はサイドカーで TLS を終端する

- **3proxy**(TLS 終端 + 素の TCP): Cilium は `mode: Terminate` のリスナーに TLSRoute しか許さず、同じ 443 に Terminate と Passthrough を
  同居させると ProtocolConflict で 443 ごと落ちる。nginx(stream)のサイドカーが **hostPort 3129** で終端して `127.0.0.1:3128` に渡す
- **AdGuard の DoH**: AdGuard は `/dns-query` を HTTPS の口(443)でしか出さない(平文の 80 は 404)。
  `BackendTLSPolicy` は Cilium 1.20.1 が Accepted にするだけで実装していない。nginx のサイドカーが `/dns-query` だけを
  `https://127.0.0.1:443` へ回す。Cilium が `BackendTLSPolicy` を実装したら両方まとめて消せる

### クライアント IP(`Cluster` のままでよい)

Gateway の Service は `externalTrafficPolicy: Cluster`。**単一ノードでは backend が必ず同じノードに居るので SNAT されない**
(denpa は公開側から 401・LAN から 200、AdGuard の DoH のログに端末の IPv6 が残る)。
**ノードを足すときは `Local` に変える**(Cilium の Helm 値 `gatewayAPI.externalTrafficPolicy`)。そうしないと AdGuard のクライアント別統計と
denpa の住所判定が壊れる。`Local` は Envoy の居るノードだけが応答するので、外側の振り分けもそれに合わせる。

### 認証は Cilium の Gateway では賄えない

Cilium には Gateway API の OIDC も ext auth も無い(cilium/cilium#24848・#30587、`ExternalAuth` は #45704)。
forward-auth が要るルートは **oauth2-proxy を前段のプロキシとして置く**(HTTPRoute → oauth2-proxy → アプリ)。
Entra のトークンは大きく(セッション実測 4293 バイト)、Cookie に載せる方式(Envoy Gateway の内蔵 OIDC など)は 4096 バイトの壁に当たる。
アプリ側(ArgoCD、denpa、NetBird など)はそれぞれ自前で OIDC を持つ([entra.md](entra.md))。

### sticky cookie は Cilium 1.21 待ち

Gateway に sticky cookie が無い(要るのは tamasagashi 1 本。更新中に HTML と CSS/JS が別の Pod から返る 404 を防ぐため)。
Gateway API の session persistence は experimental チャネル限定、Cilium は 1.21 から(cilium/cilium#48029)、
`sessionAffinity: ClientIP` は Gateway 経路に効かない。いまは replicas 1 で穴を受け入れている。
**1.21 に上げるときに Gateway API CRD を experimental に替え(`talos/render.sh` の URL)、tamasagashi の HTTPRoute に `sessionPersistence` を足す。**
それまでにアプリを複数 replica にするなら、セッション固定が無いことを先に確かめる。

## chart を配るときと、chart で入れるとき

**Helm chart を配る(OCI で push する)**のは denpa と yosegaki。入れ方は利用者に選ばせる(`helm install` でも `Application` でも同じものが入るのが正しい)。このクラスタは ArgoCD の `Application` に統一した。

配る chart でやらないこと(踏んだもの。自分の chart はどれも該当しない):

- リソース名に時刻や乱数を入れない(GitOps は同期のたびに別物として作り直す)
- CRD は `templates/` ではなく `crds/` に置く(`templates/` だとアンインストールで CR が全部巻き添えになる)
- 全ワークロードに `podAnnotations` と `resources` を出す(注釈は k8up・Infisical・ArgoCD が振る舞いを足す口)
- patch で中身を入れ替えない(chart の patch 更新で Dragonfly が Valkey に替わり、values のチューニングが黙って無効になった)
- 入口(`Ingress` / `httpRoute`)を既定で作らない

**別のリリース名で入れ直すと別物として作り直しになる**(名前を切り詰める chart がある)。入れ方を替えるときは `helm template` と live を先に突き合わせる。

### infisical だけは ArgoCD に移せない

**理由は鶏卵ではなく chart の作り。** `infisical-standalone` 1.10.0 は `DB_CONNECTION_URI` と `REDIS_URL` を
`.Values.*.auth.password` から **Deployment の平文 env に焼き込む**(`templates/_helpers.tpl`)ので、平文の Application に値を書けない。
`postgresql.useExistingPostgresSecret` は同梱の Postgres と併用すると URI が 2 回描かれて平文が勝ち、Redis には逃げ道が無い。
`*.auth.existingSecret` は subchart にしか効かず、本体は既定値で URI を組んで繋がらなくなる(`helm template` で確認)。
**なので `bootstrap/` に残し、machine config の `inlineManifests` に載せる。** `render.sh` が SOPS 済みの値を復号して `helm template` に渡すので、
平文は machine config の中にしか出ない。

## PT3 チューナー

denpa の tuner-agent は Earthsoft PT3(`earth_pt3`)の `/dev/dvb` と B-CAS リーダーに依存している。
**公式 extension `siderolabs/dvb-pt3` を使う**([siderolabs/pkgs#1682](https://github.com/siderolabs/pkgs/pull/1682))。
v1.15.0-alpha.1 からしか無いので、**正式版を待つより PT3 を先に取り、本番を alpha に乗せている**。
extension は `earth_pt3` を blacklist して配るので、`talos/controlplane.yaml` の `machine.kernel.modules` で読ませる。
復調とチューナーのモジュールは、v1.15.0-alpha.2 から Talos がカーネルの要求(`request_module`)で読む([siderolabs/talos#14724](https://github.com/siderolabs/talos/pull/14724))。
それまでは 3 つも並べて書き、起動後に PT3 を付け直す DaemonSet(pt3-rebind)で順番の問題を避けていた。

**駄目だったときの保険: KubeVirt の VM にパススルー。** PT3(05:00.0)は IOMMU グループ 36 に単独、B-CAS は USB(GemPC Twin 08e6:3437)。
`intel_iommu=on` は schematic に残してあるが、vfio は `talos/controlplane.yaml` から外した(PT3 をホストのドライバと取り合う)ので、戻るなら足し直す。
**自前 extension を `imager` で焼く案は採らない**(アップグレードのたびに自前ビルドになる)。

## 依存の更新をどこまで自動で入れるか

共有プリセット `5ym/repo-config` で、**パッチとマイナーは 1 つの PR にまとめて自動マージ、メジャーと Helm chart は人が見る**
(chart はパッチ更新でも中身が入れ替わることがある)。
PostgreSQL は 17 の線に固定(メジャーでデータディレクトリの互換が切れ、dump / restore が要る)、argo-cd と infisical-standalone の chart は自動マージしない。
理由はそれぞれ [../renovate.json](../renovate.json) の `description`。Renovate 自体は [apps/renovate/](../apps/renovate/) の CronJob で動く。

## PVC を守る仕掛けをやめた

**「git で消したものは消える」を優先する**、という判断(本人)。PVC の `Prune=false,Delete=false` は git から消しても PVC が残り、
`reclaimPolicy: Retain` は追われない Released の PV を作っていた。

**代わりの後ろ盾はバックアップ。** 誤って消したときの最大損失は 24 時間ぶん。

**承知しておくこと**: `Delete=false` も外したので、**Argo CD の Application を消すと PVC も消える**。
マニフェストを消すのは git のレビューを通るが、Application の削除は UI のボタン 1 つで済む。

**`storageClassName` はバインド済み PVC では変更も削除もできない。** 変えるときは PVC を止め、PV を `Retain` にして古い PVC を消し、
PV の `claimRef` を外して書き換え、新しい PVC を `volumeName` で同じ PV に結ぶ。

## バックアップに何を含めるか

**有料でも取る。** R2 の無料枠(10 GB-month)に収めることを目的にすると録画を捨てることになる。
容量が問題になるのは桁が変わったとき(数百 GB)。課金は期間中の日次ピークの平均で、操作の回数は桁違いに余っている。

- 保持は k8up の Schedule で `keepDaily 7 / keepWeekly 4 / keepMonthly 6`(遡れるのは約半年)。etcd は日次で `keepDaily 7 / keepWeekly 4`
  ([../apps/k8up/etcd-snapshot.yaml](../apps/k8up/etcd-snapshot.yaml))
- 戻せるかは毎月 1 日に [../apps/k8up/restore-check.yaml](../apps/k8up/restore-check.yaml) が最新を取り出して確かめる

| 対象 | 判断 |
| --- | --- |
| 録画 | **エンコード済み(`denpa-encoded`)だけ、1 世代**([../apps/k8up/denpa-encoded-forget.yaml](../apps/k8up/denpa-encoded-forget.yaml))。放送は取り直せないので容量より価値を優先する(本人)。中身が入れ替わるので世代を持つと消えたファイルを抱え続ける |
| 生 TS の作業領域(`denpa-raw`) | **取らない。** エンコードが終われば消え、数時間で入れ替わる。14 GB まで育つ |
| AdGuard のクエリログ | **保持を 7 日に。** 純粋な計測データで、復元時に無くても困らない |

## Z440 で、ストレージを OpenEBS LVM LocalPV に、バックアップを VolSync にする(2026-10-20 に決めた)

**いまの弱点は戻す側。** local-path はスナップショットを取れないので、DB は k8up の `backupcommand` で論理ダンプを取り、
戻し方が経路ごとに 7 通りに分かれた(`recovery/pv.sh` の `restore-all` で 1 コマンドにはまとめた)。
スナップショットを取れるストレージにすると、次の 2 つが一度に手に入る:

- **ダンプが原則いらない。** スナップショットは crash-consistent で、Postgres・SQLite(WAL)・Tuwunel(RocksDB)はそこから自分で立ち直る。
  VolSync にフックが無いこと(作者が入れないと明言)が問題でなくなる
- **戻すのが自動になる。** VolSync の volume populator は、`dataSourceRef` で ReplicationDestination を指した PVC を
  作るだけで中身を埋める。ただし **populator は copyMethod: Snapshot が必須**(ドキュメントに明記)なので、local-path では使えない

選んだもの:

| | 判定 |
| --- | --- |
| **OpenEBS LVM LocalPV**(thin プール) | ◎ ローカル型で軽い。thin のボリュームでスナップショットが取れる。**OpenEBS の hostpath はスナップショットが無い**ので選ばない |
| TopoLVM | ○ 同等。対応表が Kubernetes 1.36 まで(1.37 は表の外)。スナップショットは thin のみ・同じ台でのみ戻せる |
| Longhorn | △ 複製型。1 台では重さの割に得るものが無い。**台数を増やすときに足す**(下) |
| Rook/Ceph | × 3 台以上・台ごとの専用ディスク・運用の知識が前提。数台の規模には過剰 |
| **VolSync**(Snapshot + populator) | ◎ データだけを PVC 単位で宣言的に取る。リソースは git と ArgoCD が戻すので役割が分かれる |
| Velero | ○ 取る前後のフックがあり、利用者も多い。ただしリソースのバックアップが git と重複し、戻すのは命令型で、リソースまで戻すと ArgoCD とぶつかる |

**移るのは Z440 への移設のとき。** いまの DL360 のディスクは local-path の `u-local-path` が残りを全部取っていて(`grow: true`)、
LVM 用のパーティションを切る余地が無い。Talos のボリュームは未割り当ての領域にしか作れないので、切り直すには入れ直しになる。
Talos は `RawVolumeConfig` と `LVMVolumeGroupConfig` でボリュームグループを machine config だけで作れる(シェルも特権 Pod も要らない。
LVM の設定は v1.14 のドキュメントにあり、siderolabs/talos#12309 が 2026-06 に閉じられて入った)。

**台数を増やすとき**は Longhorn を足し、止まって困るアプリから順に移す。VolSync の populator があれば、
StorageClass を変えた PVC を作り直すだけで中身が埋まるので、ストレージの乗り換えも同じ手で済む。
入口(Gateway・AdGuard・LiveKit)と API の宛先は 1 台の IP に固定されているので、そのときは VIP(Cilium の L2 Announcements、Talos の共有 VIP)も要る。

確かめていないこと: OpenEBS LVM LocalPV が Talos で動くか(`dm-snapshot` モジュール、読み取り専用のルートで LVM のコマンドが通るか)、
VolSync の restic mover と R2 の組み合わせ、restic が戻したファイルの持ち主、**thin プールが溢れたときの挙動と見張り**
(データとメタデータのどちらが溢れても書き込みが止まる。スナップショットを定期的に取るので、余裕と見張りが要る)。

## VPN を wg-easy から NetBird にした

要るのは **プライバシー(全部を自宅経由にする)・DNS(AdGuard)・iLO に入る**の 3 つ。
**NetBird は routing peer が独立した概念で、1 台構成でも問題が起きない**(Headscale は管理サーバーとサブネットルータの同居を避けよと書いている)。

**公式 Helm chart は使わない**(更新が止まっている。[netbirdio/helms#39](https://github.com/netbirdio/helms/issues/39))。
v0.65.0 から management/signal/relay が 1 つの combined コンテナなので、素の Deployment で足りる(`apps/netbird/`)。

- **gRPC と HTTP が同じホスト名・同じポートに混在する。** gRPC のサービスを GRPCRoute に、`/api` `/oauth2` `/relay` `/ws-proxy` を
  HTTPRoute に、残りをダッシュボードに振った。GRPCRoute なら Cilium が backend を h2c 扱いするので Gateway の設定を触らない
- **STUN は外のもの(Cloudflare)を使う。** 内蔵だとクラスタの中の routing peer から WAN 側に届かず、IPv4 の P2P に落ちる
- **`livenessProbe` は付けない。** healthcheck は `localhost:9000` にしか bind されない
- **外部 IdP(Entra)は設定ファイルに書けない**(0.62 以降はストアに入るデータ)。ダッシュボードか `POST /api/identity-providers` で足す。
  リダイレクト URI は `https://nb.doany.io/oauth2/callback` 固定

## 公開経路(HTTPRoute)をどこに置くか

**それぞれが公開しているものと同じ場所**に置く
(このリポジトリの `apps/<name>/httproute.yaml`、各アプリのリポジトリの `deploy/httproute.yaml`、`bootstrap/` の argocd / auth / redirect-https)。

`bootstrap/` の経路も ArgoCD(Application `bootstrap`)が当てる。ArgoCD が壊れても当たっている経路は消えず、
直すのは Headlamp か `tools/t.ps1 --admin` の kubectl で足りる。
外部露出の一覧は `kubectl get httproute,grpcroute -A` が正確で、git を読むより早い(一覧の一枚は作らない)。

**落とさずに動かす**: ArgoCD は「git から消えた + 自分が追跡している」ものを prune する。別リポジトリへは移送先を**先に**マージして
tracking-id が書き換わってから元を消す。`bootstrap/` へは、先に live に `Prune=false` を効かせてから移し、tracking-id 注釈を剥がす。

## DNS:直接つなぐアプリと Cloudflare を通すアプリを分ける

**Cloudflare を通すのが基本。遅延・通信量・Cloudflare が通さないものだけ直接つなぐ**(2026-10-22、本人)。
やり方と直接つなぐものの一覧は [apps/external-dns/README.md](../apps/external-dns/README.md)。

それまでは逆(社内用は直接、SaaS のように外へ出すものだけ Cloudflare)で、通すものに個別に注釈を付けていた。
直接つなぐ理由のあるもの(UDP・853 / 6443・100MB を超える上り・2 段の名前・遅延)を洗い出すと、それ以外は社内用でも
Cloudflare で困らなかったので、**例外の側に印を付ける**形に裏返した(`*.doany.io` を proxied にし、外すものに `cloudflare-proxied: "false"`)。
止めずに切り替えるため、外すものの明示のレコードを先に作り、家の IP で引けるのを確かめてからワイルドカードを proxied にした(#500 → #501)。
NetBird は管理画面だけ Cloudflare に分ける案もあったが、IdP・API・relay が同じ名前に同居していて得が無いので、丸ごと直接にした。

**DNS もアプリのリポジトリで持つ(疎結合)。** 中央の IaC(Pulumi・DNSControl・OctoDNS)に一覧を置くと、アプリを足すたびに 2 か所を直す。
ExternalDNS は HTTPRoute の注釈だけで決まり、自分が作ったレコード(所有の印の TXT 付き)にしか触れないので、メールや DDNS の apex と同居できる。
疎結合にできる候補(ExternalDNS・cloudflare-operator・Crossplane)のうち、DNS が主役で利用者が多いのが ExternalDNS。

**Entra のリダイレクト URI は中央(`pulumi/entra.ts`)のまま。** 共用のアプリ登録 1 つに全アプリの URI が入るので、そもそも中央に集まる。

## メールは Exchange Online の SMTP AUTH をやめ、クラスタの中の中継から Graph の sendMail で送る(2026-10-24)

SMTP AUTH の Basic 認証は 2026-12 末に既定で無効になる。移る先の候補は OAuth(XOAUTH2)・Graph の `sendMail`・IP で許すコネクタ。

- **XOAUTH2 は使えない。** `info@doany.io` は Exchange Online Kiosk で、Kiosk は SMTP の OAuth に対応していないとされる。
  Infisical はそもそも SMTP のユーザー名とパスワードしか話せない
- **コネクタ(IP で許す)は家の IP が固定でないので筋が悪い**
- したがって **Graph の `sendMail`**。アプリごとに Graph を話させず、普通の SMTP を受けて Graph に渡す中継
  ([smtp-oauth-relay](https://github.com/JustinIven/smtp-oauth-relay)、`apps/smtp-relay/`)を 1 つ置き、3 つのアプリは向け先だけ替えた
- **Graph の `Mail.Send` をテナント全体には付けない。** 誰としてでも送れてしまうので、Exchange の RBAC for Applications で
  送れるメールボックスを `info@doany.io` だけに絞った。初回は組織が dehydrated で `Enable-OrganizationCustomization`(取り消せない)が要り、
  実体化まで数時間かかった
- 中継は秘密を持たない(アプリが SMTP AUTH でクライアントシークレットを渡す)。クラスタの中だけで TLS なし、届く namespace は NetworkPolicy で絞る
