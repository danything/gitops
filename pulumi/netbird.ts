// NetBird (https://nb.doany.io、apps/netbird/) の設定。**ここが正本。** 2026-10-07 に画面で作ってあったものを import で取り込んだ。
//
// 持っているのは DNS (ネームサーバー・ゾーン・レコード)、ネットワーク (自宅の LAN への経路)、exit ノードのルート、
// アクセスのポリシー。**持っていないもの:** グループ (所属するピアはセットアップキーやログインで変わるので、
// ここでは ID で指すだけ)、ピア、ユーザー、セットアップキー、アカウントの設定。
//
// 鍵は state に入れない。provider は環境変数 NB_PAT を読む (PR は PREVIEW_NB_PAT = Auditor、main は NB_PAT = Admin。
// どちらもサービスユーザーのトークン。README.md「NetBird」)。

import * as netbird from "@pulumi/netbird";

const provider = new netbird.Provider("doany", { managementUrl: "https://nb.doany.io" });
const opts = (importId: string) => ({ provider, import: importId });

// --- グループとピア (持たない。ID で指す) ------------------------------------------------------------
const ALL = "daf7c8f13kb0009ahae0";
const USERS = "daf7f7n13kb0009ahclg";
const ROUTING_PEERS = "daf7f7n13kb0009ahcng";
// クラスタの routing peer (apps/netbird/routing-peer.yaml)。自宅 LAN の入口で exit ノード
const PEER_MAIN = "daf7pp713kb0009ahhjg";

// --- DNS --------------------------------------------------------------------------------------------
// 全部の名前を自宅の AdGuard Home (main の hostPort 53) で引く。広告ブロックもここで効く
new netbird.NameserverGroup(
  "adguard",
  {
    name: "adguard",
    description: "AdGuard Home (main の hostPort 53)",
    nameservers: [{ ip: "10.0.0.2", nsType: "udp", port: 53 }],
    groups: [ALL],
    primary: true,
    domains: [],
    enabled: true,
    searchDomainsEnabled: false,
  },
  opts("daf842v13kb0009ahnvg"),
);

new netbird.DnsSettings("settings", { disabledManagementGroups: [] }, { provider });

// *.doany.io を家の Gateway (10.0.0.2) に向ける。exit ノード越しに家の外向きの IPv4 を引くと、家のルーターで
// 折り返しになって届かないため (2026-10-07)。ゾーンに無い名前 (apex など) は上のネームサーバーに流れる。
// **nb.doany.io だけは外向きのまま。** 内部に向けると、管理サーバーとリレーへの接続が NetBird のトンネル頼みになり、
// 切れたときに戻ってこられない
const zone = new netbird.DnsZone(
  "doany-io",
  { name: "doany.io", domain: "doany.io", enabled: true, enableSearchDomain: false, distributionGroups: [ALL] },
  opts("db2rqbn4p630008pv62g"),
);

const record = (key: string, name: string, type: "A" | "AAAA" | "CNAME", content: string, id: string, extra = {}) =>
  new netbird.DnsRecord(key, { zoneId: zone.id, name, type, content, ttl: 300 }, { ...opts(`db2rqbn4p630008pv62g:${id}`), ...extra });

record("wildcard", "*.doany.io", "A", "10.0.0.2", "db2rtin4p630008pv9qg");
// ワイルドカードは 1 段ぶんしか拾わない (x.s.doany.io は *.doany.io に当たらない)
record("wildcard-s", "*.s.doany.io", "A", "10.0.0.2", "db2rsg74p630008pv8ag");

// nb.doany.io は家の外向きのアドレスを返したい。アドレスは書かず、**2 段の名前 nb.origin.doany.io に CNAME で向ける。**
// 2 段なのでこのゾーンのワイルドカードには当たらず、上のネームサーバー (AdGuard → Cloudflare) で引かれる。
// Cloudflare では *.doany.io が doany.io への CNAME (プロキシなし) で、doany.io は cloudflare-ddns が家の IP に
// 書き換えるので、家の IP が変わっても追従する (IPv4 / IPv6 とも。2026-10-07)。
//
// 2026-10-07 までは nb に A / AAAA を直接書いていた。NetBird は同じ名前に CNAME と A / AAAA を並べられないので、
// AAAA を使っていない名前に移してから (nb-retired) A を CNAME に書き換える。どちらもその場の更新で、消える瞬間は無い。
// nb-retired は次の PR で消す
const nbRetired = record("nb-aaaa", "nb-retired.origin.doany.io", "AAAA", "240f:6d:842b:1::2", "db2rtr74p630008pva2g");
record("nb-a", "nb.doany.io", "CNAME", "nb.origin.doany.io", "db2rtjf4p630008pv9s0", { dependsOn: [nbRetired] });

// --- 自宅の LAN への経路 -------------------------------------------------------------------------------
const NETWORK = "daf7f7n13kb0009ahci0";
const network = new netbird.Network(
  "home",
  { name: "My First Network", description: "Created during onboarding" },
  opts(NETWORK),
);

new netbird.NetworkRouter(
  "home-main",
  { networkId: network.id, peer: PEER_MAIN, masquerade: true, metric: 9999, enabled: true },
  opts(`${NETWORK}/daf80r713kb0009ahkrg`),
);

// リソースは必ず 1 つ以上のグループに入れる (provider の制約。2026-10-07 まではどこにも入っていなかった)。
// アクセスの許可は下のポリシーがリソースを直接指しているので、このグループは今は何にも使っていない。
// peers / resources は書かない (省略すると管理画面の値をそのまま保つ。中身はリソースの側の groups で決まる)
const homeLan = new netbird.Group("home-lan", { name: "Home LAN" }, { provider });

const lan = new netbird.NetworkResource(
  "lan-10-0",
  { networkId: network.id, name: "My Subnet", address: "10.0.0.0/24", description: "Created during onboarding", enabled: true, groups: [homeLan.id] },
  opts(`${NETWORK}/daf7f7n13kb0009ahcjg`),
);
const lan1010 = new netbird.NetworkResource(
  "lan-10-10",
  {
    networkId: network.id,
    name: "lan-10-10",
    address: "10.10.0.0/24",
    description: "もう一方の LAN(eno4)。FAX 複合機 10.10.0.33、Gateway の LB IP 10.10.0.50-55",
    enabled: true,
    groups: [homeLan.id],
  },
  opts(`${NETWORK}/daf86nf13kb0009ahrdg`),
);

// --- exit ノード ----------------------------------------------------------------------------------------
new netbird.Route(
  "exit-node",
  {
    description: "自宅を出口にする(プライバシー)。gitops の docs/decisions.md",
    networkId: "exit-node",
    network: "0.0.0.0/0",
    peer: PEER_MAIN,
    groups: [ALL],
    masquerade: true,
    metric: 9999,
    keepRoute: false,
    skipAutoApply: false,
    enabled: true,
  },
  opts("daf842v13kb0009ahnt0"),
);

// --- ポリシー -------------------------------------------------------------------------------------------
// どれも双方向・全プロトコルの許可で、ルールは 1 本 (ルールの id は provider が持つ読み取り専用の値なので書かない)
const allow = (key: string, id: string, name: string, description: string, rule: Partial<netbird.types.input.PolicyRule>) =>
  new netbird.Policy(
    key,
    { name, description, enabled: true, rules: [{ name, description, action: "accept", bidirectional: true, protocol: "all", enabled: true, ...rule }] },
    opts(id),
  );

const DEFAULT_DESC = "This is a default rule that allows connections between all the resources";
allow("default", "daf7c8f13kb0009ahaeg", "Default", DEFAULT_DESC, { sources: [ALL], destinations: [ALL] });
allow("to-lan-10-0", "daf7f7n13kb0009ahcpg", "Users to My Subnet", "Allows access to this subnet 10.0.0.0/24", {
  sources: [USERS, ALL],
  destinationResource: { id: lan.id, type: "subnet" },
});
allow("to-routing-peers", "daf7f7n13kb0009ahcqg", "Users to Routing Peers", "Allows users to access routing peers", {
  sources: [USERS, ALL],
  destinations: [ROUTING_PEERS],
});
allow("to-lan-10-10", "daf86qf13kb0009ahrh0", "Users to 10.10.0.0/24", "もう一方の LAN(FAX 複合機・Gateway の LB IP)", {
  sources: [USERS, ALL],
  destinationResource: { id: lan1010.id, type: "subnet" },
  // このルールだけ説明が空 (provider は空文字を「無し」として読む)
  description: undefined,
});
