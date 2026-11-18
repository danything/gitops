// Twenty(deploy/twenty。t.doany.io)の「Microsoft でサインイン」に使うアプリ登録「twenty」。
//
// **共用のアプリ登録 Main は使えない。** Twenty は Microsoft の認可の入口を `common` に決め打ちしていて
// (twenty-server の microsoft.auth.strategy.ts)、自分のテナント専用(AzureADMyOrg)のアプリでは AADSTS50194 で弾かれる。
// そのため、このアプリだけマルチテナント(AzureADMultipleOrgs)にする。個人の Microsoft アカウントは入れない。
//
// **誰が入れるかは Twenty の側で絞る。** ワークスペースを作ったあとは、招待か、許可したドメイン(doany.io)の人しか入れない
// (IS_WORKSPACE_CREATION_LIMITED_TO_SERVER_ADMINS。deploy/twenty/README.md)。ほかのテナントの人はサインインの画面までは来られる。
//
// 権限は Graph の User.Read(委任)だけ。メールとカレンダーの同期(Mail.ReadWrite など)は付けない。
// クライアントシークレットは持たない(state に秘密を入れない。entra-smtp.ts と同じ)。画面で作って deploy/twenty/secrets.sops.yaml に入れる。

import * as azuread from "@pulumi/azuread";

// 所有者を apply の資格情報のサービスプリンシパルにする(理由は entra-smtp.ts)
const APPLY_SP_OBJECT_ID = "7d33dc7d-8a60-4f90-86d8-b22405da8972";

// Microsoft Graph と、その委任の権限 User.Read(どのテナントでも同じ ID)
const MS_GRAPH_APP_ID = "00000003-0000-0000-c000-000000000000";
const USER_READ_SCOPE_ID = "e1fe6dd8-ba31-4d61-89e7-88639da4683d";

const app = new azuread.Application("twenty", {
  displayName: "twenty",
  description: "deploy/twenty(t.doany.io)の Microsoft サインイン。入れる人は Twenty の側で doany.io に絞る",
  signInAudience: "AzureADMultipleOrgs",
  owners: [APPLY_SP_OBJECT_ID],
  web: {
    redirectUris: ["https://t.doany.io/auth/microsoft/redirect"],
  },
  requiredResourceAccesses: [
    {
      resourceAppId: MS_GRAPH_APP_ID,
      resourceAccesses: [{ id: USER_READ_SCOPE_ID, type: "Scope" }],
    },
  ],
});

new azuread.ServicePrincipal("twenty", { clientId: app.clientId, owners: [APPLY_SP_OBJECT_ID] });

// deploy/twenty/twenty.yaml の AUTH_MICROSOFT_CLIENT_ID に書く
export const twentyClientId = app.clientId;
