// doany.io の DNS のうち、ExternalDNS が作らないもの(メール・ワイルドカード・ドメインの確認)と、ゾーンの設定。
//
// アプリごとの名前は ExternalDNS がアプリの HTTPRoute から作る(apps/external-dns/)。ここには書かない。
// apex の A / AAAA は cloudflare-ddns が家の IP に合わせて書き換えるので、ここでは持たない(apps/cloudflare-ddns/)。
// 既存のレコードは import で取り込んだ(2026-10-07。取り込み済みなら何もしない)。

import * as cloudflare from "@pulumi/cloudflare";

const zoneId = process.env.CLOUDFLARE_ZONE_ID;
if (!zoneId) throw new Error("CLOUDFLARE_ZONE_ID が要る");

const record = (key: string, args: Omit<cloudflare.DnsRecordArgs, "zoneId">, importId?: string) =>
  new cloudflare.DnsRecord(key, { zoneId, ...args }, importId ? { import: `${zoneId}/${importId}` } : undefined);

// --- Web ---------------------------------------------------------------------------------------
// 直接つなぐアプリ(社内用・重いもの)は全部これで家に来る。Cloudflare を通すアプリは ExternalDNS が
// 個別の名前を作って上書きする(docs/decisions.md「DNS: 直接つなぐアプリと Cloudflare を通すアプリ」)
record("wildcard", { name: "*.doany.io", type: "CNAME", content: "doany.io", proxied: false, ttl: 1 }, "22d196005f64645eca6bccefd4e3fdee");

// 証明書を出してよい認証局。cert-manager が使う Let's Encrypt だけ。Cloudflare の Universal SSL の認証局は
// Cloudflare が自分で足すので書かない
record("caa-issue", { name: "doany.io", type: "CAA", ttl: 1, data: { flags: 0, tag: "issue", value: "letsencrypt.org" } });
record("caa-issuewild", { name: "doany.io", type: "CAA", ttl: 1, data: { flags: 0, tag: "issuewild", value: "letsencrypt.org" } });

// --- メール(Exchange Online)----------------------------------------------------------------------
// DANE のために MX を新しい形式(…mx.microsoft)へ移している途中(apps/mta-sts/README.md「DANE」)。
// Microsoft の手順どおり、切り替えのあいだは TTL を最小(Cloudflare は 60 秒)にしておく
record("mx", { name: "doany.io", type: "MX", content: "doany-io.mail.protection.outlook.com", priority: 0, ttl: 60 }, "6c7e6af1e5665b444b03f40253df2090");
record("autodiscover", { name: "autodiscover.doany.io", type: "CNAME", content: "autodiscover.outlook.com", proxied: false, ttl: 3600 }, "93eb5f05c05d9ca6ae8239cad26089e2");
// 送るのは Exchange だけ(アプリも smtp.office365.com 経由)。以前あった a:b.doany.io は、ワイルドカード経由で
// 家の IP を許していたので外した。送り元は Exchange だけなので -all(2026-10-07)
record("spf", { name: "doany.io", type: "TXT", content: "v=spf1 include:spf.protection.outlook.com -all", ttl: 3600 }, "05522a739cbd45b787b93f1a700b8916");
// DKIM(Exchange Online)。行き先は Get-DkimSigningConfig の Selector1CNAME / Selector2CNAME。
// **明示しないとワイルドカードに吸われて doany.io の TXT(SPF)が返る**(2026-10-07 まではそうだった)
record("dkim-selector1", { name: "selector1._domainkey.doany.io", type: "CNAME", content: "selector1-doany-io._domainkey.doany.q-v1.dkim.mail.microsoft", proxied: false, ttl: 3600 });
record("dkim-selector2", { name: "selector2._domainkey.doany.io", type: "CNAME", content: "selector2-doany-io._domainkey.doany.q-v1.dkim.mail.microsoft", proxied: false, ttl: 3600 });
// なりすましを受け取り側で弾かせる。DKIM(selector1)と SPF が通るのを確かめてから reject にした(2026-10-07。
// Gmail で dkim=pass / spf=pass / dmarc=pass)。集計の報告(rua)は info@ に来る
record("dmarc", { name: "_dmarc.doany.io", type: "TXT", content: "v=DMARC1; p=reject; rua=mailto:info@doany.io", ttl: 1 }, "b1a49318efbb097555b43fede5e26697");

// MTA-STS(RFC 8461)。方針ファイルは apps/mta-sts/。**方針を変えたら id も変える**(送り手は id で取り直す)
record("mta-sts", { name: "_mta-sts.doany.io", type: "TXT", content: "v=STSv1; id=20261007T0400", ttl: 3600 });
// TLS-RPT(RFC 8460)。送り手が MTA-STS / DANE で失敗したら、毎日の集計が info@ に届く
record("tls-rpt", { name: "_smtp._tls.doany.io", type: "TXT", content: "v=TLSRPTv1; rua=mailto:info@doany.io", ttl: 3600 });

// --- ドメインの確認 ---------------------------------------------------------------------------------
// Google Search Console(2 つとも確認に使われている。消すと確認が外れる)
record("google-site-verification-1", { name: "doany.io", type: "TXT", content: '"google-site-verification=WTZR-5D4XdnLy2p52RkTh37Qq6FhUf0XpPV01g6xTew"', ttl: 3600 }, "118ba3db9a2ea182ad55d806268be3cd");
record("google-site-verification-2", { name: "doany.io", type: "TXT", content: "google-site-verification=py7V3FVpxDREahHV8QWIHKhJMU8hVUGVwHznj-HRiCU", ttl: 3600 }, "4465983a89e131cf6be2170696ac44f8");
// GitHub の組織 danything のドメインの確認
record("github-verification", { name: "_gh-danything-o.doany.io", type: "TXT", content: '"f39e74c26c"', ttl: 1 }, "71200b09aa051711661e46f5f2e95b60");

// --- ゾーンの設定(Cloudflare を通す名前にだけ効く)-----------------------------------------------
// 設定は「取り込み」ではなく「書く」(PATCH なので、取り込まなくても同じ)。security_header を import すると
// プロバイダー(cloudflare 6.22)が nil pointer で落ちる(2026-10-07)
const setting = (settingId: string, value: unknown) =>
  new cloudflare.ZoneSetting(`setting-${settingId}`, { zoneId, settingId, value });

setting("ssl", "strict");
setting("always_use_https", "on");
// 1.0 / 1.1 は今使う理由が無い(既定のままだった)
setting("min_tls_version", "1.2");
// HSTS。以前は有効なのに max-age が 0 で、実際には効いていなかった。サブドメインは含めない
// (直接つなぐアプリは家の Gateway が応答するので、ここの設定は届かない)。preload もしない
setting("security_header", {
  strict_transport_security: { enabled: true, max_age: 31536000, include_subdomains: false, preload: false, nosniff: true },
});
