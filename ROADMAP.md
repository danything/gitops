# ROADMAP — バックアップ方式と Talos Linux への移行

いまの「Ubuntu + k3s(sqlite)」は暫定構成で、最終形は **Talos Linux**(ホストに repo も clone も置かない)。
ここには**やること と 進捗**だけを置く。**なぜそうしたかは [`docs/decisions.md`](docs/decisions.md)**、
Talos のインストールメディアは [`docs/talos.md`](docs/talos.md)、
復元リハーサルは [`docs/restore-drill.md`](docs/restore-drill.md)。

## いまここ

**次は Phase 2(いまの DL360 の上で k3s → Talos)。** 当日やることは
[docs/migration-day.md](docs/migration-day.md) を上から順に。
**そのあと Phase 2.5(Talos のまま HP Z440 へ移す)。** 順番を逆にした理由は
[docs/decisions.md](docs/decisions.md)「移行の順番: Talos を先に、Z440 は後」(2026-10-17)。
下の「済んだこと」は記録で、読まなくても当日は進む。

## Phase 2 — k3s → Talos(DL360 のまま。停止を伴う。**ネットワーク構成は変えない**)

**当日は [docs/migration-day.md](docs/migration-day.md) を上から順にやる。**
ここは「何を決めたか」で、あちらが「どの順にやるか」。

OS 交換だけに集中する。Cilium と Gateway API は Phase 1.5 で落ち着いた構成のまま持っていく。
Talos 側は **`KubeFlannelCNIConfig` を `$patch: delete` で消して `KubeProxyConfig` を
`enabled: false`** にし([talos/patches/cni.yaml](talos/patches/cni.yaml))、Cilium は
`k8sServicePort: 7445`(KubePrism)、`cgroup.autoMount.enabled: false` + `hostRoot: /sys/fs/cgroup` を足すだけ。
**v1alpha1 の `cni.name: none` はもう書けない**(型付きドキュメントと衝突する)。

**実機の RAM は 2026-10-17 から RDIMM 6 枚中 5 枚(40GB)。** 1 枚は Z440 の BIOS 更新に貸している(Phase 2.5)。

- [ ] 作業は LAN(10.0.0.2 / 10.10.0.4)か iLO(10.0.0.3)から。cloudflared 経由の ssh は使えない。
      **作業中は何も見せない(2026-09-08 に決めた)。** Cloudflare 側でメンテナンス画面を出す案は、
      止まっている数時間のために配線を 1 つ増やすことになるのでやめた。見に来るのは自分だけ。
- [ ] 最終バックアップを取り、`restic check` を通す。
- [ ] Talos を実機にインストール(`talos/README.md` の手順、schematic `96371c8f…`)。
- [ ] **入れたら bond0 の MAC を見る。** `talosctl get links bond0` が `e6:2c:1b:1a:a0:39` であること
      ([talos/patches/cluster.yaml](talos/patches/cluster.yaml) の `BondConfig` で固定。ルーターの IPv6 ホスト公開がこの MAC を指す)。
      別の回線の IPv6 から 443 に届くことも確かめる([docs/router.md](docs/router.md)「IPv6 はノードだけを公開する」)。
- [ ] **service の IPv6 CIDR を `fd43::/108` に変える**(Talos は `/64` を受け付けない)。ClusterIP が振り直しになる。
      設定は入っていて、VM で出ることも確かめた(2026-09-08。`kube-dns` が `["10.43.0.10","fd43::a"]`)。
      当日は「振り直された ClusterIP で困るものが無いか」を見るだけ。
- [ ] k8s オブジェクトは etcd 復元ではなく **git から ArgoCD で再構築**(k3s は sqlite なので、etcd から持ち越すものは無い)。
      **git に無いものが動いていないことは確認済み(2026-09-08)。** 追跡の印(ArgoCD の `tracking-id`・Helm・
      k3s の `objectset`・owner)の無いオブジェクトは 11 個で、全部 CI が `kubectl apply` で当てる `bootstrap/` のもの。
      例外の `infisical/data-postgresql-0` は StatefulSet の `volumeClaimTemplate` が作り直す。
- [ ] PV データを restic から復元。**手順は [docs/migration-day.md](docs/migration-day.md) の 8**
      (中身は [apps/k8up/README.md](apps/k8up/README.md)「戻し方」。**順番と、`Succeeded` が
      「戻った」の意味ではないこと**が要点。2026-09-08 に実際に流して確認済み)。
- [ ] Infisical → operator → 各アプリの順で疎通確認。DNS(cloudflare-ddns)、netbird、AdGuard の公開リゾルバを確認。
- [ ] **Renovate が戻ったことを見る。** 2026-10-16 から k8s の CronJob([apps/renovate/](apps/renovate/))で動いているので、
      再構築が済むまで依存更新の PR は止まる。ArgoCD が戻したあと、次の回で PR が来ること。
- [ ] **PT3**: 上流 PR は v1.15.0-alpha.1 に入った。schematic に `dvb-pt3` を入れ、`earth-pt3` を読ませてある。
      実機で `/dev/dvb/adapter*` が出るのを確かめ、tuner-agent に `/dev/dvb` を hostPath で渡す
      ([docs/decisions.md](docs/decisions.md)「PT3 チューナー」)。

### 用意が済んだもの

- **`talos/secrets.yaml` と `talos/registries.yaml`(2026-09-08、registries は 2026-09-15 に fj.doany.io の資格情報へ)** ── [talos/README.md](talos/README.md)
- **local-path-provisioner**(置き場は専用パーティション `/var/mnt/local-path`。**ディスクの割り方は入れ直さないと変えられない**)── [talos/manifests/local-path.yaml](talos/manifests/local-path.yaml)、[talos/patches/volumes.yaml](talos/patches/volumes.yaml)
- **metrics-server**(`--kubelet-insecure-tls` が要る)── [talos/metrics-server-values.yaml](talos/metrics-server-values.yaml)。k3s の他のアドオンは Talos が入れるか、要らない
- **Gateway API の CRD**(無いと公開経路が丸ごと消える)── [talos/render.sh](talos/render.sh) が URL で渡す。版は [talos/versions.yaml](talos/versions.yaml)
- **起動順序**(本物の値で焼いたドリルで `apply-config` 1 回で全部立ち上がった)── [docs/talos.md](docs/talos.md)「ブートドリル 4 回目」、[docs/decisions.md](docs/decisions.md)「Talos の起動順序をどう組むか」。**`upgrade-k8s` の前には必ず描き直す**([talos/README.md](talos/README.md)「上げ方 / 当て直し方」)
- **ファイルの PVC バックアップを k8up に寄せた(2026-09-08)** ── [apps/k8up/README.md](apps/k8up/README.md)。ホストのスクリプトを畳むのは Talos に移る時点
- **`local-path-retain` を消した(2026-10-05)。** 28 本の PVC を PV の使い回しで `local-path` に付け替えた(データはコピーしていない)。denpa の録画の PVC を `denpa-raw` / `denpa-encoded` に改名、**ホスト上のディレクトリ名は改名前のまま**(Talos で揃う)── [docs/decisions.md](docs/decisions.md)「PVC を守る仕掛けをやめた」
- **改名前の録画のスナップショットを消した(2026-10-05、88.6 → 37.3 GiB)** ── [docs/decisions.md](docs/decisions.md)「バックアップに何を含めるか」
- **helm 値が git と実機で一致、argocd と infisical の chart の版を固定(2026-09-08)** ── [bootstrap/README.md](bootstrap/README.md)
- **見直しで塞いだ漏れ 3 つ(2026-10-05: CI の CA、ApplicationSet が Forgejo 待ちで止まる件、cilium-drift の偽 FAILED)** ── migration-day の 6・7・10 に反映済み

## Phase 2.5 — HP Z440 へ移す(Talos のまま)

**手順は [docs/z440-migration.md](docs/z440-migration.md)。** Talos の machine config は宣言的なので、
箱の違いは schematic と NIC の名前に閉じ込める。bond0 の MAC は設定で固定してあるので、ルーターは触らない。

- [ ] **Intel Arc A310 を買う(常設)。** Xeon E5 に内蔵 GPU は無く、**Z440 は単体の GPU が無いと POST しない。**
      ロープロファイル・補助電源なし・AV1 のハードウェアエンコード可で、denpa の QSV もこれで賄う
      (いまの DL360 の画面は iLO の Matrox G200 だけで、denpa の Pod に `renderD*` が無い)。
      **Arc は UEFI + CSM 無効が要る。**
- [ ] **BIOS を 02.62 に上げてから E5-2696 v4 を載せる。** 上げるまでは仮の CPU と、DL360 から借りた RDIMM 1 枚で起こす。
- [ ] **AMT を設定する(9.x、10.0.0.5)。** 電源と SOL だけで KVM は無い。iLO のように画面は見えない。
- [ ] **Z440 用の schematic。** Intel GPU の extension(**`siderolabs/i915` で足りるか要確認**。新しい世代の Arc B シリーズなどは
      `siderolabs/xe`。**両方は入れない** ── 同じ GPU を取り合う)と、SOL に出すための `console=` のカーネル引数。
      変えたら `talos/versions.yaml` の ID と depName を差し替える。
- [ ] **NIC を MAC で名付ける(`LinkAliasConfig`)。** 箱が替わるとインタフェース名が変わるので、bond のメンバーは名前でなく MAC で指す。
- [ ] Z440 用の machine config を先に描いて置いておき、移す。
- [ ] 移したら: `talosctl ls /dev/dri` に `renderD128`、`talosctl dmesg` に GuC / HuC の読み込みが出ること。
      **denpa 側は何もしなくてよい**(イメージの ffmpeg は QSV / VA-API 入りで、chart は `/dev/dri` をマウント済み)。
      `talosctl get links bond0` の MAC と、外からの IPv6 も Phase 2 と同じく見る。
- [ ] docs の「iLO(10.0.0.3)」を AMT(10.0.0.5)に直す(talos.md・router.md など、移設後も使う手順)。

## Phase 3 — Talos 定常運用

- [ ] **etcd スナップショットの定期化。用意は済んだ(2026-10-05)** ── 移行後に
      `talos/after-migration/etcd-snapshot.yaml` を `apps/k8up/` へ移すだけ(migration-day の 10)。
      Talos の `kubernetesTalosAPIAccess` で **`os:etcd:backup` だけ**を k8up の namespace に渡し
      (`talos/patches/etcd-backup.yaml`。`os:admin` の talosconfig を Secret に置く案はやめた)、
      日次で同じ restic リポジトリへ(`--host etcd`)。**戻すときの主経路は git からの再構築のまま**で、
      こちらは近道(docs/talos.md「etcd スナップショットからの復旧」)。
- [ ] 四半期ごとに VM で復元リハーサル(PV + etcd の両方)。**初回は Forgejo を含めること**
      (非公開アプリのイメージとマニフェストが Forgejo から来る経路は、まだ一度も通していない)。
- [ ] **k3s 期の残りを畳む。** ホストのスナップショット(`host=main`)は保持が `--keep-monthly 2` なので
      移行から約 2 か月で落ちきる。そこで `backup/`、`recovery/restore.sh`、
      `apps/k8up/README.md` の `sudo k3s kubectl …` の例を消す(`recovery/env.age` は残す ──
      Talos 期も `k8up-global` を手で作るのに要る)。それまでは k3s に戻る道として置いておく。
- [ ] **移行して 1〜2 か月してから R2 の容量をもう一度見る。** 数字は `pulumi` ワークフローの週次の Summary に出る。
      k3s 期はホストの `backup/k3s-backup` が `/var/lib/rancher/k3s/storage` を丸ごと取っていて、
      k8up の per-PVC の保持設計がどれも効いていなかった
      ([docs/decisions.md](docs/decisions.md)「バックアップに何を含めるか」)。
      `host=main` のスナップショットが保持から落ちきると、
      [apps/k8up/denpa-encoded-forget.yaml](apps/k8up/denpa-encoded-forget.yaml) を含めて
      ようやく効きはじめる。そこで初めて本当の定常サイズが分かる。

済んだもの:

- **k8up の失敗通知(2026-09-08)** ── [apps/k8up/notify.yaml](apps/k8up/notify.yaml) が日次で Matrix の `server` へ。[apps/k8up/README.md](apps/k8up/README.md)「失敗したときに気づけるようにする」。`restic check` も [schedules.yaml](apps/k8up/schedules.yaml) に
- **R2 のずれ検知(2026-10-05、初回から一致)** ── [docs/decisions.md](docs/decisions.md)「バックアップに何を含めるか」
- **`talosctl upgrade` / `upgrade-k8s` の手順(2026-09-08)** ── [talos/README.md](talos/README.md)「上げ方 / 当て直し方」。`upgrade-k8s` は bootstrap 層の当て直しも兼ねる
- **通信の可視化は Hubble で足りる(2026-09-07、`hl.doany.io`)。** 公開しているものの一覧は作らない ── [docs/decisions.md](docs/decisions.md)「公開経路(HTTPRoute)をどこに置くか」

## 済んだこと(記録)

1 行ずつ。詳しいことはリンク先にある。

- **Phase 0 — k3s のまま restic 化(2026-09-06)。** R2 の `doany-restic` へ日次、復元は `recovery/` のパスフレーズ 1 つ、リハーサル 2 回([docs/restore-drill.md](docs/restore-drill.md))。pull 認証はノード単位(2026-09-15 から fj.doany.io だけ。decisions.md「ghcr の pull 認証」)
- **Phase 0.5 — `k3s/` を `deploy/` に改名(2026-09-06)。** 8 repo、`k3s-gitops` は `gitops` に、ApplicationSet は `deploy/argocd.yaml` だけを見る
- **Phase 1 — Talos の検証(2026-09-06〜07)。** QEMU で起動から etcd 復旧まで([docs/talos.md](docs/talos.md)「VM ブートドリル」「PSA のラベル」)、HelmChart CRD を Application に(decisions.md「HelmChart CRD から ArgoCD の Application へ」)、k8up を導入([apps/k8up/README.md](apps/k8up/README.md))
- **Phase 1.5 — k3s のまま Cilium + Gateway API に(2026-09-06〜07)。** **Talos で後から替えるのが高いのは CNI だけ**なので先に。経緯と障害は decisions.md「ルーティングの選定」。Traefik を消した時点で切り戻しの道は閉じている
- **Phase 1.7 — 運用まわり(2026-09-07)。** Cilium の Helm 値を git に([bootstrap/cilium/README.md](bootstrap/cilium/README.md))、Entra をアプリロールに([docs/entra.md](docs/entra.md))、自動マージの範囲(decisions.md「依存の更新をどこまで自動で入れるか」)、Talos の更新は検知だけ自動([talos/versions.yaml](talos/versions.yaml))
- **復元リハーサルの宿題(2026-09-07〜08、全部片付いた)** ── [docs/restore-drill.md](docs/restore-drill.md)、apps/k8up/README.md「CRD がまだ無いクラスタで apps を止めないこと」、[apps/k8up/k8up-secrets.yaml](apps/k8up/k8up-secrets.yaml)
- **PVC を守る仕掛けをやめた(2026-09-07、`local-path-retain` の撤去は 2026-10-05)** ── decisions.md「PVC を守る仕掛けをやめた」
