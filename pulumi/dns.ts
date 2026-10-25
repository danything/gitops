// doany.io の DNS のうち ExternalDNS が作らないものと、ゾーンの設定。
// アプリごとの名前は ExternalDNS、apex の A / AAAA は cloudflare-ddns が持つ。

import * as cloudflare from "@pulumi/cloudflare";

const zoneId = process.env.CLOUDFLARE_ZONE_ID;
if (!zoneId) throw new Error("CLOUDFLARE_ZONE_ID が要る");

const record = (key: string, args: Omit<cloudflare.DnsRecordArgs, "zoneId">, importId?: string) =>
  new cloudflare.DnsRecord(key, { zoneId, ...args }, importId ? { import: `${zoneId}/${importId}` } : undefined);

// --- Web ---------------------------------------------------------------------------------------
// **Cloudflare を通すのが基本。** 名前を足すだけで Cloudflare 経由で家に来る。
// 通さないものは個別に proxied ではないレコードを持つ: HTTPRoute のあるもの(nb・ah・fj・lk・dp など)は
// ExternalDNS が `cloudflare-proxied: "false"` の注釈から作り、無いものは下に明示する(apps/external-dns/README.md)
record("wildcard", { name: "*.doany.io", type: "CNAME", content: "doany.io", proxied: true, ttl: 1 }, "22d196005f64645eca6bccefd4e3fdee");

// Cloudflare を通さない名前のうち、HTTPRoute が無い(= ExternalDNS が作れない)もの。ワイルドカードを proxied に
// するので、明示しないと Cloudflare に吸われる(apps/external-dns/README.md)
//   ks: API サーバ。6443 は Cloudflare が通さないポート(CI の cilium-drift.yml が使う)
//   px: 3proxy。hostPort の 3129 に直接来る
//   *.s: 2 段の名前(bootstrap/auth の sub)。Cloudflare の無料の証明書は 1 段しか守れない
record("ks", { name: "ks.doany.io", type: "CNAME", content: "doany.io", proxied: false, ttl: 1 });
record("px", { name: "px.doany.io", type: "CNAME", content: "doany.io", proxied: false, ttl: 1 });
record("wildcard-s", { name: "*.s.doany.io", type: "CNAME", content: "doany.io", proxied: false, ttl: 1 });

// mado(ブラウザから RDP する入口)。main が落ちたときの入口なので、JCOM 側の PC(固定 IP)に直接来る(docs/router.md)
record("md-a", { name: "md.doany.io", type: "A", content: "61.21.173.41", proxied: false, ttl: 1 });
record("md-aaaa", { name: "md.doany.io", type: "AAAA", content: "2405:1201:5201:3a00::2", proxied: false, ttl: 1 });

// 証明書を出してよい認証局は Let's Encrypt だけ(Universal SSL のぶんは Cloudflare が自分で足す)
record("caa-issue", { name: "doany.io", type: "CAA", ttl: 1, data: { flags: 0, tag: "issue", value: "letsencrypt.org" } });
record("caa-issuewild", { name: "doany.io", type: "CAA", ttl: 1, data: { flags: 0, tag: "issuewild", value: "letsencrypt.org" } });

// --- メール(Exchange Online)----------------------------------------------------------------------
// DNSSEC に対応した MX(Enable-DnssecForVerifiedDomain で払い出された)。DANE はこれで効く
record("mx-dnssec", { name: "doany.io", type: "MX", content: "doany-io.o-v1.mx.microsoft", priority: 0, ttl: 3600 });
record("autodiscover", { name: "autodiscover.doany.io", type: "CNAME", content: "autodiscover.outlook.com", proxied: false, ttl: 3600 }, "93eb5f05c05d9ca6ae8239cad26089e2");
// 送るのは Exchange だけ(アプリも apps/smtp-relay → Graph の sendMail で Exchange から出る)なので -all
record("spf", { name: "doany.io", type: "TXT", content: "v=spf1 include:spf.protection.outlook.com -all", ttl: 3600 }, "05522a739cbd45b787b93f1a700b8916");
// DKIM。行き先は Get-DkimSigningConfig の Selector1CNAME / Selector2CNAME。明示しないとワイルドカードに吸われる
record("dkim-selector1", { name: "selector1._domainkey.doany.io", type: "CNAME", content: "selector1-doany-io._domainkey.doany.q-v1.dkim.mail.microsoft", proxied: false, ttl: 3600 });
record("dkim-selector2", { name: "selector2._domainkey.doany.io", type: "CNAME", content: "selector2-doany-io._domainkey.doany.q-v1.dkim.mail.microsoft", proxied: false, ttl: 3600 });
// 集計の報告(rua)は info@ に来る
record("dmarc", { name: "_dmarc.doany.io", type: "TXT", content: "v=DMARC1; p=reject; rua=mailto:info@doany.io", ttl: 1 }, "b1a49318efbb097555b43fede5e26697");

// MTA-STS(RFC 8461)。方針ファイルは apps/mta-sts/。**方針を変えたら id も変える**(送り手は id で取り直す)
record("mta-sts", { name: "_mta-sts.doany.io", type: "TXT", content: "v=STSv1; id=20261007T0530", ttl: 3600 });
// TLS-RPT(RFC 8460)。送り手が MTA-STS / DANE で失敗したら、毎日の集計が info@ に届く
record("tls-rpt", { name: "_smtp._tls.doany.io", type: "TXT", content: "v=TLSRPTv1; rua=mailto:info@doany.io", ttl: 3600 });

// --- ドメインの確認 ---------------------------------------------------------------------------------
// Google Search Console のドメインの確認。もう 1 つあった WTZR-… は info@doany.io の分で、Search Console が
// 「未使用の所有権トークン」と出した(その持ち主はもう確認済みの所有者ではない)ので 2026-10-25 に外した
record("google-site-verification-2", { name: "doany.io", type: "TXT", content: "google-site-verification=py7V3FVpxDREahHV8QWIHKhJMU8hVUGVwHznj-HRiCU", ttl: 3600 }, "4465983a89e131cf6be2170696ac44f8");
// GitHub の組織 danything のドメインの確認
record("github-verification", { name: "_gh-danything-o.doany.io", type: "TXT", content: '"f39e74c26c"', ttl: 1 }, "71200b09aa051711661e46f5f2e95b60");

// --- ゾーンの設定(Cloudflare を通す名前にだけ効く)-----------------------------------------------
// 取り込まずに書く(PATCH なので同じ。security_header を import するとプロバイダーが nil pointer で落ちる)
const setting = (settingId: string, value: unknown) =>
  new cloudflare.ZoneSetting(`setting-${settingId}`, { zoneId, settingId, value });

setting("ssl", "strict");
setting("always_use_https", "on");
setting("min_tls_version", "1.2");
// HSTS。サブドメインは含めない(直接つなぐアプリにはここの設定が届かない)
setting("security_header", {
  strict_transport_security: { enabled: true, max_age: 31536000, include_subdomains: false, preload: false, nosniff: true },
});
