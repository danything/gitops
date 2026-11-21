// Twenty(deploy/twenty。t.doany.io)の「Microsoft でサインイン」と、メール・カレンダーの同期に使うアプリ登録「twenty」。
//
// **共用のアプリ登録 Main は使えない。** Twenty は Microsoft の認可の入口を `common` に決め打ちしていて
// (twenty-server の microsoft.auth.strategy.ts と microsoft-apis-oauth-common.auth.strategy.ts)、自分のテナント専用(AzureADMyOrg)の
// アプリでは AADSTS50194 で弾かれる。そのため、このアプリだけ自分のテナントの外にも開く。
//
// **個人の Microsoft アカウント(outlook.com など)も入れる**(AzureADandPersonalMicrosoftAccount)。持ち主の普段の予定は
// 個人のアカウント(y16m@outlook.com)にあり、それを Twenty の同期につなぐため。個人のアカウントを入れるには、アクセストークンを
// v2 にしておく必要がある(api.requestedAccessTokenVersion)。
//
// **誰が入れるかは Twenty の側で絞る。** ワークスペースを作ったあとは、招待か、許可したドメイン(doany.io)の人しか入れない
// (IS_WORKSPACE_CREATION_LIMITED_TO_SERVER_ADMINS。deploy/twenty/README.md)。ほかのテナントや個人のアカウントの人も、
// サインインの画面までは来られるが、ワークスペースには入れない。
//
// 権限は Graph の委任だけ。Twenty はアカウントをつなぐとき、同期するのがメールだけでもカレンダーだけでも、必ず次を全部求める
// (get-microsoft-apis-oauth-scopes.ts)。読むだけの権限(Mail.Read など)では足りない。
// クライアントシークレットは持たない(state に秘密を入れない。entra-smtp.ts と同じ)。画面で作って deploy/twenty/secrets.sops.yaml に入れる。

import * as azuread from "@pulumi/azuread";

// 所有者を apply の資格情報のサービスプリンシパルにする(理由は entra-smtp.ts)
const APPLY_SP_OBJECT_ID = "7d33dc7d-8a60-4f90-86d8-b22405da8972";

// Microsoft Graph と、その委任の権限(どのテナントでも同じ ID)
const MS_GRAPH_APP_ID = "00000003-0000-0000-c000-000000000000";
const GRAPH_DELEGATED_SCOPE_IDS = {
  "User.Read": "e1fe6dd8-ba31-4d61-89e7-88639da4683d",
  openid: "37f7f235-527c-4136-accd-4a02d197296e",
  email: "64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0",
  profile: "14dad69e-099b-42c9-810b-d002981feec1",
  offline_access: "7427e0e9-2fba-42fe-b0c0-848c9e6a8182",
  "Mail.ReadWrite": "024d486e-b451-40bb-833d-3e66d98c5c73",
  "Mail.Send": "e383f46e-2787-4529-855e-0e479a3ffac0",
  "Calendars.ReadWrite": "1ec239c2-d7c9-4623-a91a-a9775856bb36",
};

const app = new azuread.Application("twenty", {
  displayName: "twenty",
  description: "deploy/twenty(t.doany.io)の Microsoft サインインとメール・カレンダーの同期。入れる人は Twenty の側で doany.io と招待に絞る",
  signInAudience: "AzureADandPersonalMicrosoftAccount",
  owners: [APPLY_SP_OBJECT_ID],
  api: { requestedAccessTokenVersion: 2 },
  web: {
    redirectUris: [
      // サインイン(AUTH_MICROSOFT_CALLBACK_URL)
      "https://t.doany.io/auth/microsoft/redirect",
      // メールとカレンダーのアカウントをつなぐ(AUTH_MICROSOFT_APIS_CALLBACK_URL)
      "https://t.doany.io/auth/microsoft-apis/get-access-token",
    ],
  },
  requiredResourceAccesses: [
    {
      resourceAppId: MS_GRAPH_APP_ID,
      resourceAccesses: Object.values(GRAPH_DELEGATED_SCOPE_IDS).map((id) => ({ id, type: "Scope" })),
    },
  ],
});

new azuread.ServicePrincipal("twenty", { clientId: app.clientId, owners: [APPLY_SP_OBJECT_ID] });

// deploy/twenty/twenty.yaml の AUTH_MICROSOFT_CLIENT_ID に書く
export const twentyClientId = app.clientId;
