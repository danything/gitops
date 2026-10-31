// NetBird (https://nb.doany.io) の設定の正本。DNS・ネットワーク・exit ノード・ポリシー・アカウントの設定を持つ。
// グループ (ID で指すだけ)・ピア・ユーザー・セットアップキー・トークン・Entra の IdP は持たない。
// provider は環境変数 NB_PAT を読む (README.md「NetBird」)。

import * as netbird from "@pulumi/netbird";

const provider = new netbird.Provider("doany", { managementUrl: "https://nb.doany.io" });
const opts = (importId: string) => ({ provider, import: importId });

// --- グループとピア (持たない。ID で指す) ------------------------------------------------------------
const ALL = "daf7c8f13kb0009ahae0";
const USERS = "daf7f7n13kb0009ahclg";
const ROUTING_PEERS = "daf7f7n13kb0009ahcng";
// クラスタの routing peer (deploy/netbird/routing-peer.yaml)。自宅 LAN の入口で exit ノード
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

// *.doany.io を家の Gateway に向ける (外向きの IPv4 は家のルーターで折り返せず届かない)。
// nb.doany.io は外向きのまま (内部に向けると、トンネルが切れたときに戻ってこられない)。ほかの例外は下の md・autodiscover
const zone = new netbird.DnsZone(
  "doany-io",
  { name: "doany.io", domain: "doany.io", enabled: true, enableSearchDomain: false, distributionGroups: [ALL] },
  opts("db2rqbn4p630008pv62g"),
);

// id は NetBird の画面で作ったものを取り込んだときの ID。ここで作るものは null
const record = (key: string, name: string, type: "A" | "AAAA" | "CNAME", content: string, id: string | null, extra = {}) =>
  new netbird.DnsRecord(
    key,
    { zoneId: zone.id, name, type, content, ttl: 300 },
    { ...(id ? opts(`db2rqbn4p630008pv62g:${id}`) : { provider }), ...extra },
  );

record("wildcard", "*.doany.io", "A", "10.0.0.2", "db2rtin4p630008pv9qg");
// ワイルドカードは 1 段ぶんしか拾わない (x.s.doany.io は *.doany.io に当たらない)
record("wildcard-s", "*.s.doany.io", "A", "10.0.0.2", "db2rsg74p630008pv8ag");

// 2 段の名前に CNAME で向けると、このゾーンのワイルドカードに当たらず Cloudflare の家の IP に追従する。
// 同じ名前に CNAME と A / AAAA は並べられない。alias は以前のキー (nb-a) を作り直さないため
record("nb", "nb.doany.io", "CNAME", "nb.origin.doany.io", "db2rtjf4p630008pv9s0", { aliases: [{ name: "nb-a" }] });

// 家の Gateway に無い名前は、ワイルドカードに吸われないよう外向きと同じ先を書く (dns.ts と揃える)。
// md.doany.io は JCOM 側の PC の mado (../mado/)。NetBird につないだまま開けなかった (2026-10-30)
record("md-a", "md.doany.io", "A", "61.21.173.41", null);
record("md-aaaa", "md.doany.io", "AAAA", "2405:1201:5201:3a00::2", null);
// Outlook の自動設定 (Microsoft 365)
record("autodiscover", "autodiscover.doany.io", "CNAME", "autodiscover.outlook.com", null);

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

// リソースは 1 つ以上のグループに入れる (provider の制約。許可はポリシーがリソースを直接指すので使っていない)。
// peers / resources は書かない (中身はリソースの側の groups で決まる)
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

// --- アカウントの設定とログイン ------------------------------------------------------------------------
const ACCOUNT = "daf7c8f13kb0009ahad0";
new netbird.AccountSettings(
  "account",
  {
    networkRange: "100.82.0.0/16",
    dnsDomain: "",
    // 新しい利用者は管理者が承認するまで使えない。一般の利用者は他人のピアを見られない
    userApprovalRequired: true,
    regularUsersViewBlocked: true,
    peerApprovalEnabled: false,
    // ログインは 24 時間で切れる。放置での切断はしない
    peerLoginExpirationEnabled: true,
    peerLoginExpiration: 86400,
    peerInactivityExpirationEnabled: false,
    peerInactivityExpiration: 600,
    // Entra のトークンの roles をグループにする機能は使っていない (グループはここでは持たない)
    jwtGroupsEnabled: false,
    jwtGroupsClaimName: "roles",
    jwtAllowGroups: [],
    groupsPropagationEnabled: true,
    lazyConnectionEnabled: true,
    routingPeerDnsResolutionEnabled: true,
    autoUpdateVersion: "disabled",
    networkTrafficLogsEnabled: false,
    networkTrafficPacketCounterEnabled: false,
    peerExposeEnabled: false,
  },
  opts(ACCOUNT),
);

// Entra の IdP は持たない。provider がクライアントシークレットを必須にしていて、共用のアプリ登録の
// シークレットを GitHub に置くことになる (漏れると全部の SSO に及ぶ)。画面で持つ
