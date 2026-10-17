# cilium

**クラスタの土台。** CNI・kube-proxy の代替・Gateway API を全部これが担う。
決定の経緯は [../../docs/decisions.md](../../docs/decisions.md)「ルーティングの選定」。

## 当て方

Argo CD は同期しない(`bootstrap/` は対象外)。**machine config の inlineManifest に載っている**ので、
[values.yaml](values.yaml) か [version.yaml](version.yaml) を直したら
**`render.sh` → `apply-config` → `upgrade-k8s`**([../../talos/README.md](../../talos/README.md)「上げ方 / 当て直し方」)。
`helm upgrade` は使わない。値はここが正本で、machine config は [../../talos/render.sh](../../talos/render.sh) が
ここから描く派生物(二度書かない。decisions.md「machine config と Cilium の chart をどう連動させるか」)。

**どの設定が何のために要るかは [values.yaml](values.yaml) のコメントにある**(ここには写さない)。
版は [version.yaml](version.yaml) が唯一の出どころ(Renovate がここを追う)。

## 描き直すたびに Hubble の証明書が入れ替わる

チャートの `hubble/tls-helm/*` は毎回 `genCA` / `genSignedCert` で作り直す
(`cilium.io/helm-template-non-idempotent: "true"`)。**値を 1 行も変えなくても、`hubble-ca-secret` /
`hubble-server-certs` / `hubble-relay-client-certs` の 3 つは `upgrade-k8s` の差分に出る。**
実害は無い(エージェントも Relay もファイルの入れ替わりに追従する。Pod の再起動は要らない)。
`cilium-dbg status` の `Hubble: Ok` と `hubble-relay` の Ready で確かめる。

## ズレは CI が見ている

**当て忘れとクラスタ側の直接編集は [../../.github/workflows/cilium-drift.yml](../../.github/workflows/cilium-drift.yml) が見つける。**
`values.yaml` から ConfigMap を描いて live と突き合わせるだけで、**読むだけ**(権限は `cilium-config` の `get` 1 つ)。
`bootstrap/cilium/**` を触ったときと毎週月曜に走る。当てるのは自動化しない(Talos API の os:admin を CI に置かない)。

## 当てたあとに確認すること

```shell
# ホストのポートが張られているか(eBPF なので ss には出ない)
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | grep -i hostport
# Gateway のリスナーが載っているか(住所はノードの IP になる)
kubectl -n kube-system get gateway doany
```
