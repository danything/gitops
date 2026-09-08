# cilium

**クラスタの土台。** CNI・kube-proxy の代替・Gateway API を全部これが担う。
決定の経緯は [../../docs/decisions.md](../../docs/decisions.md)「ルーティングの選定」。

## 入れ方

Argo CD は同期しない(`bootstrap/` は対象外)。手で当てる。

```shell
helm repo add cilium https://helm.cilium.io
helm upgrade --install cilium cilium/cilium --version "$(yq -r .version version.yaml)" \
  --namespace kube-system -f values.yaml
```

版は [version.yaml](version.yaml) が唯一の出どころ(Renovate がここを追う)。

## **`helm upgrade` の前に必ず [values.yaml](values.yaml) を読むこと**

過去に ConfigMap を直接いじって当てた設定があり、**素で `helm upgrade` すると黙って元に戻る。**
いま `values.yaml` が「あるべき値」で、**どの設定が何のために要るかも経緯も
そのファイルのコメントにある**(ここには写さない ── 二重に持つと必ず片方が腐る)。
**以後は ConfigMap を直接いじらず、あちらを直して `helm upgrade` する。**

## **`helm upgrade` のたびに Hubble の証明書が入れ替わる**

チャートの `hubble/tls-helm/*` は毎回 `genCA` / `genSignedCert` で作り直す
(テンプレートに `cilium.io/helm-template-non-idempotent: "true"` が付いている)。
つまり **値を 1 行も変えない `helm upgrade` でも、`hubble-ca-secret` /
`hubble-server-certs` / `hubble-relay-client-certs` の 3 つは差分として出る。**

実害は無い(2026-09-07 に確認)。エージェントも Relay もマウントしたファイルを
見張っていて入れ替わりに追従するので、**Pod の再起動は要らない**。
`cilium-dbg status` の `Hubble: Ok` と `hubble-relay` の Ready で確かめる。

**差分を見るときはここを読み飛ばす。** 中身のある変更だけ見たいなら:

```shell
helm get manifest cilium -n kube-system > /tmp/before.yaml
helm upgrade cilium cilium/cilium --version 1.20.1 -n kube-system -f values.yaml --dry-run \
  | sed -n '/^MANIFEST:/,$p' | tail -n +2 > /tmp/after.yaml
diff -u /tmp/before.yaml /tmp/after.yaml | grep -E '^[+-][^+-]' | grep -vE 'ca\.crt|tls\.(crt|key)'
```

## ズレは CI が見ている

**当てるのは人だが、当て忘れとクラスタ側の直接編集は
[../../.github/workflows/cilium-drift.yml](../../.github/workflows/cilium-drift.yml) が見つける。**
`values.yaml` から ConfigMap を描いて live と突き合わせるだけで、**読むだけ**(権限は
`cilium-config` の `get` 1 つ)。`bootstrap/cilium/**` を触ったときと毎週月曜に走る。

**Talos に移っても `helm upgrade` は使える。** 初回は machine config の `inlineManifests` で
入れることになるが、あれは「作りっぱなし」ではなく **`talosctl upgrade-k8s` を通せば更新も
削除もされる**(2026-09-08 に VM で実測。../../docs/talos.md)。つまり machine config だけで
回す道もあるが、**値が SOPS 済みの machine config に埋まって Renovate が追えなくなる**ので、
ここ(`values.yaml`)を正本にしたまま `helm upgrade` を続ける。

**`helm upgrade` そのものは自動化しない。** ClusterRole / ClusterRoleBinding / Secret /
DaemonSet の書き込みが要り、**ClusterRoleBinding を書けるということは自分に何の権限でも
足せるということ**で、実質 cluster-admin を公開リポジトリの OIDC 主体に渡すことになる。
Talos に移ると cilium は inlineManifests になって `helm upgrade` 自体を使わなくなるので、
そこに手をかけても捨てることになる。

## 当てたあとに確認すること

```shell
# ホストのポートが張られているか(eBPF なので ss には出ない)
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | grep -i hostport
# Gateway のリスナーが載っているか(住所はノードの IP になる)
kubectl -n kube-system get gateway doany
```
