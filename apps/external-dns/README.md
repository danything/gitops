# external-dns

**Cloudflare を通すアプリの DNS レコードを、アプリの HTTPRoute から作る**([ExternalDNS](https://github.com/kubernetes-sigs/external-dns)。2026-10-06)。

## 方針

| アプリ | DNS | すること |
| --- | --- | --- |
| 社内用・通信量が多い(**直接つなぐ**) | `*.doany.io` のワイルドカード(proxied ではない) | 何もしない |
| SaaS のように外へ出す(**Cloudflare を通す**) | ExternalDNS が作る proxied の CNAME(→ `doany.io`) | アプリのリポジトリの HTTPRoute に注釈を付ける |

```yaml
metadata:
  annotations:
    external-dns.kubernetes.io/cloudflare-proxied: "true"
```

**gitops 側には何も書かない。** アプリを足すのも消すのも、アプリのリポジトリの PR だけで済む(疎結合)。
注釈を外すか HTTPRoute を消せば、レコードも消える(`policy: sync`)。

## 触るもの・触らないもの

ExternalDNS は**自分が作ったレコードにしか触れない**。作ったレコードの隣に所有の印の TXT
(`_externaldns.<名前>`、owner は `doany`)を置いて見分ける。

- 触らない:メール(MX・SPF・DMARC・`autodiscover`)、`*.doany.io`、apex の A / AAAA(DDNS。`apps/cloudflare-ddns`)、
  GitHub の確認用の TXT
- **印の無い既存のレコードは上書きしない。** 手で作った CNAME を ExternalDNS に移すときは、先に手のレコードを消す
  (消している間もワイルドカードで引けるので、止まらない。Cloudflare を通らない時間が 1 分ほどあるだけ)

## 鍵

Cloudflare の Account API token「external-dns (doany.io DNS write)」。権限は **`doany.io` のゾーンだけの Zone Read + DNS Write**。
Infisical `/external-dns/external-dns` の `cloudflare-api-token`。

## 移した記録

| ホスト | アプリ | 移した日 |
| --- | --- | --- |
