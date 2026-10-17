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

一番危ない OS の入れ替え(Talos への移行)は、**iLO で画面まで見える DL360** で済ませた。Z440 の遠隔管理は
AMT 9.x(電源と SOL だけ)で、単体の GPU が無いと POST もしない。Talos なら箱の違いは schematic と NIC の名前に閉じる。
計画と箱の違いは [z440-migration.md](z440-migration.md)。

## bond0 の MAC を固定する(2026-10-17)

ルーターの IPv6 ホスト公開はノードを **bond0 の MAC(`e6:2c:1b:1a:a0:39`)で指している**
([router.md](router.md)「IPv6 はノードだけを公開する」)。固定しないと bond は先頭のメンバーの MAC を引き継ぎ、
再起動で変わってエントリから外れたことがある。[talos/patches/cluster.yaml](../talos/patches/cluster.yaml) の `BondConfig` の
`hardwareAddr` に書いたので、NIC の交換でも Z440 への移設でも変わらない。

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

リモートは Cloudflare R2 のバケット `doany-restic`(APAC、Standard。2026-09-06)。API トークンは
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

### そのパスフレーズをどこに置くか(2026-09-08 決定)

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

## Talos の起動順序をどう組むか(2026-09-07)

Talos には helm-controller が無く、inlineManifests は Helm を実行できないので、手元の `render.sh` が `helm template` して載せる。
**ArgoCD は Infisical 無しで起動する。** `$argocd-oidc:client-secret` のような参照は Secret が無いと警告して文字列のまま返す
(`util/settings/settings.go`)ので、SSO が効かないだけで同期は動く。順序は
**Cilium → ArgoCD → ArgoCD が Infisical を入れる → operator が Secret を作る → SSO が効く**。
その窓の間は `admin.enabled: false` なので UI に誰も入れない(要るなら一時的に戻す。`kubectl` で見る)。

### 層の分け方

| 層 | 中身 | 資格情報 |
| --- | --- | --- |
| **machine config** | **`bootstrap/` のほぼ全部。** inline が 8 つ(cilium / local-path / `bootstrap-applier` の RBAC / argocd / cert-manager / infisical / SOPS の Secret 2 つ)、CRD だけ URL で 5 つ(gateway-api / argocd ×3 / cert-manager) | 入力(`talos/secrets.yaml` など)が SOPS 済みで、生成物は git に置かない |
| **GitHub Actions** | `bootstrap/` の残り(`ClusterIssuer`・Gateway・auth・`InfisicalSecret` など、平文のもの) | OIDC。**Secret 権限なし・delete なし**の狭い RBAC |
| **ArgoCD** | `apps/`(**infisical は来ない**。下の「infisical だけは ArgoCD に移せない」) | — |

- **CRD だけ URL で渡すのは大きさの都合。** 埋めると machine config が 341 KB → 4 MB を超える。
  `KubeExternalManifestConfig` は Talos がそのために用意している入口([talos/render.sh](../talos/render.sh))
- **ArgoCD を CI 側に置かない。** 導入には CRD・ClusterRole・Secret が要る ── 実質 cluster-admin で、
  CI の RBAC を狭く保つ意味が消える([bootstrap/apiserver/rbac.yaml](../bootstrap/apiserver/rbac.yaml))
- **SOPS の Secret を machine config に入れる。** CI には age 鍵を渡さないので CI からは当てられない。machine config は
  もともと SOPS で暗号化して git に置いている(クラスタ CA の秘密鍵を含む)ので信頼水準は変わらず、起動時点で存在する
- **Helm を実行する場所はクラスタの外(手元の生成時)だけ。** Cilium は CNI なので inlineManifests 以外に置きようがなく、
  ArgoCD も同じ扱いにすればクラスタ内に Helm コントローラを持たなくて済む。版の追従は Renovate

## machine config と Cilium の chart をどう連動させるか(2026-09-08 決定)

**machine config を「派生物」にする。** `helm template` の出力を `KubeInlineManifestConfig` に包んで `--config-patch` として渡す
([talos/render.sh](../talos/render.sh))ので、Cilium の値がリポジトリに二度書かれない。Renovate は
`bootstrap/cilium/version.yaml` を見ていて、machine config は毎回そこから描き直されるだけ。

**`helm upgrade` は使わない。** 更新経路は「`values.yaml` を直す → 描き直す → `upgrade-k8s`」。古い machine config のまま
`upgrade-k8s` を流すと走っている Cilium が巻き戻る([../talos/README.md](../talos/README.md)「上げ方 / 当て直し方」)。
流し忘れは [cilium-drift.yml](../.github/workflows/cilium-drift.yml) が週次で live と突き合わせる。
bootstrap のあとに `helm install` する案は、再構築のたびに「CNI が無いので何も動かない」状態での手作業が増えるので採らない。

**描いた結果はコミットしない(2026-10-17 に再検討)。** 描き出しを git に置いて Renovate の `postUpgradeTasks` に描き直させれば
当てるのは「重ねるだけ」になるが、採らない:
- **infisical の描き出しは秘密を含む。** chart が Redis の接続文字列(`REDIS_URL`)をパスワードごと Deployment の env に書き、
  外から渡す口が無い(1.11.0 のテンプレートで確認)。ここだけは手元で描くしかなく、描く道具は結局残る
- 描き出しは machine config で 980 行・310 KB(1 行が長い)。版を上げるたびにその差分が積もる
- 代わりに **描くたびに変わる値を潰した**(Hubble の証明書・infisical の `postgres-password`・`updatedAt`)。
  同じ入力なら生成物はバイト単位で同じなので、`apply-config --dry-run` の差分がそのまま「何が変わるか」になる

**起動に要らないものは ArgoCD に置く。** metrics-server は 2026-10-17 に `apps/metrics-server/` へ移した
(版上げが `upgrade-k8s` 無しで済む)。cert-manager は移さない ── CRD を machine config から外すと Talos の prune が CRD を消しうる(消えれば
全 namespace の Certificate が道連れ)。

## ルーティングの選定(2026-09-06)

**Cilium(CNI + Gateway API)に寄せる。** `Ingress` API は凍結済みで ingress-nginx は 2026-03 に retire。
**Talos で後から替えるのが高いのは CNI だけ**なので先に決め、Ingress・LB・証明書は Gateway API に寄せて後から差し替えられるようにした。

| | 選択 | 置き換わるもの |
| --- | --- | --- |
| CNI | Cilium | flannel |
| kube-proxy | Cilium の kubeProxyReplacement | kube-proxy |
| LoadBalancer | 使わない(hostPort と Gateway の hostNetwork。下記) | ServiceLB |
| Ingress | Cilium Gateway(Gateway API) | Traefik |
| 証明書 | cert-manager(Cloudflare DNS-01) | Traefik 内蔵 ACME |
| 認証 | oauth2-proxy を前段のプロキシに(下記) | — |

- **Cilium 1.20 は Gateway API v1.6.1 の CRD を要求する。** 古いと GatewayClass が `Waiting for controller` のまま止まる
- **ノード自身からは 80/443 に届かない。** Gateway の nodePort が L7LB リダイレクトとして載っているため(外から来る通信の経路そのもの)
- **`terminationGracePeriodSeconds` が長い Pod**(denpa と tuner-agent、6 時間)は Recreate と組むと入れ替わらない。`--grace-period=0 --force` で消す

### LoadBalancer をどう置き換えるか(2026-09-06 決定・実施済み)

**hostPort を選んだ。** ルータの DMZ 転送先と AdGuard の split-horizon が**ノード自身の IP**(`10.0.0.2` / `10.10.0.4` /
`240f:6d:842b:1::2`)に固定されていて、LB-IPAM の仮想 IP だとクラスタ外の変更が要り、IPv6 のプレフィックスは RA 由来で変わりうる。
hostPort ならノードの全アドレスで受けられ、送信元 IP も保たれる。ノードが増えて VIP が要るなら、そのとき LB-IPAM に移る。

| 対象 | hostPort |
| --- | --- |
| Gateway(`cilium-gateway-doany`) | 80 / 443。Envoy が hostNetwork で bind するが、**実通信は nodePort の L7LB リダイレクト経由**(`bootstrap/cilium/values.yaml` の `nodePort`)。nodePort 80/443 は bootstrap-apply が当て直す |
| adguardhome | 53 UDP・53 TCP・853 TCP |
| matrix の LiveKit | 8443 UDP・8443 TCP |
| 3proxy(tls-terminator サイドカー) | 3129 TCP |

- **Cilium の hostPort は既定で無効**(`hostPort.enabled`)。有効にしたら対象の Pod を作り直す(サンドボックス作成時に設定される)。
  `ss` には出ないので確認は `cilium-dbg service list | grep HostPort`
- **hostPort と RollingUpdate は両立しない**(新しい Pod が Pending で止まる)。AdGuard と 3proxy は `strategy: Recreate`
- **Gateway はアドレスが付くまで `Programmed=False`。** `gatewayAPI.hostNetwork` でノードの IP が `status.addresses` に入る
- **`nodePort.range` は `80,443` の 2 つだけ。** Cilium は nodePort の範囲に入る hostPort を張らない(`80-32767` にしたら 853・8443・3129 が一斉に落ちた)。
  前段を入れ替えるときは、自分で配っている chart の入口(denpa の `httpRoute`)も数えること

### 3proxy と AdGuard の DoH はサイドカーで TLS を終端する

- **3proxy**(TLS 終端 + 素の TCP): Cilium は `mode: Terminate` のリスナーに TLSRoute しか許さず、同じ 443 に Terminate と Passthrough を
  同居させると ProtocolConflict で 443 ごと落ちる。nginx(stream)のサイドカーが **hostPort 3129** で終端して `127.0.0.1:3128` に渡す
- **AdGuard の DoH**: AdGuard は `/dns-query` を HTTPS の口(443)でしか出さない(平文の 80 は 404。切り替えの翌朝、ブラウザの名前解決だけが死んだ)。
  `BackendTLSPolicy` は Cilium 1.20.1 が Accepted にするだけで実装していない。nginx のサイドカーが `/dns-query` だけを
  `https://127.0.0.1:443` へ回す。Cilium が `BackendTLSPolicy` を実装したら両方まとめて消せる

### クライアント IP(2026-09-07 確認、`Cluster` のままでよい)

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

Traefik の sticky cookie に代わるものが無い(使っていたのは tamasagashi 1 本。更新中に HTML と CSS/JS が別の Pod から返る 404 を防ぐため)。
Gateway API の session persistence は experimental チャネル限定、Cilium は 1.21 から(cilium/cilium#48029)、
`sessionAffinity: ClientIP` は Gateway 経路に効かない。いまは replicas 1 で穴を受け入れている。
**1.21 に上げるときに Gateway API CRD を experimental に替え(`talos/render.sh` の URL)、tamasagashi の HTTPRoute に `sessionPersistence` を足す。**
それまでにアプリを複数 replica にするなら、セッション固定が無いことを先に確かめる。

## chart を配るときと、chart で入れるとき(2026-09-07)

**`HelmChart` CRD(helm-controller)はやめた。** ArgoCD と二重管理になり(差分も同期状態も prune も見えない)、Talos に無い。
argocd と infisical も `bootstrap/<name>/` の version.yaml・values.yaml から `render.sh` が描く。**Helm chart を配る(OCI で push する)のは続ける**(denpa と yosegaki)。
入れ方は利用者に選ばせる(`helm install` でも `Application` でも同じものが入るのが正しい)。このクラスタは ArgoCD の `Application` に統一した。

配る chart でやらないこと(踏んだもの。自分の chart はどれも該当しない):

- リソース名に時刻や乱数を入れない(GitOps は同期のたびに別物として作り直す)
- CRD は `templates/` ではなく `crds/` に置く(`templates/` だとアンインストールで CR が全部巻き添えになる)
- 全ワークロードに `podAnnotations` と `resources` を出す(注釈は k8up・Infisical・ArgoCD が振る舞いを足す口)
- patch で中身を入れ替えない(chart の patch 更新で Dragonfly が Valkey に替わり、values のチューニングが黙って無効になった)
- 入口(`Ingress` / `httpRoute`)を既定で作らない

**別のリリース名で入れ直すと別物として作り直しになる**(名前を切り詰める chart がある)。入れ方を替えるときは `helm template` と live を先に突き合わせる。

### infisical だけは ArgoCD に移せない(2026-09-08、chart を読んで確定)

**理由は鶏卵ではなく chart の作り。** `infisical-standalone` 1.10.0 は `DB_CONNECTION_URI` と `REDIS_URL` を
`.Values.*.auth.password` から **Deployment の平文 env に焼き込む**(`templates/_helpers.tpl`)ので、平文の Application に値を書けない。
`postgresql.useExistingPostgresSecret` は同梱の Postgres と併用すると URI が 2 回描かれて平文が勝ち、Redis には逃げ道が無い。
`*.auth.existingSecret` は subchart にしか効かず、本体は既定値で URI を組んで繋がらなくなる(`helm template` で確認)。
**なので `bootstrap/` に残し、machine config の `inlineManifests` に載せる。** `render.sh` が SOPS 済みの値を復号して `helm template` に渡すので、
平文は machine config の中にしか出ない。

## ghcr の pull 認証

**2026-09-15 から ghcr.io の資格情報は要らない** ── 非公開のリポジトリを Forgejo に移し(apps/forgejo/README.md)、
ghcr.io に残るイメージは全部公開。**ノード単位で持つのは fj.doany.io の資格情報だけ**(`talos/registries.yaml`、[talos/README.md](../talos/README.md))。

## PT3 チューナー(Talos で動かすための算段)

実機には Earthsoft PT3(`earth_pt3`、Altera 1172:4c15)が刺さっていて、Talos のカーネルは `CONFIG_DVB_PT3` を
有効にしておらず、公式 extension にも無かった。denpa の tuner-agent はこの箱の `/dev/dvb` と B-CAS リーダーに依存している。

**結論(2026-10-13): 上流に入った。** [siderolabs/pkgs#1682](https://github.com/siderolabs/pkgs/pull/1682)
(`CONFIG_DVB_PT3=m`)が v1.15.0-alpha.1 に入り、`siderolabs/dvb-pt3` が Image Factory の公式 extension に出た。
本番の schematic を `96371c8f…`(dvb-pt3 + intel-ucode + IOMMU の引数)に作り直し、Talos を v1.15.0-alpha.1 に上げた
(`talos/versions.yaml`)。extension は `earth_pt3` を blacklist して配るので、`talos/patches/main.yaml` の
`machine.kernel.modules` で読ませる。alpha をノード 1 台の本番に乗せることになるが、正式版を待つより PT3 を先に取った。

**駄目だったときの保険: KubeVirt の VM にパススルー。** PT3(05:00.0)は IOMMU グループ 36 に単独、B-CAS は USB(GemPC Twin 08e6:3437)。
`intel_iommu=on` は schematic に残してあるが、vfio は `talos/patches/main.yaml` から外した(PT3 をホストのドライバと取り合う)ので、戻るなら足し直す。
**自前 extension を `imager` で焼く案は採らない**(アップグレードのたびに自前ビルドになる)。

## 依存の更新をどこまで自動で入れるか(2026-09-07)

共有プリセット `5ym/repo-config` で、**パッチとマイナーは 1 つの PR にまとめて自動マージ、メジャーと Helm chart は人が見る**
(postgres 17 → 18 が nginx のパッチと同じ PR で自動マージされかけた danything/gitops#7、chart のパッチ更新で中身が入れ替わった件から)。
PostgreSQL は 17 の線に固定(メジャーでデータディレクトリの互換が切れ、dump / restore が要る)、argo-cd と infisical-standalone の chart は自動マージしない。
理由はそれぞれ [../renovate.json](../renovate.json) の `description`。Renovate 自体は [apps/renovate/](../apps/renovate/) の CronJob で動く。

## PVC を守る仕掛けをやめた(2026-09-07)

**「git で消したものは消える」を優先する**、という判断(本人)。PVC の `Prune=false,Delete=false` は git から消しても PVC が残り、
StorageClass `local-path-retain`(`reclaimPolicy: Retain`)は追われない Released の PV を作っていた(35 日と 44 日放置が 3 本)。

**代わりの後ろ盾はバックアップ。** 誤って消したときの最大損失は 24 時間ぶん。**この判断は復元リハーサルが通ってから**行った
(2026-10-17 には実際にこれで全部戻した)。

**承知しておくこと**: `Delete=false` も外したので、**Argo CD の Application を消すと PVC も消える**。
マニフェストを消すのは git のレビューを通るが、Application の削除は UI のボタン 1 つで済む。

**`storageClassName` はバインド済み PVC では変更も削除もできない。** 変えるときは PVC を止め、PV を `Retain` にして古い PVC を消し、
PV の `claimRef` を外して書き換え、新しい PVC を `volumeName` で同じ PV に結ぶ(2026-10-05 に 28 本をこれで付け替えた)。

## バックアップに何を含めるか

**有料でも取る(2026-09-08)。** R2 の無料枠(10 GB-month)に収めることを目的にすると録画を捨てることになる。
容量が問題になるのは桁が変わったとき(数百 GB)。課金は期間中の日次ピークの平均で、操作の回数は桁違いに余っている。

いまの姿(2026-10-17):

- **restic の実データは 5.60 GiB**(圧縮前 8.52 GiB)。前のホストのスクリプト(`host=main`)が PV の置き場を丸ごと持っていて、
  k8up の世代を減らしても同じ blob を掴んで解放されなかったが、2026-10-17 に forget + prune した
- 保持は k8up の Schedule で `keepDaily 7 / keepWeekly 4 / keepMonthly 6`(遡れるのは約半年)。etcd は日次で `keepDaily 7 / keepWeekly 4`
  ([../apps/k8up/etcd-snapshot.yaml](../apps/k8up/etcd-snapshot.yaml))
- 戻せるかは毎月 1 日に [../apps/k8up/restore-check.yaml](../apps/k8up/restore-check.yaml) が最新を取り出して確かめる

| 対象 | 判断 |
| --- | --- |
| 録画 | **エンコード済み(`denpa-encoded`)だけ、1 世代**([../apps/k8up/denpa-encoded-forget.yaml](../apps/k8up/denpa-encoded-forget.yaml))。放送は取り直せないので容量より価値を優先する(本人)。中身が入れ替わるので世代を持つと消えたファイルを抱え続ける |
| 生 TS の作業領域(`denpa-raw`) | **取らない。** エンコードが終われば消え、数時間で入れ替わる。14 GB まで育つ |
| AdGuard のクエリログ | **保持を 7 日に。** 純粋な計測データで、復元時に無くても困らない |

## VPN を wg-easy から NetBird にした(2026-09-07)

要るのは **プライバシー(全部を自宅経由にする)・DNS(AdGuard)・iLO に入る**の 3 つで、スマホを足すときの QR はよく使う。
wg-easy は自前の認証を切れず SSO の後ろでも二重ログインが残り([wg-easy#1923](https://github.com/wg-easy/wg-easy/issues/1923))、
Headscale は FAQ が「headscale を動かすマシンをサブネットルータにするな」と書いていてノード 1 台では避けられない。
**NetBird は routing peer が独立した概念で、1 台構成でも問題が起きない。**

**公式 Helm chart は使わない**(更新が止まっている。[netbirdio/helms#39](https://github.com/netbirdio/helms/issues/39))。
v0.65.0 から management/signal/relay が 1 つの combined コンテナなので、素の Deployment で足りる(`apps/netbird/`)。

- **gRPC と HTTP が同じホスト名・同じポートに混在する。** gRPC のサービスを GRPCRoute に、`/api` `/oauth2` `/relay` `/ws-proxy` を
  HTTPRoute に、残りをダッシュボードに振った。GRPCRoute なら Cilium が backend を h2c 扱いするので Gateway の設定を触らない
- **STUN(UDP 3478)はリバースプロキシを通せない**ので hostPort。namespace の PSA が `privileged` なのはこのため
- **`livenessProbe` は付けない。** healthcheck は `localhost:9000` にしか bind されない
- **外部 IdP(Entra)は設定ファイルに書けない**(0.62 以降はストアに入るデータ)。ダッシュボードか `POST /api/identity-providers` で足す。
  リダイレクト URI は `https://nb.doany.io/oauth2/callback` 固定

## 公開経路(HTTPRoute)をどこに置くか(2026-09-07)

`apps/gateway-routes/` にまとめていたのをやめ、**それぞれが公開しているものと同じ場所**に置いた
(このリポジトリの `apps/<name>/httproute.yaml`、各アプリのリポジトリの `deploy/httproute.yaml`、`bootstrap/` の argocd / auth / redirect-https)。
ArgoCD は `recurse` で拾い tracking-id 注釈で追跡するので、場所は挙動に影響しない。

**`bootstrap/` に移したものが本題。** `argocd` と `auth` の実体はこの層にあり、ArgoCD は同期していない。
ArgoCD が自分の公開経路を握っていると、ArgoCD が壊れているときにその経路を直せない。
外部露出の一覧は `kubectl get httproute,grpcroute -A` が正確で、git を読むより早い(一覧の一枚は作らない)。

**落とさずに動かす**: ArgoCD は「git から消えた + 自分が追跡している」ものを prune する。別リポジトリへは移送先を**先に**マージして
tracking-id が書き換わってから元を消す。`bootstrap/` へは、先に live に `Prune=false` を効かせてから移し、tracking-id 注釈を剥がす。

## DNS:直接つなぐアプリと Cloudflare を通すアプリを分ける(2026-10-06)

**社内用や通信量が多いアプリは直接つなぐ。SaaS のように外へ出すアプリは Cloudflare のプロキシを通す**(本人)。

- 直接つなぐもの:`*.doany.io` のワイルドカード(proxied ではない CNAME → `doany.io`)で引ける。明示のレコードは持たない
- Cloudflare を通すもの:アプリのリポジトリの HTTPRoute に `external-dns.kubernetes.io/cloudflare-proxied: "true"` を付け、
  **ExternalDNS**(`apps/external-dns/`)が proxied の CNAME を作る

**DNS もアプリのリポジトリで持つ(疎結合)。** 中央の IaC(Pulumi・DNSControl・OctoDNS)に一覧を置くと、アプリを足すたびに 2 か所を直す。
ExternalDNS は HTTPRoute の注釈だけで決まり、自分が作ったレコード(所有の印の TXT 付き)にしか触れないので、メールや DDNS の apex と同居できる。
疎結合にできる候補(ExternalDNS・cloudflare-operator・Crossplane)のうち、DNS が主役で利用者が多いのが ExternalDNS。

**Entra のリダイレクト URI は中央(`pulumi/entra.ts`)のまま。** 共用のアプリ登録 1 つに全アプリの URI が入るので、そもそも中央に集まる。
