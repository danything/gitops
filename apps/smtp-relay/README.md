# smtp-relay

**クラスタの中のアプリのメールを、Microsoft 365(Exchange Online)へ Graph で送る中継**
([smtp-oauth-relay](https://github.com/JustinIven/smtp-oauth-relay))。アプリからは普通の SMTP に見える。

## なぜ

Exchange Online の SMTP AUTH の Basic 認証(ユーザー名とパスワード)は、2026-12 末に既定で無効、2027 年後半に廃止日が発表される。
`info@doany.io` は **Exchange Online Kiosk** で、Kiosk は SMTP の OAuth にも対応していないとされるので、
SMTP AUTH をやめて **Graph の `sendMail`** で送る。Infisical のように OAuth を話せないアプリもあるので、アプリごとに直さず中継を 1 つ置く。

## 仕組み

- 中継は**秘密を持たない**。アプリが SMTP AUTH で渡す
  - ユーザー名: `22ac977d-b140-4dc8-8150-90d645d3475b@<クライアント ID>`(テナント ID @ Entra のアプリのクライアント ID)
  - パスワード: そのアプリのクライアントシークレット(Infisical)
  
  で中継がトークンを取り、**差出人(From)のメールボックス**から `sendMail` する
- Entra のアプリ「smtp-relay」は Graph の `Mail.Send` をテナント全体には持たない。**Exchange の RBAC for Applications で、
  送れるメールボックスを `info@doany.io` だけに絞る**(下の作り方)
- クラスタの中だけで受ける(`smtp-relay.smtp-relay.svc:587`、STARTTLS なし)。届いてよい namespace は
  [network-policy.yaml](network-policy.yaml) で絞る。DKIM・SPF は Microsoft 365 が付けるので DNS は今のまま

## 送る側の設定

| | 値 |
| --- | --- |
| ホスト・ポート | `smtp-relay.smtp-relay.svc` / `587` |
| TLS | なし(STARTTLS もしない。Infisical は `SMTP_REQUIRE_TLS=false`、todoroku は `SMTP_STARTTLS=false`) |
| ユーザー名 | `22ac977d-b140-4dc8-8150-90d645d3475b@fd45a316-97cc-4480-8da8-487109403520` |
| パスワード | Infisical の `/infisical/infisical-smtp` の `SMTP_PASSWORD`(Infisical と todoroku が使う)、`/yosegaki/yosegaki-secrets` の `smtp-password` |
| 差出人 | `info@doany.io`(ほかのアドレスは Exchange が拒む) |

使っているのは Infisical(`bootstrap/infisical-values.yaml`)、yosegaki(blog のリポジトリ)、todoroku(Forgejo の doa/todoroku)。
**送る側を足すときは network-policy.yaml にその namespace を足す。**

## Entra のアプリと Exchange の絞り込み(1 回だけ。済み)

1. **アプリ登録とサービスプリンシパルは Pulumi**([pulumi/entra-smtp.ts](../../pulumi/entra-smtp.ts))。クライアント ID は
   `fd45a316-97cc-4480-8da8-487109403520`、サービスプリンシパルのオブジェクト ID は `87892e30-8165-46c1-b12d-c4cd30e5f717`
2. **Exchange の RBAC for Applications は PowerShell**(Pulumi では扱えない)。ホストにモジュールを入れないよう、使い捨てのコンテナで流す
   (`mcr.microsoft.com/powershell:lts-ubuntu-22.04`。latest では EXO のモジュールが読めなかった。ログインはデバイスコード):

   ```powershell
   Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
   Connect-ExchangeOnline -Device -ShowBanner:$false
   # 組織が dehydrated なら先に Enable-OrganizationCustomization(取り消せない)。実体化に数時間かかり、その間 New-ManagementScope が通らない
   New-ServicePrincipal -AppId fd45a316-97cc-4480-8da8-487109403520 -ObjectId 87892e30-8165-46c1-b12d-c4cd30e5f717 -DisplayName smtp-relay
   New-ManagementScope -Name 'smtp-relay mailbox scope' -RecipientRestrictionFilter "PrimarySmtpAddress -eq 'info@doany.io'"
   New-ManagementRoleAssignment -App fd45a316-97cc-4480-8da8-487109403520 -Role 'Application Mail.Send' -CustomResourceScope 'smtp-relay mailbox scope'
   Test-ServicePrincipalAuthorization -Identity fd45a316-97cc-4480-8da8-487109403520 -Resource info@doany.io   # InScope が True
   ```

3. **クライアントシークレットは Entra の画面で作り**(期限 24 か月)、値を Infisical の上の 2 か所に入れる。あとから取り出せない。
   期限は `pulumi.yml` の expiry が他のアプリ登録と一緒に知らせる。作り直したら 2 か所を書き換え、送る側を rollout restart する

## 確かめ方

```shell
tools/t.ps1 kubectl -n smtp-relay logs deploy/smtp-relay
```

送る側のログに失敗が無く、中継のログに Graph の 202 相当(送信成功)が出ること。
