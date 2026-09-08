# 移行当日の手順

**この 1 枚を上から順にやる。** 中身の説明は各所にあるので、ここには**順番と、
その場で見るもの**だけ置く。詳しい理由が要るときだけリンクを踏む。

**なぜこの順番か**が要るなら [ROADMAP.md](../ROADMAP.md) の Phase 2 と
[decisions.md](decisions.md)「Talos の起動順序をどう組むか」。

---

## 0. 前日までに

- [ ] `./talos/render.sh /tmp/talos-config` が**手元で通る**
      (`valid for metal mode` まで出ること)
- [ ] 生成物に **inline 9 つ + CRD の URL 5 つ**が入っている
      ([talos/README.md](../talos/README.md)「上げ方 / 当て直し方」)
- [ ] `talos/versions.yaml` の版が意図どおり(**上げるなら今日ではない日に**)
- [ ] **作業中は何も見せない。** 決定済み(ROADMAP の Phase 2)。メンテナンス画面は用意しない

## 1. 経路の確保

- [ ] **LAN(10.0.0.2 / 10.10.0.4)か iLO(10.0.0.3)から作業する。**
      cloudflared 経由の ssh は落ちる
- [ ] iLO にログインできることを**先に**確かめる

## 2. 最終バックアップ

```shell
sudo systemctl start k3s-backup.service     # ホストのぶん
```

- [ ] `restic check` が通る
- [ ] **k8up の 23 系統が 25 時間以内**([apps/k8up/README.md](../apps/k8up/README.md)
      「失敗したときに気づけるようにする」。`notify` の CronJob を手で 1 回回すのが早い)

## 3. machine config を作る

```shell
./talos/render.sh /tmp/talos-config
```

**秘密は 2 つとも repo にある**(`talos/secrets.yaml` / `talos/registries.yaml`)。
`secrets.yaml` を作り直すと**別のクラスタになる**ので触らない。

## 4. 焼く

- [ ] iLO の仮想メディアで **ISO** を起動([talos.md](talos.md)「メディアに載せる」)
- [ ] maintenance mode の IP をコンソールで確認
- [ ] `talosctl get links --insecure -n <IP> -e <IP>` で**インタフェース名が
      `eno1` / `eno2` / `eno4` であること**を確かめる。違ったら
      `talos/patches/cluster.yaml` を直して 3 に戻る

```shell
talosctl apply-config --insecure -n <IP> -f /tmp/talos-config/controlplane.yaml
```

**`UnattendedInstallConfig` があるのでディスクに書かれる。**

## 5. クラスタを起こす

```shell
TC=/tmp/talos-config/talosconfig
talosctl --talosconfig $TC -n 10.0.0.2 -e 10.0.0.2 bootstrap
talosctl --talosconfig $TC -n 10.0.0.2 -e 10.0.0.2 kubeconfig
```

- [ ] `talosctl get volumestatus` に **EPHEMERAL(64GiB 上限)と u-local-path** が出る。
      **ここが違ったら入れ直すしかない**([talos/patches/volumes.yaml](../talos/patches/volumes.yaml))
- [ ] `kubectl get nodes` が **Ready / control-plane / v1.36.2**
- [ ] `kubectl get pods -A` で **cilium・coredns・metrics-server・local-path・
      argocd・cert-manager・infisical** が Running
      (ドリル 4 回目と同じ絵。[talos.md](talos.md))

## 6. 残りの bootstrap/ を当てる

GitHub Actions の **bootstrap apply** を `workflow_dispatch` で回す。

- [ ] `ClusterIssuer`・Gateway・auth・`InfisicalSecret` が入る
- [ ] **SOPS 済みの 4 ファイルは CI が当てない。**
      `infisical/secrets.yaml` と `cert-manager/cloudflare-secret.yaml` は
      **machine config に入っている**ので何もしなくてよい。残り 2 つは chart なので同じ
- [ ] Gateway に証明書が付く(`kubectl get certificate -A`)

## 7. アプリが戻るのを待つ

ArgoCD が `apps/` と各リポジトリの `deploy/argocd.yaml` を同期する。

- [ ] `kubectl -n argocd get applications` が全部 Synced / Healthy
- [ ] **PVC が Bound になる**(`local-path` が要る。5 で確認済み)

**`OutOfSync / Missing` のまま止まっているものは 1 回叩く。** `apps/infisical-operator/`
が CRD を入れる前に同期しにいった Application は `(retried 5 times)` で諦めていて、
**`refresh=hard` では戻らない**(2026-09-08 のドリル 5 回目)。

```shell
kubectl -n argocd patch application <名前> --type=merge \
  -p '{"operation":{"sync":{"revision":"HEAD"},"initiatedBy":{"username":"me"}}}'
```

**Infisical の DB が空のままだと、`InfisicalSecret` を使うアプリは Secret を
もらえない。** 先に 8 で `infisical-postgresql.sql` を戻しておくほうが早い。

## 8. PV データを戻す

**Infisical の DB は 7 より前に戻すと楽。** 空のままだと `InfisicalSecret` を使う
アプリが Secret をもらえず、7 が「全部 Healthy」にならない。

**順番が決まっている。** 手順は [apps/k8up/README.md](../apps/k8up/README.md)「戻し方」。

1. アプリを止める(`kubectl scale deploy/… --replicas=0`)
2. `Restore` を作る。**スナップショット ID を明示する**
3. **中身を見る。** `Succeeded` は「戻った」の意味ではない
4. アプリを戻す

**SQL のダンプは先にロールを作る** ── アプリを普通に起動してから流すのが早い。

## 9. 疎通確認

- [ ] Infisical → operator → 各アプリの `Secret` が埋まる
- [ ] DNS(cloudflare-ddns が A/AAAA を書く)
- [ ] netbird(外から VPN に入れる)
- [ ] AdGuard の公開リゾルバ
- [ ] `*.doany.io` が HTTPS で開く

## 10. 後始末

- [ ] ホストの `k3s-backup` はもう無い(Talos にシェルが無い)。**k8up だけが残る**
- [ ] `bootstrap/storageclass.yaml`(`local-path-retain`)を消す
      ── 再構築で PVC を引き直したこの時だけ消せる(ROADMAP)
- [ ] `talosctl etcd snapshot` を 1 本取って R2 へ

---

## 詰まったときに見るところ

| | |
| --- | --- |
| ノードが上がらない | コンソール(iLO)。ダッシュボードに版と健全性が出る |
| Pod が Pending | **PSA のラベル**([talos.md](talos.md)「Pod Security Admission」)か、control-plane の taint |
| PVC が Bound しない | local-path の ConfigMap に `setup`/`teardown` があるか |
| private イメージが引けない | `talos/registries.yaml` が machine config に入っているか |
| inlineManifest を直したのに効かない | `render.sh` → `apply-config` → **`upgrade-k8s`**。順番が要る |
