# cilium

**クラスタの土台。** CNI・kube-proxy の代替・Gateway API を全部これが担う。
決定の経緯は [../../docs/decisions.md](../../docs/decisions.md)「ルーティングの選定」。

## 入れ方

Argo CD は同期しない(`bootstrap/` は対象外)。手で当てる。

```shell
helm repo add cilium https://helm.cilium.io
helm upgrade --install cilium cilium/cilium --version 1.20.1 \
  --namespace kube-system -f values.yaml
```

## **`helm upgrade` の前に必ず [values.yaml](values.yaml) を読むこと**

過去に ConfigMap を直接いじって当てた設定があり、**素で `helm upgrade` すると黙って元に戻る。**
いま `values.yaml` が「あるべき値」で、**どの設定が何のために要るかも経緯も
そのファイルのコメントにある**(ここには写さない ── 二重に持つと必ず片方が腐る)。
**以後は ConfigMap を直接いじらず、あちらを直して `helm upgrade` する。**

## 当てたあとに確認すること

```shell
# ホストのポートが張られているか(eBPF なので ss には出ない)
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | grep -i hostport
# Gateway のリスナーが載っているか(住所はノードの IP になる)
kubectl -n kube-system get gateway doany
```
