# Entra ID のトークンを小さくして redis を捨てる

いまの forward-auth は oauth2-proxy + redis で、**redis はセッション(トークン)を持つためだけに居る**。
Entra が返す ID トークンが大きいのは `groups` クレームに**所属グループを全部載せている**ためで、
実測でセッションが 4293 バイトある。ここを小さくできれば oauth2-proxy を Cookie セッション
(`--session-store-type=cookie`)に変えられて、redis の Deployment と Service が消える。

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

## 効いたかの確かめ方

セッションの大きさは redis から直接測る。

```shell
kubectl exec -n auth deploy/auth-redis -- sh -c \
  'redis-cli --scan --pattern "*" | head -1 | xargs -I{} redis-cli STRLEN {}'
```

**4096 バイトを下回れば Cookie セッションに移せる。** 一度ログアウトしてから測ること
(古いセッションは前のトークンのまま残っている)。

## redis を捨てる

1. `bootstrap/auth/deployment.yaml` の `auth` と `auth-sub` から
   `OAUTH2_PROXY_SESSION_STORE_TYPE=redis` と `OAUTH2_PROXY_REDIS_CONNECTION_URL` を外す
   (既定が `cookie` なので、明示するなら `OAUTH2_PROXY_SESSION_STORE_TYPE=cookie`)
2. `bootstrap/auth/redis-deployment.yaml` と `redis-service.yaml` を消す
3. `bootstrap/` は Argo CD の同期対象外なので手で `kubectl apply` して、redis を `kubectl delete`
4. **切り戻し**は redis を戻して環境変数を足すだけ。セッションは消えるので入り直しになる
