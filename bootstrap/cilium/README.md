# cilium

**クラスタの土台。** CNI・kube-proxy の代替・LoadBalancer(LB-IPAM)・Gateway API を全部これが担う。
決定の経緯は [../../docs/decisions.md](../../docs/decisions.md)「ルーティングの選定」。

## 入れ方

Argo CD は同期しない(`bootstrap/` は対象外)。手で当てる。

```shell
helm repo add cilium https://helm.cilium.io
helm upgrade --install cilium cilium/cilium --version 1.20.1 \
  --namespace kube-system -f values.yaml
```

## **`helm upgrade` の前に必ず [values.yaml](values.yaml) を読むこと**

**2026-09-07 まで、この値は git に無かった。** 手で `helm install` した一度きりで入れ、
以後の調整は `cilium-config` の ConfigMap を直接いじって当てていた。その差分は Helm の
リリースに記録されないので、**素で `helm upgrade` すると黙って元に戻る。**

いま `values.yaml` は「あるべき値」になっていて、**どの設定が何のために要るかは
そのファイルのコメントに書いてある**(ここには写さない ── 二重に持つと必ず片方が腐る)。
**以後は ConfigMap を直接いじらず、あちらを直して `helm upgrade` する。**

## 当てたあとに確認すること

```shell
# ホストのポートが張られているか(eBPF なので ss には出ない)
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | grep -i hostport
# Gateway が住所を持っているか
kubectl -n kube-system get svc cilium-gateway-doany
# L2 アナウンス(ConfigMap に入れるだけでは効かない。エージェントの再起動が要る)
kubectl -n kube-system get ciliuml2announcementpolicy
```
