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
| ユーザー名 | `22ac977d-b140-4dc8-8150-90d645d3475b@<クライアント ID>` |
| パスワード | Infisical の `/infisical/infisical-smtp` の `SMTP_PASSWORD`(Infisical と todoroku が使う)、`/yosegaki/yosegaki-secrets` の `smtp-password` |
| 差出人 | `info@doany.io`(ほかのアドレスは Exchange が拒む) |

使っているのは Infisical(`bootstrap/infisical/values.yaml`)、yosegaki(blog のリポジトリ)、todoroku(Forgejo の doa/todoroku)。
**送る側を足すときは network-policy.yaml にその namespace を足す。**

## Entra のアプリの作り方(1 回だけ)

Pulumi の CI はアプリ登録を作れない(`pulumi/entra-ci.ts`)うえ、絞り込みは Exchange の PowerShell でしかできないので、手で作る。
上流の [`New-RelayEntraApp.ps1`](https://github.com/JustinIven/smtp-oauth-relay/blob/main/New-RelayEntraApp.ps1) が
アプリ登録・シークレット・サービスプリンシパル・Exchange の管理スコープ・`Application Mail.Send` の割り当てまでやる。
ホストに PowerShell のモジュールを入れないよう、使い捨てのコンテナで流す(ログインはデバイスコード):

```powershell
wslc run --rm -it mcr.microsoft.com/powershell:latest pwsh
```

```powershell
Install-Module Microsoft.Graph.Applications, ExchangeOnlineManagement -Scope CurrentUser -Force
Connect-MgGraph -UseDeviceCode -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All" -NoWelcome
Connect-ExchangeOnline -Device -ShowBanner:$false
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/JustinIven/smtp-oauth-relay/main/New-RelayEntraApp.ps1" -OutFile New-RelayEntraApp.ps1
./New-RelayEntraApp.ps1 -DisplayName "smtp-relay" -SenderAddress "info@doany.io" -SecretValidYears 2
```

出てくる **SMTP のユーザー名**(クライアント ID)を送る側の設定に、**パスワード**(クライアントシークレット)を Infisical の
上の 2 か所に入れる。シークレットはあとから取り出せない。期限は `pulumi.yml` の expiry が他のアプリ登録と一緒に知らせる。

## 確かめ方

```shell
tools/t.ps1 kubectl -n smtp-relay logs deploy/smtp-relay
```

送る側のログに失敗が無く、中継のログに Graph の 202 相当(送信成功)が出ること。
