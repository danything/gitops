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

## 手順 A(推奨): クレームを「アプリに割り当てたグループだけ」にする

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

## 手順 B: アプリロールに切り替える

グループそのものをやめてロールにする。**トークンはさらに小さくなり**(`roles: ["admin"]` の数十バイト)、
将来 Gateway 内蔵の OIDC(Envoy Gateway など)を使う道も開く。ただし **denpa のコード修正が要る**。

1. **アプリの登録** → 対象のアプリ → **アプリ ロール** → **アプリ ロールの作成**
   - 表示名: `Admins` / 値: `admin` / 許可されたメンバーの種類: **ユーザーまたはグループ**
2. **エンタープライズ アプリケーション** → 同じアプリ → **ユーザーとグループ**
   → **ユーザーまたはグループの追加** → `admins` グループを選び、ロールに `Admins` を割り当てる
3. **プロパティ** → **割り当てが必要ですか?** が **はい** になっていることを確認
   (いいえだと、割り当てていない人もログインだけは通る)
4. **トークン構成** のグループ要求は消してよい
5. クラスタ側:
   - oauth2-proxy に `OAUTH2_PROXY_OIDC_GROUPS_CLAIM=roles` を足し、`ALLOWED_GROUPS` を `admin` にする
   - Argo CD の `scopes` を `'[roles, email]'`、`policy.csv` を `g, admin, role:admin` に
   - yosegaki の `oidc.adminGroups` を `admin` に(コードは既に `roles` を見る)
   - denpa の `src/lib/server/oidc.ts` に `roles` を読む分岐を足す

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
