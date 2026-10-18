// この Pulumi の CI が Entra に入るための、アプリ登録 2 つの「信頼の設定」(README.md「Entra」)。
// protect する: apply のものを消すと apply が Entra に入れなくなり、自分では直せない。
// アプリ登録そのもの(名前・API の権限)は CI の権限では書けないので持たない。

import * as azuread from "@pulumi/azuread";

// subject は「変わらない形」(番号入り)。今の形は `gh api repos/danything/gitops/actions/oidc/customization/sub`
const SUBJECT_PREFIX = "repo:danything@143234231/gitops@1311609465";
const ISSUER = "https://token.actions.githubusercontent.com";
const AUDIENCES = ["api://AzureADTokenExchange"];

// [リソース名, アプリ登録のオブジェクト ID, 信頼の設定の ID(取り込み元), 表示名, subject の後半, 説明]
const CREDENTIALS: [string, string, string, string, string, string][] = [
  // gitops pulumi preview (Entra read)。クライアント ID はリポジトリの Variables の PREVIEW_AZURE_CLIENT_ID
  ["ci-preview-pull-request", "55e188d0-1533-4813-93f9-8d52535436d6", "1af4e0b0-f7ef-485d-a118-dc3cc1d7a1df", "github-1", "pull_request", ""],
  ["ci-preview-main", "55e188d0-1533-4813-93f9-8d52535436d6", "cff51876-67be-4618-826f-bd9430f5fffe", "github-2", "ref:refs/heads/main", ""],
  // gitops pulumi apply (Entra write)。クライアント ID は Environment pulumi-apply の Variables の AZURE_CLIENT_ID
  ["ci-apply", "00096e10-38b6-4c02-bf2c-942bab44871b", "014bfa72-77a4-43ba-94d8-257ac43b093f", "github-1", "environment:pulumi-apply", ""],
];

for (const [name, objectId, credentialId, displayName, subject, description] of CREDENTIALS) {
  new azuread.ApplicationFederatedIdentityCredential(
    name,
    {
      applicationId: `/applications/${objectId}`,
      displayName,
      description,
      issuer: ISSUER,
      audiences: AUDIENCES,
      subject: `${SUBJECT_PREFIX}:${subject}`,
    },
    // 取り込みの ID は `<オブジェクト ID>/federatedIdentityCredential/<ID>`(先頭に /applications/ を付けると見つからない)
    { protect: true, import: `${objectId}/federatedIdentityCredential/${credentialId}` },
  );
}
