# mta-sts

doany.io 宛てのメールの、**サーバーどうしの通信を守る** 2 つの仕組み。どちらも「途中で平文に落とされる・偽の
サーバーに渡される」のを防ぐ。2026-10-07 に入れた。

| 仕組み | 何で守るか | 在処 |
| --- | --- | --- |
| **MTA-STS**(RFC 8461) | 「Exchange の MX に、正しい証明書の TLS で送ること」という方針を HTTPS で配る | 方針ファイルはここ([mta-sts.yaml](mta-sts.yaml))、`_mta-sts` の TXT は [../../pulumi/dns.ts](../../pulumi/dns.ts) |
| **DANE**(RFC 7672) | MX の証明書を DNSSEC で署名した TLSA で示す | Exchange Online が TLSA を持つ。こちらは MX を新しい形式にするだけ(dns.ts) |
| TLS-RPT(RFC 8460) | 上の 2 つで失敗した送り手から、毎日の集計が info@ に届く | `_smtp._tls` の TXT(dns.ts) |

## 方針を変えるとき

今は **enforce**(max_age 1 週間)。**MX を変えるときは、先に testing に戻して id を変え、1 週間待つ**(enforce のまま
MX を替えると、古い方針を覚えている送り手が新しい MX に送らなくなる)。


1. [mta-sts.yaml](mta-sts.yaml) の `mta-sts.txt` を直し、`mta-sts/policy-rev` を上げる
2. dns.ts の `_mta-sts` の `id` を変える(今の UTC の時刻など)。**変えないと送り手は古い方針を使い続ける**

## DANE への切り替え(2026-10-07 に済んだ。Microsoft の手順。learn.microsoft.com の「How SMTP DANE works」)

MX を `doany-io.mail.protection.outlook.com` から、DNSSEC に対応した `…mx.microsoft` に替え、Exchange 側で DANE を
有効にする。受信を止めないよう、MX の TTL を下げてから新旧を並べて入れ替える。MTA-STS はそのあいだ testing にする。

1. MX の TTL を 60 秒にし、前の TTL(1 時間)が切れるのを待つ
2. `Enable-DnssecForVerifiedDomain -DomainName doany.io` → 新しい MX の値が返る
3. 新しい MX(`doany-io.o-v1.mx.microsoft`)を優先度 0、古い MX を予備の 30 にする。MTA-STS の `mx` を新しいものに替える(testing のまま)
   - 手元からは 25 番ポートに出られないので、Gmail から info@ への試験のメールで受信を確かめた
4. 古い MX を消し、TTL を 3600 に戻す
5. `Enable-SmtpDaneInbound -DomainName doany.io` → TLSA が出るのを確かめる(15〜30 分)
6. MTA-STS を enforce にし、`max_age` を 1 週間に、`id` を変える
