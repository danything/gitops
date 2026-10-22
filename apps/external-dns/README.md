# external-dns

**Cloudflare を通さないアプリの DNS レコードを、アプリの HTTPRoute から作る**([ExternalDNS](https://github.com/kubernetes-sigs/external-dns))。

## 方針

**Cloudflare を通すのが基本**(2026-10-22 から。それまでは逆で、通すものに注釈を付けていた)。

| アプリ | DNS | すること |
| --- | --- | --- |
| ほとんど(**Cloudflare を通す**) | `*.doany.io` のワイルドカード(proxied。`pulumi/dns.ts`) | 何もしない |
| 遅延・通信量・Cloudflare が通さないもの(**直接つなぐ**) | ExternalDNS が作る proxied ではない CNAME(→ `doany.io`) | アプリのリポジトリの HTTPRoute に注釈を付ける |

```yaml
metadata:
  annotations:
    external-dns.kubernetes.io/cloudflare-proxied: "false"
```

**gitops 側には何も書かない。** アプリを足すのも消すのも、アプリのリポジトリの PR だけで済む(疎結合)。
注釈を外すか HTTPRoute を消せば、レコードも消えてワイルドカード(Cloudflare 経由)に戻る(`policy: sync`)。
前の方針の名残の `"true"` が付いていても拾わない(ワイルドカードで Cloudflare を通るので同じ)。

### 直接つなぐもの

| 名前 | 理由 | どこで |
| --- | --- | --- |
| `nb` | WireGuard の UDP と、つなぎっぱなしの gRPC。管理画面だけ分けても、IdP・API・relay が同じ名前なので得が無い | `apps/netbird/httproute.yaml` |
| `ah` | 同じ名前で DoT の 853 | `apps/adguardhome/httproute.yaml` |
| `fj` | コンテナイメージの大きな層の push が、無料プランの 100MB の上限に当たる | `apps/forgejo/httproute.yaml` |
| `lk` | 通話の合図の WebSocket。音声と映像は 8443 で IP に直接来る | `apps/matrix/httproute.yaml` |
| `dp` / `dp.l` | 映像の配信と遅延。住所の判定が接続元の IP に頼る | denpa のリポジトリ |
| `ks` | API サーバ。6443 は Cloudflare が通さない | `pulumi/dns.ts`(HTTPRoute が無い) |
| `px` | 3proxy。hostPort の 3129 | `pulumi/dns.ts` |
| `*.s` | 2 段の名前。無料の証明書は 1 段(`*.doany.io`)しか守れない | `pulumi/dns.ts` |
| `md` | mado。別の家(JCOM 側)の IP | `pulumi/dns.ts` |

**2 段の名前(`x.y.doany.io`)を新しく作るときは、必ず直接つなぐ側にする。** Cloudflare を通すと TLS が壊れる。

### Cloudflare を通すときに知っておくこと

- **オリジンの IP は隠れない。** 直接つなぐ名前と apex が同じ IP を指しているので、得られるのは端での防御(DDoS・WAF)とキャッシュ・集計まで
- アプリから見える接続元は Cloudflare の IP。本当の接続元は `CF-Connecting-IP`(Rybbit は自分で読む)
- 応答が 100 秒を超えると 524、リクエストの本文は 100MB まで(無料プラン)
- SSL は Full (strict)(`pulumi/dns.ts` の zone 設定)。Gateway の Let's Encrypt の証明書で足りる
- NetBird につないでいる端末は、NetBird の DNS(`pulumi/netbird.ts`)で `*.doany.io` を 10.0.0.2 に引くので Cloudflare を通らない

## 触るもの・触らないもの

ExternalDNS は**自分が作ったレコードにしか触れない**。作ったレコードの隣に所有の印の TXT
(`_externaldns.<名前>`、owner は `doany`)を置いて見分ける。

- 触らない:メール(MX・SPF・DMARC・`autodiscover`)、`*.doany.io`・`ks`・`px`・`*.s`・`md`(Pulumi)、apex の A / AAAA(DDNS。`apps/cloudflare-ddns`)、
  GitHub の確認用の TXT
- **印の無い既存のレコードは上書きしない。** 手で作った CNAME を ExternalDNS に移すときは、先に手のレコードを消す
  (消している間もワイルドカードで引けるので、止まらない。Cloudflare を通らない時間が 1 分ほどあるだけ)

## 鍵

Cloudflare の Account API token「external-dns (doany.io DNS write)」。権限は **`doany.io` のゾーンだけの Zone Read + DNS Write**。
Infisical `/external-dns/external-dns` の `cloudflare-api-token`。

