// 共用の Entra のアプリ登録(`b0fa498f-…`)のリダイレクト URI とアプリロール。ほかの設定には触れない。
// アプリを足す・消すときは、そのアプリのマニフェストと同じ PR でここも直す。

import * as azuread from "@pulumi/azuread";

// アプリ登録のオブジェクト ID(アプリケーション ID の b0fa498f-… とは別物)
const APPLICATION_OBJECT_ID = "89e18065-3ead-401f-b2dd-6fd5228e2f75";

// [ホスト, パス, 何のため]。並びはホスト名の順
const WEB_REDIRECTS: [string, string, string][] = [
  ["a.doany.io", "/oauth2/callback", "auth(oauth2-proxy。bootstrap/auth/)"],
  ["ac.doany.io", "/auth/callback", "Argo CD"],
  ["ah.doany.io", "/oauth2/callback", "AdGuard Home の前段(oauth2-proxy)"],
  ["as.doany.io", "/auth/callback", "ashi"],
  ["dp.doany.io", "/login/callback", "denpa"],
  ["fj.doany.io", "/user/oauth2/entra/callback", "Forgejo"],
  ["h.doany.io", "/oidc-callback", "Headlamp"],
  ["hl.doany.io", "/oauth2/callback", "Hubble の前段(oauth2-proxy)"],
  ["m.doany.io", "/_matrix/client/unstable/login/sso/callback/b0fa498f-7e6a-4fe1-a1c6-16fbbb6f397e", "Matrix(Tuwunel)"],
  ["md.doany.io", "/callback", "mado(mado/。このクラスタの外)"],
  ["nb.doany.io", "/oauth2/callback", "NetBird"],
  ["nb.doany.io", "/oauth2/logout/callback", "NetBird(ログアウト)"],
  ["yk.doany.io", "/admin/callback", "yosegaki の管理画面"],
];

new azuread.ApplicationRedirectUris(
  "doany-web",
  {
    applicationId: `/applications/${APPLICATION_OBJECT_ID}`,
    type: "Web",
    redirectUris: WEB_REDIRECTS.map(([host, path]) => `https://${host}${path}`),
  },
  { import: `/applications/${APPLICATION_OBJECT_ID}/redirectUris/Web` },
);

// アプリロール「Admins」(value `admin`)。各アプリはトークンの `roles` に admin があれば管理者にする(docs/entra.md)。
// **ID を変えると割り当てが外れる**(割り当てはロールの ID を指す)。割り当て自体は Pulumi の外で、画面で持つ
new azuread.ApplicationAppRole(
  "doany-web-admins",
  {
    applicationId: `/applications/${APPLICATION_OBJECT_ID}`,
    roleId: "fd51fd21-182f-4eb1-971e-c545c5862667",
    value: "admin",
    displayName: "Admins",
    description: "この登録の後ろにあるセルフホストのアプリの管理者",
    allowedMemberTypes: ["User"],
  },
  { import: `/applications/${APPLICATION_OBJECT_ID}/appRoles/fd51fd21-182f-4eb1-971e-c545c5862667` },
);
