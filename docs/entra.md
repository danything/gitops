# Entra ID のアプリロールと、oauth2-proxy のセッション

## いまの決まり

**認可はアプリロールで決める。テナントに認可用のグループは無い**。
共用のアプリ登録 `Main`(client id `b0fa498f-7e6a-4fe1-a1c6-16fbbb6f397e`)にロール `Admins`(値 `admin`)があり、
各アプリはトークンの `roles` に `admin` があれば管理者にする。ロールとリダイレクト URI は Pulumi が持つ([../pulumi/entra.ts](../pulumi/entra.ts))。

- **ロールはユーザーに直接割り当てる。** テナントに Entra ID P1/P2 が無く、グループ単位の割り当てができない。管理者が増えたらその人にも割り当てる
- **`appRoleAssignmentRequired` は `false` のまま**(本人)。`はい` にすると、ロールの無い人が `Main` の後ろのアプリ全部から締め出され、
  人を足すたびに割り当てが要る。誰が入れるかはテナントに居るかどうか、何ができるかは各アプリ側で絞る
- ロールにした理由: 設定が読める(`g, admin, role:admin`)、ロール名は他の IdP にも移せる、トークンがテナントのグループの数に左右されない

| どこ | 何を見るか |
| --- | --- |
| oauth2-proxy(`auth` / `auth-sub`) | `OAUTH2_PROXY_OIDC_GROUPS_CLAIM=roles`、`ALLOWED_GROUPS=admin`(ロールも `groups` として扱う) |
| Argo CD | `scopes: '[roles, email]'`、`policy.csv` に `g, admin, role:admin` |
| denpa・yosegaki | `roles`(`src/lib/server/oidc.ts`) |

## ゲストを足したときに使えるもの

方針は「**使うものは全部使える、管理は `admin` のロールを持つ人(info@)だけ**」(本人)。
ゲストを Entra に招くだけで、割り当てなどは要らない。

| 種類 | ゲスト | 決めているところ |
| --- | --- | --- |
| Matrix・Element、Forgejo(チーム members)、denpa・ashi・yosegaki など | 入れる・使える | 割り当て必須が `false`。初回のログインでアカウントが自動で作られる |
| NetBird(VPN) | 入れる・家の LAN に届く | 方針が All の組(pulumi/netbird.ts) |
| Argo CD・Kubernetes(Headlamp)・Hubble | 見るだけ | Argo CD は `policy.default: role:readonly`、Kubernetes は `entra:viewer`、Hubble は前段でロールを見ない |
| AdGuard Home・`*.s.doany.io` | 入れない | 前段(oauth2-proxy)やアプリが `admin` のロールを求める |

Matrix の ID はメールの @ の前から作るので、前半が同じ人が 2 人居ると 2 人目は入れない(apps/matrix/README.md)。
Forgejo の members から外したいときは [../apps/forgejo/README.md](../apps/forgejo/README.md)「誰が何をできるか」。

## oauth2-proxy のセッションは Cookie だけ(redis なし)

セッションを大きくしていたのは **ID・アクセス・リフレッシュの 3 つのトークンそのもの**(合わせて 4 KB 超)。
**`OAUTH2_PROXY_SESSION_COOKIE_MINIMAL=true`** でそれを落とし、Email と User だけを Cookie に持つ。
`--pass-authorization-header` / `--set-authorization-header` / `--pass-access-token` / `--cookie-refresh` とは併用できない(使っていない)。
redis に戻すなら `SESSION_STORE_TYPE=redis` と `REDIS_CONNECTION_URL` を足して入れ直す(セッションは消える)。

効いたかは oauth2-proxy のログで見る。`groups:[admin]` ならロールで通り、`refresh_token:false` ならトークンが落ちている。

```shell
kubectl logs -n auth deploy/auth --since=10m | grep AuthSuccess
```

**`OIDC_GROUPS_CLAIM` を generic な `oidc` プロバイダで使うと `groups` スコープを勝手に要求し、Entra に AADSTS650053 で断られる**
(`bootstrap/auth/deployment.yaml` のコメント)。いまは `entra-id` プロバイダで `OAUTH2_PROXY_SCOPE` も明示している。
