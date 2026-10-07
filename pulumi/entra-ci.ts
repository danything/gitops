// この Pulumi 自身が Entra に入るための、CI 用のアプリ登録 2 つの「信頼の設定」(ワイルドカード ID のフェデレーション)。
// GitHub Actions のどの実行に、どのアプリ登録としてトークンを出すかを決める(README.md「Entra」)。
//
// 2026-10-06 に `az` で手で作り、subject の形を間違えて AADSTS700213 で入れなかったことがある。git で持つ。
// 2026-10-07 に取り込んだ。書き換えられるよう、apply のサービスプリンシパルを 2 つのアプリ登録の所有者にした
// (Application.ReadWrite.OwnedBy は自分が所有者のものしか書けない)。
//
// **apply の信頼の設定は消せないように protect する。** 消すと apply が Entra に入れなくなり、自分では直せない
// (直すには管理者が az で作り直す)。preview のほうも、壊すと PR の preview が落ちる。
//
// アプリ登録そのもの(名前・API の権限)は持たない。Graph の権限の付与は管理者の同意が要り、CI の権限では書けない。

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
    { protect: true, import: `/applications/${objectId}/federatedIdentityCredential/${credentialId}` },
  );
}
