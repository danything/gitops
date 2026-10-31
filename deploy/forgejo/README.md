# forgejo

`fj.doany.io`。git のホスティングと Forgejo Actions。**GitHub Actions の課金を避けて、CI をこのクラスタで回す**ために置いた。

| ファイル | 中身 |
| --- | --- |
| [forgejo.yaml](forgejo.yaml) | Forgejo 本体(最新を追う)。chart は使わない(理由はファイルの先頭) |
| [postgres.yaml](postgres.yaml) | DB |
| [runner.yaml](runner.yaml) | Runner(v13)+ docker(dind)。`runs-on: ubuntu-latest` をそのまま拾う |
| [httproute.yaml](httproute.yaml) | 公開経路。SSH は出さない(clone / push は HTTPS + トークン) |
| [forgejo-secrets.yaml](forgejo-secrets.yaml) | Infisical から Secret 3 つ |
| [argocd-creds.yaml](argocd-creds.yaml) | ArgoCD が Forgejo のリポジトリを読むための資格情報 |

バックアップは [../volsync/forgejo.yaml](../volsync/forgejo.yaml)(VolSync。PVC 2 本をスナップショットから、毎日 19:35・19:40 UTC)。

## 使い始め

1. **Infisical に 2 つ入れる(同期より先に)**
   - `/forgejo/forgejo-db`: `postgres-password` ── 英数字だけのランダム(`openssl rand -hex 32` など)。
     postgres は最初の起動でしかパスワードを設定しないので、**後から変えるなら DB 側も変える**
   - `/forgejo/forgejo-oauth`: `key` = `b0fa498f-7e6a-4fe1-a1c6-16fbbb6f397e`(Main のクライアント ID。秘密ではなく deploy/auth にも平文で書いてある)、`secret` = `${prod.auth.auth-secrets.oidc-client-secret}`(値は写さず参照)
2. Entra のアプリ登録 Main のリダイレクト URI に `https://fj.doany.io/user/oauth2/entra/callback`([pulumi/entra.ts](../../pulumi/entra.ts) にある)
3. main にマージ → ArgoCD が同期
4. **管理者を作る**(1 度だけ)。Entra のメールと同じにしておくと、Entra でログインしたときに自動で紐づいて管理者になる。
   パスワードは捨てる(表示させない)。組織 `doa` とチーム `members`(読み取り・すべてのリポジトリ)も作る

   ```shell
   kubectl -n forgejo exec deploy/forgejo-web -c forgejo -- \
     gitea admin user create --admin --username info --email info@doany.io --random-password >/dev/null
   ```

   **members を作る前にログインした人は、次のログインで入る**
5. **Runner の秘密を入れる**: Infisical `/forgejo/forgejo-runner` に `runner-secret` = 16 進 40 文字のランダム。
   値は画面に出さずに作って貼る(WSL なら `openssl rand -hex 20 | tr -d '\n' | clip.exe`。貼ったらクリップボードは消す)。
   管理画面での操作は要らない。Forgejo と Runner の Pod が入れ替わり、Forgejo の init が同じ秘密で Runner を登録し
   ([forgejo.yaml](forgejo.yaml) の setup.sh の 5)、Runner は同じ秘密から uuid / token を出して繋ぐ([runner.yaml](runner.yaml))。
   `/admin/actions/runners` に `forgejo-runner` が「Idle」で出れば済み。
   **秘密を変えると別の Runner として登録される**(UUID は秘密の先頭 16 文字から作る)。古い方は一覧で消す

## プライベートのリポジトリを移す(1 本ずつ)

**方針: プライベートは GitHub に置かない。** GitHub Actions の課金はプライベートにだけ掛かるので、
公開リポジトリ(gitops・blog など)は GitHub のままでよい。

**Forgejo が唯一の置き場になる。** バックアップは VolSync(R2)の 1 日 1 回だけなので、手元の clone も捨てないこと。

ArgoCD が読むトークンは Infisical `/argocd/forgejo-repo-creds`([argocd-creds.yaml](argocd-creds.yaml))。
**スコープは repository・organization・issue の読み取り。** issue が無いと ApplicationSet が
`token does not have at least one of required scope(s): [read:issue]` で止まる。
ApplicationSet は GitHub 側と別の `repos-forgejo`(同居させると、Forgejo が空のクラスタで GitHub 側まで 1 本も作られない)。

リポジトリごとに:

1. Forgejo の「新しい移行」で組織 `doa` の下に取り込む(Issue / PR / リリースも)。非公開のまま入り、チーム members が読める
2. ワークフローを Forgejo 向けに直す(`.github/workflows/` のままで読まれる)
   - イメージは `ghcr.io/danything/<name>` → `fj.doany.io/doa/<name>`。push はワークフローの `secrets.GITHUB_TOKEN`(Forgejo のトークン)で通る
   - クラスタが pull できるように、アプリの namespace に `imagePullSecrets` を足す(Forgejo の `read:package` トークンを Infisical から `kubernetes.io/dockerconfigjson` で)
   - claude-review(GitHub App)のワークフローは消す。Forgejo では動かない
3. Forgejo で CI とイメージの push が通るのを確かめる
4. **GitHub のリポジトリを消す**。両方に `deploy/argocd.yaml` があると Application 名がぶつかる
   (ApplicationSet が `repos` と `repos-forgejo` に分かれているので、2 つが同じ Application を奪い合う)。
   ApplicationSet は `preserveResourcesOnDeletion: true` なので、Application が作り直されても Pod や PVC は消えない
5. ghcr.io の古いパッケージを消す

## 誰が何をできるか

| | 公開リポジトリ | 非公開リポジトリ | fork・PR | push・マージ | 管理画面 |
| --- | --- | --- | --- | --- | --- |
| ログインしていない人 | 見える | 見えない | ─ | ─ | ─ |
| テナントの人(Entra、チーム members) | 見える | 読める | できる | できない | ─ |
| 管理者(Forgejo の管理画面で付ける) | 全部 | 全部 | できる | できる | できる |

- **テナントのゲストも tid が同じなので members に入る。** 外したくなったら Forgejo 専用のアプリ登録を作り、
  「割り当てが必要」にして人ごとに割り当てる(Main の設定を変えると、ロールを割り当てていない人が Main の後ろのアプリ全部から締め出される。
  [../../docs/entra.md](../../docs/entra.md))
- **Entra のアプリロール admin は Forgejo の管理者に連動しない**(グループのクレームを tid に使っているため)。管理者は管理画面で付け外しする
- **fork からの PR のワークフローは、管理者が承認するまで走らない**(読み取り権限だけの人は承認が要る。Forgejo の既定)。
  Runner は privileged なので、中身を見ずに承認しないこと

## 気をつけること

- **Runner の docker は privileged**。namespace の PSA が `privileged` なのはこのため
- dind のイメージ置き場は `emptyDir`。Pod が入れ替わると次のジョブで pull し直す
- Cilium は vxlan なので dind の MTU を 1400 にしてある。1500 に戻すと大きい pull が途中で止まる

## 組織 doa は「ログインユーザーのみ」(limited)

**公開にしてはいけない。** パッケージ(コンテナイメージ)の読み取り権限はリポジトリではなく**組織の公開範囲**で決まり、
公開の組織だと非公開リポジトリのイメージでも匿名で pull できる(`services/packages/perm.go` の
`HasOrgOrUserVisible`)。

## Actions からイメージを push するとき

**ワークフローの自動トークン(`GITHUB_TOKEN`)ではパッケージに書けない**(Forgejo 15。`services/packages/perm.go` に
`TODO: ActionUser permission check` とあり、Actions のユーザーは組織のメンバー扱いにならない)。
組織 doa の Actions のシークレット `REGISTRY_TOKEN`(bot ユーザー `forgejo-bot` の `write:package` だけのトークン)で
`docker login fj.doany.io -u forgejo-bot` する。下の承認済みインテグレーションで秘密を無くせることは確かめたが、
forgejo-bot のものは管理の手段が無いので見送っている(下の表)。

## 承認済みインテグレーション(Authorized Integrations、Forgejo 16)

CI から Forgejo の API・git・レジストリに**長く生きる秘密なしで**入る仕組み。外から来た JWT のクレームを、ユーザーごとに
登録したルールで確かめ、合えばそのユーザーとして(登録したスコープとリポジトリの範囲で)通す。
[ドキュメント](https://forgejo.org/docs/latest/user/api/authorized-integrations/)。設定(app.ini)は要らない
(`[authorized_integration]` の既定で外の発行者に取りに行ける)。既定では取りに行けるのは外のホストだけで、
クラスタの中・プライベートの IP・ループバックには行かない(`ALLOW_LOCALNETWORKS` が false。`services/auth/authorized_integration.go`
の `initAuthorizedIntegrationHTTPClient`)。リダイレクトも追わず、`jwks_uri` は発行者と同じホストに限る。
もっと絞るなら `FORGEJO__authorized_integration__ALLOWED_DOMAINS: token.actions.githubusercontent.com`
(Forgejo Actions の JWT は中で確かめるので、この一覧に要らない)。

- **誰として動くか**: インテグレーションの持ち主。push・PR・マージの予約も持ち主がしたことになるので、
  付属の actions トークンと違って**ワークフローも起きる**(`services/actions/notifier_helper.go` は `IsActions()` のときだけ止める)
- **渡し方**: API は `Authorization: Bearer <JWT>`(`token <JWT>` でも通る)。git とレジストリは Basic のパスワードに JWT
  (ユーザー名は見ない。`routers/web/web.go` の `buildGitAuthGroup`、`routers/api/packages/api.go` の `ContainerRoutes`)
- **JWT の寿命**: Forgejo Actions のものは 1 時間(`[actions].ID_TOKEN_EXPIRATION_TIME`)。レジストリのトークンもそれに縛られる
- **リポジトリを絞ると**、スコープは repository / issue しか選べず、管理者の権限は効かない(`services/authz/access_token.go`)。
  レジストリ(package)と組織の操作は「すべて」で作る
- **Forgejo Actions のジョブは `enable-openid-connect: true`** で JWT を取る。fork からの PR では取れない。
  JWT の `workflow` は `name:` ではなく**ファイル名**(`run.WorkflowID`。GitHub とは違う)。
  再利用ワークフロー(`uses: ./...`)のジョブは、**呼ばれる側**のファイルの設定が効き、JWT の `workflow` は**呼ぶ側**のファイル名になる
- **境界は main に書ける人**: main のワークフローを書き換えられる人は、その JWT で持ち主として書ける(シークレットのときと同じ)。
  doa の main に書けるのは bots と Owners だけ(members は読み取り)

| 状態 | 持ち主 | 名前 | 発行者 | クレームのルール | 範囲・スコープ | aud の置き場 | 代わりに消したもの |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **使っている** | yui | repo-config | GitHub Actions | GitHub の 5ym/repo-config、`refs/heads/main`、`forgejo-settings.yml`、push / schedule / workflow_dispatch | すべて・`write:organization` `write:repository` | GitHub の 5ym/repo-config の変数 `FORGEJO_AUDIENCE` | repo-config の secrets `FORGEJO_TOKEN` と yui のトークン `repo-config-settings` |
| 見送り | forgejo-bot | doa-registry | Forgejo Actions | doa の todoroku・tamasagashi・worklog-cloud、`refs/heads/main`、`publish.yml` / `fetch-latest.yml`、push / workflow_dispatch / schedule | すべて・`write:package` | 組織 doa の変数 `REGISTRY_AUDIENCE` | (今は組織の `REGISTRY_TOKEN`) |
| 見送り | forgejo-bot | todoroku-deploy | Forgejo Actions | todoroku、`refs/heads/main`、`publish.yml`、push / workflow_dispatch | todoroku だけ・`write:repository` | todoroku の変数 `DEPLOY_AUDIENCE` | (今は todoroku の `DEPLOY_TOKEN`) |

**forgejo-bot の 2 つは見送った。**forgejo-bot のものは 16.0.5 では画面にも CLI・API にも一覧・変更・削除の手段が無く
(forgejo-bot は画面にログインできない。`ENABLE_INTERNAL_SIGNIN: "false"`)、止めるには DB の `authorized_integration` の行を触ることになる。
17.0.1 でも CLI は `create-authorized-integration` だけで、一覧・削除は無い(2026-10-31 に確かめた)。管理の手段が揃ったら、表のルールで `forgejo admin user create-authorized-integration --username forgejo-bot …` を本番で打ち、
出力の `audience`(`u:<ユーザー ID>:<UUID>`。秘密ではない)を表の変数に入れて、ワークフローの PR
(doa/tamasagashi#106・doa/todoroku#368・doa/worklog-cloud#148。閉じてある)を出し直す。急いで止めるなら forgejo-bot を bots チームから外す
(`prohibit_login` はレジストリを止めない)。doa の ID は 2、リポジトリ ID は todoroku 1・tamasagashi 3・worklog-cloud 4(変更の CLI が無いので、足すときは作り直し)。

yui のもの(repo-config)は画面(設定 → 承認済みインテグレーション → 汎用 JWT)で作った。発行者は `https://token.actions.githubusercontent.com`、
クレームの値は文字列(5ym/repo-config の `repository_id` は 1315588536、`repository_owner_id` は 13718335)。

## ノードからイメージを取る

アプリ側に `imagePullSecrets` は要らない([../../bootstrap/talos.md](../../bootstrap/talos.md)「fj.doany.io の資格情報」)。

## マージはスカッシュ

**組織単位でマージ方法を縛る設定は Forgejo に無い**(15 時点)。既定のマージ方法は `forgejo.yaml` の
`DEFAULT_MERGE_STYLE`、許すマージ方法はリポジトリごと。リポジトリを作ったり取り込んだりしたら、これを当てる:

```shell
curl -X PATCH -H "Authorization: token $T" -H 'Content-Type: application/json' \
  -d '{"allow_merge_commits":false,"allow_rebase":false,"allow_rebase_explicit":false,"allow_fast_forward_only_merge":false,"allow_squash_merge":true,"default_merge_style":"squash","default_delete_branch_after_merge":true}' \
  https://fj.doany.io/api/v1/repos/doa/<name>
```
