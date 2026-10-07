# ROADMAP — バックアップ方式と Talos Linux への移行

いまの「Ubuntu + k3s(sqlite)」は暫定構成で、最終形は **Talos Linux**(ホストに repo も clone も置かない)。
ここには**やること と 進捗**だけを置く。**なぜそうしたかは [`docs/decisions.md`](docs/decisions.md)**、
Talos のインストールメディアは [`docs/talos.md`](docs/talos.md)、
復元リハーサルは [`docs/restore-drill.md`](docs/restore-drill.md)。

## いまここ

**Phase 2(k3s → Talos)の直前。** 当日やることは
[docs/migration-day.md](docs/migration-day.md) を上から順に。
下の「済んだこと」は記録で、読まなくても当日は進む。

## Phase 2 — k3s → Talos(停止を伴う。**ネットワーク構成は変えない**)

**当日は [docs/migration-day.md](docs/migration-day.md) を上から順にやる。**
ここは「何を決めたか」で、あちらが「どの順にやるか」。

OS 交換だけに集中する。Cilium と Gateway API は Phase 1.5 で落ち着いた構成のまま持っていく。
Talos 側は **`KubeFlannelCNIConfig` を `$patch: delete` で消して `KubeProxyConfig` を
`enabled: false`** にし([talos/patches/cni.yaml](talos/patches/cni.yaml))、Cilium は
`k8sServicePort: 7445`(KubePrism)、`cgroup.autoMount.enabled: false` + `hostRoot: /sys/fs/cgroup` を足すだけ。
**v1alpha1 の `cni.name: none` はもう書けない**(型付きドキュメントと衝突する)。

- [ ] 作業は LAN(10.0.0.2 / 10.10.0.4)か iLO(10.0.0.3)から。cloudflared 経由の ssh は使えない。
      **作業中は何も見せない(2026-09-08 に決めた)。** Cloudflare 側でメンテナンス画面を出す案は、
      止まっている数時間のために配線を 1 つ増やすことになるのでやめた。見に来るのは自分だけ。
- [ ] 最終バックアップを取り、`restic check` を通す。
- [ ] Talos を実機にインストール(`talos/README.md` の手順、schematic `32820716…`)。
- [ ] **service の IPv6 CIDR を `fd43::/108` に変える**(Talos は `/64` を受け付けない)。ClusterIP が振り直しになる。
      設定は入っていて、VM で出ることも確かめた(2026-09-08。`kube-dns` が `["10.43.0.10","fd43::a"]`)。
      当日は「振り直された ClusterIP で困るものが無いか」を見るだけ。
- [ ] k8s オブジェクトは etcd 復元ではなく **git から ArgoCD で再構築**(k3s 固有の HelmChart 等が etcd に混ざっているため)。
      **git に無いものが動いていないことは確認済み(2026-09-08)。** 追跡の印(ArgoCD の `tracking-id`・Helm・
      k3s の `objectset`・owner)の無いオブジェクトは 11 個で、全部 CI が `kubectl apply` で当てる `bootstrap/` のもの。
      例外の `infisical/data-postgresql-0` は StatefulSet の `volumeClaimTemplate` が作り直す。
- [ ] PV データを restic から復元。**手順は [docs/migration-day.md](docs/migration-day.md) の 8**
      (中身は [apps/k8up/README.md](apps/k8up/README.md)「戻し方」。**順番と、`Succeeded` が
      「戻った」の意味ではないこと**が要点。2026-09-08 に実際に流して確認済み)。
- [ ] Infisical → operator → 各アプリの順で疎通確認。DNS(cloudflare-ddns)、netbird、AdGuard の公開リゾルバを確認。
- [ ] **PT3**: 上流 PR が間に合わなければ KubeVirt にパススルーして tuner-agent だけ VM で動かす
      ([docs/decisions.md](docs/decisions.md)「PT3 チューナー」)。

### 用意が済んだもの

- **`talos/secrets.yaml`(クラスタの CA 一式)と `talos/registries.yaml`(2026-09-08)。** 無いと `render.sh` が
  動かず、private なイメージは全部 `ImagePullBackOff` になる。registries は 2026-09-15 に ghcr.io の PAT から
  fj.doany.io の資格情報に作り直した([talos/README.md](talos/README.md))。k3s の registries.yaml は役目を終える。
- **k3s の組み込みアドオンのうち Talos に無いもの(2026-09-08)。** `kubectl -n kube-system get addons.k3s.cattle.io` で洗い出した。
  - **local-path-provisioner** … 無いと **PVC が 1 つも bind しない**。[talos/manifests/local-path.yaml](talos/manifests/local-path.yaml)
    (`local-path-storage` の PSA ラベルもここ)。置き場は **`/var/mnt/local-path`(専用パーティション。
    [talos/patches/volumes.yaml](talos/patches/volumes.yaml))**。**ディスクの割り方は入れ直さないと変えられない**ので、焼く前に確定させること
  - **metrics-server** … 無いと `kubectl top` と各 UI の使用量表示が消える(HPA は 0 個)。
    [talos/metrics-server-values.yaml](talos/metrics-server-values.yaml)。**`--kubelet-insecure-tls` が要る**(Talos の kubelet は自己署名)
  - coredns は Talos が入れる。ccm と rolebindings は k3s 固有。k3s の RuntimeClass 10 個はどの Pod も使っていない。
    クラスタスコープのもの(APIService・PriorityClass・IngressClass・webhook)も数え直し、残っていたのは下の Gateway API の CRD だけ
- **Gateway API の CRD を自分で入れる(2026-09-08)。** いま入っているのは消した Traefik の `traefik-crd` chart が
  置いていったもので、**Talos には無い。** 無いと `Gateway` も `HTTPRoute` も適用できず**公開経路が丸ごと消える**
  (Cilium の chart は CRD を同梱しない)。[talos/render.sh](talos/render.sh) が `KubeExternalManifestConfig` で
  URL を渡す。版は [talos/versions.yaml](talos/versions.yaml)。
- **起動順序(2026-09-08)。** k3s の `HelmChart` CRD は Talos に無いので、[talos/render.sh](talos/render.sh) が
  bootstrap 層を全部 `helm template` して inlineManifest にする(値はどこにも写さない。CI も同じ `render.sh` を使う)。
  **本物の値で焼いたドリルで `apply-config` 1 回で全部立ち上がった**([docs/talos.md](docs/talos.md)「ブートドリル 4 回目」)。
  層の分け方と根拠は [docs/decisions.md](docs/decisions.md)「Talos の起動順序をどう組むか」、
  **`upgrade-k8s` の前には必ず描き直す**こと(古い machine config だと走っているものが巻き戻る)は
  [talos/README.md](talos/README.md)「上げ方 / 当て直し方」。
- **ファイルの PVC バックアップを k8up に寄せた(2026-09-08)。** ホストの `k3s-backup` は Talos にシェルが無いので
  持っていけない。全 namespace で成功を確認済み。切り分けは [apps/k8up/README.md](apps/k8up/README.md)。
  ホストのスクリプトを畳むのは Talos に移る時点。
- **`local-path-retain` を消した(2026-10-05、k3s のうちに)。** 28 本の PVC を止めて作り直した。**データはコピーしていない** ──
  PV の reclaim を `Retain` にして古い PVC を消し、PV の `claimRef` を外して `storageClassName` を `local-path` に書き換え、
  新しい PVC を `volumeName` で同じ PV に結んだ(使い捨ての PVC で先に確かめた)。あわせて denpa の録画の PVC を
  `denpa-recorded` → `denpa-raw`、`denpa-library` → `denpa-encoded` に改名。PV を使い回したので**ホスト上のディレクトリ名は
  改名前のまま**(Talos で引き直せば揃う)。PR は gitops と ashi#89 / blog#123 / lgtm#56 / xool#159 / yuzuriha#19 /
  todoroku#342 / worklog-cloud#142 / denpa#430。
- **改名前の録画のスナップショットを消した(2026-10-05)。** 新パスの 1 本目(`8a2c927b`)を取ってから旧パスの `539a08ac` を
  forget → prune。**49.4 GiB 解放、88.6 → 37.3 GiB**、`restic check` はエラー無し。旧スナップショットにだけあった
  3 話分(ライブラリから削除済み)は戻せなくなった ── 1 世代の方針どおり。
- **git と実機の helm 値が一致していることを確認(2026-09-08)、argocd と infisical の chart の版を固定**
  (argo-cd 10.8.1 / infisical-standalone 1.10.0)。手順と注意は [bootstrap/README.md](bootstrap/README.md)。
- **見直しで漏れを 3 つ塞いだ(2026-10-05)。** どれも 09-08 のドリルより後に足したものか、ドリルが通らない経路だった。
  - **CI の CA が k3s のままだった。** `bootstrap/apiserver/ca.crt` は k3s の CA で Talos の CA とは別物。当日の 6 で
    `bootstrap-apply` が TLS で落ち、nodePort 80/443 の当て直しも走らず公開経路が戻らないところだった。両方を 1 ファイルに入れた
    (移行後に k3s のぶんを消す。migration-day の 10)
  - **Forgejo を戻すまで ApplicationSet が丸ごと止まる。** gitea の generator が失敗すると ApplicationSet は GitHub 側も含めて
    Application を 1 本も作らない(argo-cd の `applicationset_controller.go`)。まっさらなクラスタでは抜けられない詰まり方だった。
    `repos` と `repos-forgejo` に分け、migration-day の 7 に「Forgejo を Infisical の次に戻す」を足した
  - **cilium-drift が Talos で毎週偽の FAILED を出す。** `talos/cilium-values.yaml` を重ねないと `cgroup-root` が必ず
    食い違う。サーバの版で k3s / Talos を見分けて重ねるようにした

## Phase 3 — Talos 定常運用

- [ ] **etcd スナップショットの定期化。用意は済んだ(2026-10-05)** ── 移行後に
      `talos/after-migration/etcd-snapshot.yaml` を `apps/k8up/` へ移すだけ(migration-day の 10)。
      Talos の `kubernetesTalosAPIAccess` で **`os:etcd:backup` だけ**を k8up の namespace に渡し
      (`talos/patches/etcd-backup.yaml`。`os:admin` の talosconfig を Secret に置く案はやめた)、
      日次で同じ restic リポジトリへ(`--host etcd`)。**戻すときの主経路は git からの再構築のまま**で、
      こちらは近道(docs/talos.md「etcd スナップショットからの復旧」)。
- [ ] **いずれ Intel の GPU を足して QSV でエンコードする(2026-10-05 時点では未購入)。** いまの実機には
      QSV が使える GPU が無い(Xeon E5-2696 v4 は内蔵 GPU なし、画面は iLO の Matrox G200 だけ)ので、
      denpa の Pod から見えるのは `card0` だけで `renderD*` が無い。候補は **Intel Arc A310**(ロープロファイル、
      補助電源なし、AV1 のハードウェアエンコード可)。買ったらやること:
      - Talos なら schematic に **`siderolabs/i915`** を足す(新しい世代の Arc B シリーズなどは `siderolabs/xe`。
        **両方は入れない** ── 同じ GPU を取り合う)。schematic を変えたら `talos/versions.yaml` の ID と depName を差し替え、
        `talosctl upgrade` で当てる(ISO は焼き直さなくてよい)
      - `talosctl ls /dev/dri` に `renderD128`、`talosctl dmesg` に GuC / HuC の読み込みが出ること
      - **denpa 側は何もしなくてよい。** イメージの ffmpeg は QSV / VA-API 入りで、chart は `/dev/dri` をマウント済み
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

- **k8up の失敗通知(2026-09-08)。** [apps/k8up/notify.yaml](apps/k8up/notify.yaml) の CronJob が日次で Matrix の
  `server` の部屋に投げる。考え方は [apps/k8up/README.md](apps/k8up/README.md)「失敗したときに気づけるようにする」。
  `restic check` も [schedules.yaml](apps/k8up/schedules.yaml) に 1 本ある。
- **R2 のずれ検知(2026-10-05)。** 初回から「一致」。容量の推移と、録画をホストのスクリプトから外して
  `restic rewrite` で抜いた件は [docs/decisions.md](docs/decisions.md)「バックアップに何を含めるか」。
- **`talosctl upgrade` / `upgrade-k8s` の手順(2026-09-08)。** [talos/README.md](talos/README.md)「上げ方 / 当て直し方」。
  `upgrade-k8s` は inlineManifests の reconcile も兼ねるので、Talos 期の「bootstrap 層を当て直す」操作でもある。
- **通信の可視化は Hubble で足りている(2026-09-07、`hl.doany.io`。認証は oauth2-proxy 前段)。**
  「何がインターネットに出ているか」の一枚は作らない(2026-09-09 判断)。`kubectl get httproute,grpcroute -A` が正確で早い。

## 済んだこと(記録)

1 行ずつ。詳しいことはリンク先にある。

- **Phase 0 — k3s のまま restic 化(2026-09-06)。** `backup/k3s-backup` + systemd timer(毎日 04:00 JST)で
  R2 の `doany-restic` へ、復元は `recovery/restore.sh` + `recovery/env.age`(パスフレーズ 1 つで戻る)。
  repo 内の秘密は SOPS + age。リハーサル 2 回([docs/restore-drill.md](docs/restore-drill.md))。
  ghcr の pull 認証をノード単位にして `imagePullSecrets` を全廃(decisions.md「ghcr の pull 認証」)。
  旧方式(tar + rclone の `backup.sh` / `init.sh` / `setup-network.sh`)は削除済み。
- **Phase 0.5 — `k3s/` を `deploy/` に改名(2026-09-06)。** 8 repo(denpa#66、lgtm#17、blog#20、yuzuriha#8、
  tamasagashi#63、worklog-cloud#106、xool#128、k3s-gitops#2)、`k3s-gitops` は `gitops` に改名、
  ApplicationSet は `deploy/argocd.yaml` だけを見る。
- **Phase 1 — Talos の検証(2026-09-06〜07、本番に触らない)。** QEMU で v1.14.0 の起動・inlineManifests・
  デュアルスタック・etcd スナップショットからの復旧まで([docs/talos.md](docs/talos.md))。talhelper をやめて
  `talosctl gen config` + パッチに。実機固有の確認(ドライバ、bond、静的 IPv6、`accept_ra: "2"`、wireguard)は
  docs/talos.md「VM ブートドリル」。PSA のラベル(baseline は hostPort も弾く)は docs/talos.md「PSA のラベル」。
  アプリ層の HelmChart CRD を ArgoCD の Application に移した(decisions.md「HelmChart CRD から ArgoCD の Application へ」)。
  k8up を入れて論理バックアップを寄せた([apps/k8up/README.md](apps/k8up/README.md))。
- **Phase 1.5 — k3s のまま Cilium + Gateway API に寄せた(2026-09-06〜07)。** CNI 交換 → ServiceLB をやめて hostPort →
  cert-manager と Gateway → 切り替え本番 → Traefik 撤去 → Gateway を hostNetwork に。**Talos で後から替えるのが
  高いのは CNI だけ**なので先に済ませた。経緯・詰まった点・障害(AdGuard の DoH)は
  decisions.md「ルーティングの選定」以下。Traefik を消した時点で切り戻しの道は閉じている。
- **Phase 1.7 — 運用まわり(2026-09-07)。** Cilium の Helm 値を git に入れた(ConfigMap の直接編集が Helm に残っておらず、
  素の `helm upgrade` で公開 Web が全部落ちる状態だった。[bootstrap/cilium/README.md](bootstrap/cilium/README.md))。
  Entra の認可をアプリロールにして redis を廃止([docs/entra.md](docs/entra.md))。依存更新の自動マージの範囲
  (decisions.md「依存の更新をどこまで自動で入れるか」)。Talos の更新は**検知は自動、適用は手動**
  ([talos/versions.yaml](talos/versions.yaml))。R2 の無料枠超過の原因を除外(decisions.md「バックアップに何を含めるか」)。
- **復元リハーサルで出た宿題(2026-09-07〜08、全部片付いた)。** Cilium 構成での再実施は 3 問とも Yes
  ([docs/restore-drill.md](docs/restore-drill.md))。`Schedule` に `SkipDryRunOnMissingResource=true`
  (apps/k8up/README.md「CRD がまだ無いクラスタで apps を止めないこと」)。`k8up-global` は `restore.sh` が作り直し、
  Talos 用には Infisical の `/k8up/k8up-global` に移した([apps/k8up/k8up-secrets.yaml](apps/k8up/k8up-secrets.yaml))。
- **PVC を守る仕掛けをやめた(2026-09-07、`local-path-retain` の撤去は 2026-10-05)。** decisions.md「PVC を守る仕掛けをやめた」。
