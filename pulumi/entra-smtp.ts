// メールの中継(apps/smtp-relay)が Graph の sendMail に使うアプリ登録「smtp-relay」。
// apply の資格情報(Application.ReadWrite.OwnedBy)は自分で作ったアプリ登録だけを扱えるので、これは CI が作って持つ。
//
// **Graph の権限(Mail.Send)はここでは付けない。** テナント全体で誰としてでも送れてしまうため。
// 代わりに Exchange の RBAC for Applications で、送れるメールボックスを info@doany.io だけに絞る(apps/smtp-relay/README.md)。
// それは Exchange の PowerShell でしかできないので Pulumi の外。
//
// クライアントシークレットも持たない(手元から state を読めず、Infisical に渡す道が無い)。画面で作って Infisical に入れる。
// 期限は pulumi.yml の expiry が知らせる。

import * as azuread from "@pulumi/azuread";

const app = new azuread.Application("smtp-relay", {
  displayName: "smtp-relay",
  description: "apps/smtp-relay(SMTP → Graph の sendMail)。送れるのは Exchange の RBAC で info@doany.io だけ",
  signInAudience: "AzureADMyOrg",
});

const sp = new azuread.ServicePrincipal("smtp-relay", { clientId: app.clientId });

// Exchange の New-ServicePrincipal と、送る側の SMTP のユーザー名(<テナント ID>@<クライアント ID>)に使う
export const smtpRelayClientId = app.clientId;
export const smtpRelayServicePrincipalId = sp.objectId;
