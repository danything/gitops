# Entra ID のアプリロールと、oauth2-proxy のセッション

## まず訂正: グループクレームは redis の理由ではなかった(2026-09-07)

長らく「Entra の `groups` クレームに所属グループが全部載るのでセッションが Cookie に
収まらない、だから redis が要る」と書いていたが、**これは誤りだった**。

数えたところ、このテナントで管理者ユーザーが所属するグループは **2 つだけ**
(`admins` と `All Company`)。GUID は 1 つ 36 文字なので、`groups` クレームは
せいぜい 100 バイト強しかない。4293 バイトあったセッションの中身は
**ID トークン・アクセストークン・リフレッシュトークンそのもの**で、
グループを削ってもほとんど減らない。

**効いたのは `--session-cookie-minimal`。** Cookie セッションからその 3 つのトークンを落とす。
残るのは Email と User だけで、`X-Auth-Request-*` を出すには十分。
`--pass-authorization-header` / `--set-authorization-header` / `--pass-access-token` /
`--cookie-refresh` とは併用できない(どれも落とすトークンを必要とする)が、どれも使っていない。

**アプリロールへの移行はそれとは独立に価値がある**(下記)。トークンが小さくなることは
主目的ではなくなった、というだけ。

## アプリロールに移す理由(トークンの大きさとは別)

- **設定が読める。** `g, <グループの Object ID>, role:admin` が `g, admin, role:admin` になる
- **移植できる。** グループの Object ID は Entra 固有の GUID。ロール名なら別の IdP でも通る
- **トークンがテナントの都合に左右されない。** 将来グループが増えても `roles: ["admin"]` のまま
- Microsoft 自身も新規のアプリではロールを勧めている

## いま `groups` を読んでいるもの

**変更の影響範囲はここで決まる。** 同じアプリ登録
(client id `b0fa498f-7e6a-4fe1-a1c6-16fbbb6f397e`)を 5 つが共有している。

| | 何を読むか | アプリロールに切り替えたら |
| --- | --- | --- |
| oauth2-proxy(`auth` / `auth-sub`) | `OAUTH2_PROXY_ALLOWED_GROUPS` にグループの Object ID | `--oidc-groups-claim=roles` が要る |
| Argo CD | `policy.csv` の `g, <Object ID>, role:admin` と `scopes: '[groups, email]'` | `scopes` と `policy.csv` の書き換えが要る |
| yosegaki | `groups` **と** `roles` の両方を見る(`src/lib/server/oidc.ts`) | 値を `admin` にするだけ |
| denpa | **`groups` だけ**(`src/lib/server/oidc.ts`) | **コードの修正が要る**。yosegaki と同じく `roles` も見るようにする |
| ERPNext | ソーシャルログイン。グループでは絞っていない | 影響なし |

## どちらを採るか

**新しく組む・長く運用するなら手順 B(アプリロール)。** Microsoft 自身も
[グループ要求の構成](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-fed-group-claims)で
「新しいアプリを作っている / 既存アプリを設定できる」「ネストしたグループが要らない」なら
**グループではなくアプリロールを勧める**と書いている。理由は 3 つとも当てはまる。

| | グループを絞る(A) | アプリロール(B) |
| --- | --- | --- |
| トークンの大きさ | いまは小さくなるが、**アプリに割り当てるグループが増えればまた育つ** | `roles: ["admin"]` で固定。テナントの都合に左右されない |
| 設定の読みやすさ | `g, 5847ec59-0f80-…, role:admin` のような GUID が散らばる | `g, admin, role:admin` |
| 移植性 | グループの Object ID は Entra 固有 | ロール名は他の IdP でもそのまま |
| 誰が管理者か | グループの GUID を知っている必要がある | エンタープライズ アプリケーションの割り当て画面で見える |
| 要る作業 | **Entra の設定 1 回だけ。アプリは無変更** | Entra + アプリ 4 つの書き換え(denpa はコード修正) |

ネストしたグループは**どちらも展開されない**(A は仕様、B はロール割り当ての仕様)ので、そこに差は無い。

**手順 A は「今日 redis を消したい」ときの近道。** 両方やるなら Entra の作業が二度手間になるので、
最初から B を選ぶほうがよい。

## 手順 A: クレームを「アプリに割り当てたグループだけ」にする

**アプリ側は何も変えなくていい。** 出るのが `admins` の Object ID 1 つになるだけなので、
上の 5 つは全部そのまま動く。ネストしたグループは載らなくなるので、**`admins` に直接入っていること**が前提。

1. [Microsoft Entra 管理センター](https://entra.microsoft.com) → **アプリケーション** → **アプリの登録**
   → 対象のアプリ(client id `b0fa498f-…`)
2. 左メニューの **トークン構成** → **グループ要求の追加**
3. **アプリケーションに割り当てられているグループ** を選ぶ
   (英語表示なら *Groups assigned to the application*)
4. **ID トークン** と **アクセス トークン** の両方にチェックを入れて保存

   マニフェストで直接書くなら `"groupMembershipClaims": "ApplicationGroup"`。
5. **アプリケーション** → **エンタープライズ アプリケーション** → 同じアプリ → **ユーザーとグループ**
   → `admins` グループが割り当てられていることを確認(無ければ **ユーザーまたはグループの追加**)

> **注意**: この設定ではネストしたグループが展開されない。`admins` の中に別のグループを入れて
> 間接的に所属させている人が居ると、その人はトークンに `admins` が載らなくなって弾かれる。

## 手順 B(推奨): アプリロールに切り替える

グループそのものをやめてロールにする。**締め出されない順番でやること。**
先に Entra を変えると、`groups` しか見ていないアプリから全員が弾かれる。

### 順番

1. **アプリ側を先に「両対応」にする。** `groups` と `roles` のどちらでも通るようにして deploy する。
   yosegaki は既にそうなっている(`src/lib/server/oidc.ts`)ので、denpa をそれに合わせる。
   この時点ではまだ `groups` で通っているので何も壊れない
2. Entra でロールを作って割り当てる(下記)
3. 実機でログインし直して、ロールで通ることを確認する
4. Entra の**グループ要求を消す**。トークンが小さくなる
5. アプリ側の `groups` を見る分岐を落とす(急がなくてよい)

### Entra の操作(上の 2)

**画面が英語のときの表記を括弧に添えてある。**

1. **アプリの登録**(*App registrations*)→ 対象のアプリ → **アプリ ロール**(*App roles*)
   → **アプリ ロールの作成**(*Create app role*)
   - 表示名(*Display name*): `Admins`
   - 許可されたメンバーの種類(*Allowed member types*): **ユーザーまたはグループ**(*Users/Groups*)
   - 値(*Value*): `admin` ← **トークンに載るのはこれ**
   - 説明(*Description*): 任意
2. **エンタープライズ アプリケーション**(*Enterprise applications*)→ 同じアプリ
   → **ユーザーとグループ**(*Users and groups*)→ **ユーザーまたはグループの追加**
   (*Add user/group*)→ `admins` グループを選び、ロールに `Admins` を割り当てる
3. **プロパティ**(*Properties*)→ **割り当てが必要ですか?**(*Assignment required?*)が
   **はい**(*Yes*)であることを確認。いいえだと、割り当てていない人もログインだけは通る
4. 上の 4 の段で、**トークン構成**(*Token configuration*)のグループ要求を消す

### クラスタ側(上の 1 と 5)

| どこ | 何を |
| --- | --- |
| denpa | `src/lib/server/oidc.ts` に `roles` を読む分岐を足す(**先にやる**) |
| oauth2-proxy | `OAUTH2_PROXY_OIDC_GROUPS_CLAIM=roles` を足し、`ALLOWED_GROUPS` を `admin` に |
| Argo CD | `scopes` を `'[roles, email]'`、`policy.csv` を `g, admin, role:admin` に |
| yosegaki | `oidc.adminGroups` を `admin` に(コードは既に `roles` を見る) |

> oauth2-proxy の `OIDC_GROUPS_CLAIM` は、以前 **generic な `oidc` プロバイダで使ったときに
> `groups` スコープを勝手に要求して Entra に AADSTS650053 で断られた**ことがある
> (`bootstrap/auth/deployment.yaml` のコメント)。いまは `entra-id` プロバイダで
> `OAUTH2_PROXY_SCOPE` も明示しているので起きないはずだが、**1 ルートで確かめてから広げること。**

## 実施ログ(2026-09-07)

`az` で操作した。**テナントに Entra ID P1/P2 が無いので、ロールにグループは割り当てられない**
(グループ単位のアプリロール割り当ては P1 以上の機能)。ユーザーを直接ロールに割り当ててある。
管理者が増えたら、その人にもロールを割り当てる。

| | |
| --- | --- |
| アプリ登録 | `Main`(`b0fa498f-…`、オブジェクト ID `89e18065-…`) |
| 作ったロール | 表示名 `Admins` / 値 `admin` / ID `fd51fd21-182f-4eb1-971e-c545c5862667` |
| 割り当て | ユーザー `info@doany.io` に直接 |
| `appRoleAssignmentRequired` | **`false` のまま。** 「割り当てが必要」は元から `いいえ` だった(コードのコメントは誤り)。絞っているのは各アプリ側の判定 |

```shell
# 作ったときのコマンド(値は上のとおり)
az rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/<オブジェクト ID>"   --headers "Content-Type=application/json" --body @approle.json
az rest --method POST   --url "https://graph.microsoft.com/v1.0/servicePrincipals/<SP の ID>/appRoleAssignedTo"   --headers "Content-Type=application/json"   --body '{"principalId":"<ユーザーの ID>","resourceId":"<SP の ID>","appRoleId":"<ロールの ID>"}'
```

アプリ側は両対応にして deploy 済み。**Entra のグループ要求はまだ消していない**ので、
いまはトークンに `groups` と `roles` の両方が載っている。

| | 状態 |
| --- | --- |
| denpa | `roles` も見るようにした |
| yosegaki | `adminGroups` に `admin` と GUID の両方 |
| Argo CD | `scopes: '[roles, groups, email]'`、`policy.csv` に両方の行 |
| oauth2-proxy | **`roles` のみ**(`--oidc-groups-claim` は 1 つしか取れない)。`ALLOWED_GROUPS=admin` |

**完了(2026-09-07)。** ログインが `roles` で通ることをログで確認し
(`[AuthSuccess] ... groups:[admin]`)、Entra のグループ要求を消して
(`groupMembershipClaims: null`)、redis を落とし、各アプリから GUID を落とした。

**`appRoleAssignmentRequired` は `false` のままにしてある。** `はい` にすると
ロールを割り当てていない人がこの登録の後ろにあるアプリ全部から締め出される。
ERPNext はテナントのゲストも使うので、そこは開けておく
(ERPNext は OIDC のスコープが `openid profile email` だけで、グループもロールも見ていない)。

**`admins` グループも削除した(2026-09-07)。** ディレクトリロールもライセンスも条件付きアクセスも
このグループを使っておらず、メールも有効でなかった(セキュリティグループなので Teams や
SharePoint も付いていない)。唯一残っていた参照は別のアプリ登録 `wg-easy` への割り当てだったが、
**wg-easy の OIDC は上流の都合で使えない**(Entra の userinfo が `email_verified` を返さず、
wg-easy がそれを必須にしている)ので無視した。あちらには本人のユーザー割り当ても別途ある。

**wg-easy を廃したので、アプリ登録 `wg-easy` と、共用アプリ `Main` に残っている
`https://wg.doany.io/oauth2/callback` のリダイレクト URI は消してよい**(2026-09-07 に VPN を
NetBird へ移した。理由は [decisions.md](decisions.md))。NetBird は内蔵 IdP(Dex)を持っていて、
Entra は「外部 IdP」として NetBird のダッシュボードから足す形になる。
リダイレクト URI は `https://nd.doany.io/oauth2/callback` で固定。

**これでこのテナントに認可用のグループは無い。** 誰が管理者かは、アプリ登録 `Main` の
エンタープライズ アプリケーション → ユーザーとグループ で `Admins` ロールを割り当てるかどうかだけで決まる。

## 効いたかの確かめ方

oauth2-proxy のログにセッションの中身が出る。

```shell
kubectl logs -n auth deploy/auth --since=10m | grep AuthSuccess
```

`groups:[admin]` ならロールで通っている(oauth2-proxy はロールも `groups` として扱う)。
`refresh_token:false` なら `session-cookie-minimal` が効いてトークンが落ちている。

## redis を捨てる

**全部済んだ(2026-09-07)。**

1. `OAUTH2_PROXY_SESSION_STORE_TYPE` を `cookie` にし、`OAUTH2_PROXY_SESSION_COOKIE_MINIMAL=true` を入れた
2. 実機のログインで通ることを確認
   (`[AuthSuccess] … refresh_token:false groups:[admin]`)。`a.doany.io`・`*.s.doany.io`・Argo CD とも本人確認済み
3. `redis-deployment.yaml` と `redis-service.yaml` を削除し、実機からも `kubectl delete` した
4. **切り戻すなら** `SESSION_STORE_TYPE=redis` と `REDIS_CONNECTION_URL` を戻して redis を入れ直す。
   セッションは消えるので入り直しになる
