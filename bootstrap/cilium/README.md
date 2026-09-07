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

## 当てたあとに確認すること

```shell
# ホストのポートが張られているか(eBPF なので ss には出ない)
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | grep -i hostport
# Gateway のリスナーが載っているか(住所はノードの IP になる)
kubectl -n kube-system get gateway doany
```
