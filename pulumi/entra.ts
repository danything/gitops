// Entra ID のアプリ登録(`b0fa498f-…`、auth / argocd / headlamp / … が共用する 1 つ)の
// リダイレクト URI(2026-10-06)とアプリロール(2026-10-07)を持つ。アプリ登録のほかの設定(クライアントシークレット、
// ロールの割り当て)には触れない ── `ApplicationRedirectUris` / `ApplicationAppRole` はそれぞれ自分の分だけを持つリソース。
//
// **アプリを足す・消すときは、そのアプリのマニフェストと同じ PR でここも直す。** 以前は手で足し引きしていて、
// ERPNext と Mattermost を消したあとも URI だけが残っていた。
//
// CI の鍵は置かない。GitHub Actions から Entra へはワークロード ID のフェデレーション(OIDC)で入る
// (README.md「Entra」)。手元で流すときは Azure CLI のログイン(`az login`)がそのまま使われる。

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
  ["mc.doany.io", "/auth-oidc-callback", "MeshCentral(meshcentral/。このクラスタの外)"],
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
  // 2026-10-06 に手で持っていた 12 本を取り込んだ(取り込み済みなら何もしない)
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
  // 2026-10-07 に画面で作ってあったものを取り込んだ
  { import: `/applications/${APPLICATION_OBJECT_ID}/appRoles/fd51fd21-182f-4eb1-971e-c545c5862667` },
);
