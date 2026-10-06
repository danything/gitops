// Entra ID のアプリ登録(`b0fa498f-…`、auth / argocd / headlamp / … が共用する 1 つ)の
// **リダイレクト URI だけ**を持つ(2026-10-06)。アプリ登録のほかの設定(クライアントシークレット、
// アプリロール、割り当て)には触れない ── `ApplicationRedirectUris` はこの一覧だけを持つリソース。
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
  ["nb.doany.io", "/oauth2/callback", "NetBird"],
  ["nb.doany.io", "/oauth2/logout/callback", "NetBird(ログアウト)"],
  ["yk.doany.io", "/admin/callback", "yosegaki の管理画面"],
  ["z.doany.io", "/complete/oidc/", "Zulip"],
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
