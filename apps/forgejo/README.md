# forgejo

`fj.doany.io`。git のホスティングと Forgejo Actions。**GitHub Actions の課金を避けて、CI をこのクラスタで回す**ために置いた。

| ファイル | 中身 |
| --- | --- |
| [forgejo.yaml](forgejo.yaml) | Forgejo 本体(最新を追う)。chart は使わない(理由はファイルの先頭) |
| [postgres.yaml](postgres.yaml) | DB。k8up が `pg_dump` を取る |
| [runner.yaml](runner.yaml) | Runner(v13)+ docker(dind)。`runs-on: ubuntu-latest` をそのまま拾う |
| [httproute.yaml](httproute.yaml) | 公開経路。SSH は出さない(clone / push は HTTPS + トークン) |
| [forgejo-secrets.yaml](forgejo-secrets.yaml) | Infisical から Secret 3 つ |
| [argocd-creds.yaml](argocd-creds.yaml) | ArgoCD が Forgejo のリポジトリを読むための資格情報 |

バックアップは [../k8up/schedules.yaml](../k8up/schedules.yaml)(毎日 14:45 UTC)。

## 使い始め

1. **Infisical に 2 つ入れる(同期より先に)**
   - `/forgejo/forgejo-db`: `postgres-password` ── 英数字だけのランダム(`openssl rand -hex 32` など)。
     postgres は最初の起動でしかパスワードを設定しないので、**後から変えるなら DB 側も変える**
   - `/forgejo/forgejo-oauth`: `key` = `b0fa498f-7e6a-4fe1-a1c6-16fbbb6f397e`(Main のクライアント ID。秘密ではなく bootstrap/auth にも平文で書いてある)、`secret` = `${prod.auth.auth-secrets.oidc-client-secret}`(値は写さず参照)
2. Entra のアプリ登録 Main のリダイレクト URI(Web)に `https://fj.doany.io/user/oauth2/entra/callback` ── **2026-09-15 に `az ad app update` で追加済み**
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

**方針: プライベートは GitHub に置かない**(2026-09-15)。GitHub Actions の課金はプライベートにだけ掛かるので、
公開リポジトリ(gitops・blog など)は GitHub のままでよい。対象は shadai / tamasagashi / worklog-cloud(noren は閉じた)。

**Forgejo が唯一の置き場になる。** バックアップは k8up(R2)の 1 日 1 回だけなので、手元の clone も捨てないこと。

先に 1 回だけ:

1. Forgejo に組織 `doa` を作る
2. ArgoCD 用のアクセストークンを作り(`read:repository` と `read:organization`)、Infisical `/argocd/forgejo-repo-creds` に
   `url` = `https://fj.doany.io/doa` / `username` / `password` = トークン で入れる([argocd-creds.yaml](argocd-creds.yaml))。
   **スコープは repository・organization・issue の読み取り。** issue が無いと、非公開リポジトリができた時点で
   ApplicationSet が `token does not have at least one of required scope(s): [read:issue]` で止まる(2026-09-15)
3. `bootstrap/argocd/repos.yaml` に Forgejo の generator を足す PR をマージする(**Forgejo とトークンが揃ってから**。
   API に届かないと ApplicationSet 全体の生成が止まる)。
   **2026-10-05 に `repos-forgejo` という別の ApplicationSet に分けた。** 同居していると、まっさらな
   クラスタ(Forgejo が空で、トークンもまだ無い)で GitHub 側の Application まで 1 本も作られず、
   Forgejo 自身もデプロイされないので抜けられなかった。いまは止まるのは Forgejo 側だけ

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

- **テナントのゲスト(もとは ERPNext のために招いた人)も tid が同じなので members に入る。** 外したくなったら Forgejo 専用のアプリ登録を作り、
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
`HasOrgOrUserVisible`。2026-09-15 に shadai のイメージが匿名で取れるのを見つけて limited にした)。

## Actions からイメージを push するとき

**ワークフローの自動トークン(`GITHUB_TOKEN`)ではパッケージに書けない**(Forgejo 15。`services/packages/perm.go` に
`TODO: ActionUser permission check` とあり、Actions のユーザーは組織のメンバー扱いにならない)。
**秘密は置かない。** 下の承認済みインテグレーションで、ジョブの JWT を bot ユーザー `forgejo-bot` として通し、
`docker login fj.doany.io -u forgejo-bot`(パスワードに JWT)する。前は組織の Actions のシークレット `REGISTRY_TOKEN`
(forgejo-bot の `write:package` だけのトークン)だった。

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
  JWT の `workflow` は `name:` ではなく**ファイル名**(`run.WorkflowID`。2026-10-07 に実ジョブの JWT で確かめた。GitHub とは違う)。
  再利用ワークフロー(`uses: ./...`)のジョブは、**呼ばれる側**のファイルの設定が効き、JWT の `workflow` は**呼ぶ側**のファイル名になる
- **境界は main に書ける人**: main のワークフローを書き換えられる人は、その JWT で持ち主として書ける(シークレットのときと同じ)。
  doa の main に書けるのは bots と Owners だけ(members は読み取り)

| 持ち主 | 名前 | 発行者 | クレームのルール | 範囲・スコープ | aud の置き場 |
| --- | --- | --- | --- | --- | --- |
| forgejo-bot | doa-registry | Forgejo Actions | doa の todoroku・tamasagashi・worklog-cloud、`refs/heads/main`、`publish.yml` / `fetch-latest.yml`、push / workflow_dispatch / schedule | すべて・`write:package` | 組織 doa の変数 `REGISTRY_AUDIENCE` |
| forgejo-bot | todoroku-deploy | Forgejo Actions | todoroku、`refs/heads/main`、`publish.yml`、push / workflow_dispatch | todoroku だけ・`write:repository` | todoroku の変数 `DEPLOY_AUDIENCE` |
| yui | repo-config | GitHub Actions | GitHub の 5ym/repo-config、`refs/heads/main`、`forgejo-settings.yml`、push / schedule / workflow_dispatch | すべて・`write:organization` `write:repository` | GitHub の 5ym/repo-config の変数 `FORGEJO_AUDIENCE` |

aud はインテグレーションを作ると決まる(`u:<ユーザー ID>:<UUID>`)。秘密ではないので変数に置く。
**doa にイメージを出すリポジトリを足したら、doa-registry のリポジトリ ID も足す**(変更の CLI が無いので作り直し。aud が変わる)。

**forgejo-bot は画面にログインできない**(`ENABLE_INTERNAL_SIGNIN: "false"`)ので、forgejo-bot のものは本番の CLI で作る。
一覧・変更・削除の CLI と API は無い(16.0.5)。急いで止めるなら、forgejo-bot を組織 doa の bots チームから外す
(パッケージもリポジトリも書けなくなる。トークンも巻き込む)。`prohibit_login` は API と git は止めるが、
レジストリは止めない(`routers/api/packages` は見ていない)。消すのは DB の `authorized_integration`
(と `authorized_integ_resource_repo`)の行。

```shell
# doa-registry(リポジトリ ID は 1 = todoroku、3 = tamasagashi、4 = worklog-cloud。組織 doa の ID は 2)
kubectl -n forgejo exec deploy/forgejo-web -c forgejo -- forgejo admin user create-authorized-integration \
  --username forgejo-bot --name doa-registry \
  --description "doa の main の publish がイメージを push する" \
  --issuer urn:forgejo:authorized-integrations:actions \
  --claim-eq repository_owner_id=2 --claim-eq ref=refs/heads/main \
  --claim-in repository_id=1,3,4 --claim-in workflow=publish.yml,fetch-latest.yml \
  --claim-in event_name=push,workflow_dispatch,schedule \
  --scope write:package --repo all

# todoroku-deploy
kubectl -n forgejo exec deploy/forgejo-web -c forgejo -- forgejo admin user create-authorized-integration \
  --username forgejo-bot --name todoroku-deploy \
  --description "todoroku の publish が deploy-bump を push して PR を作り、マージを予約する" \
  --issuer urn:forgejo:authorized-integrations:actions \
  --claim-eq repository_id=1 --claim-eq ref=refs/heads/main --claim-eq workflow=publish.yml \
  --claim-in event_name=push,workflow_dispatch \
  --scope write:repository --repo doa/todoroku
```

出力の `audience` を変数に入れる(`POST /api/v1/orgs/doa/actions/variables/REGISTRY_AUDIENCE`、
`POST /api/v1/repos/doa/todoroku/actions/variables/DEPLOY_AUDIENCE`。本文は `{"value": "<audience>"}`)。
yui のもの(repo-config)は画面(設定 → 承認済みインテグレーション → 汎用 JWT)で作る。発行者は
`https://token.actions.githubusercontent.com`、範囲は「すべて」、スコープは organization と repository を「読み取りと書き込み」。
ルール(GitHub の 5ym/repo-config の ID は 1315588536、5ym は 13718335。クレームの値は文字列):

```json
{"rules": [
  {"claim": "repository_id", "compare": "eq", "value": "1315588536"},
  {"claim": "repository_owner_id", "compare": "eq", "value": "13718335"},
  {"claim": "ref", "compare": "eq", "value": "refs/heads/main"},
  {"claim": "workflow_ref", "compare": "eq", "value": "5ym/repo-config/.github/workflows/forgejo-settings.yml@refs/heads/main"},
  {"claim": "event_name", "compare": "in", "values": ["push", "schedule", "workflow_dispatch"]}
]}
```

## ノードからイメージを取る

ホストからは Gateway の 443 に繋がらないので、[node-access.yaml](node-access.yaml) の中継 + ホストの `/etc/hosts`
(`10.43.200.10 fj.doany.io`)+ `/etc/rancher/k3s/registries.yaml` の資格情報(info の `read:package`)。
アプリ側に `imagePullSecrets` は要らない。Talos では [../../talos/README.md](../../talos/README.md)。

## マージはスカッシュ

**組織単位でマージ方法を縛る設定は Forgejo に無い**(15 時点)。既定のマージ方法は `forgejo.yaml` の
`DEFAULT_MERGE_STYLE`、許すマージ方法はリポジトリごと。リポジトリを作ったり取り込んだりしたら、これを当てる:

```shell
curl -X PATCH -H "Authorization: token $T" -H 'Content-Type: application/json' \
  -d '{"allow_merge_commits":false,"allow_rebase":false,"allow_rebase_explicit":false,"allow_fast_forward_only_merge":false,"allow_squash_merge":true,"default_merge_style":"squash","default_delete_branch_after_merge":true}' \
  https://fj.doany.io/api/v1/repos/doa/<name>
```

2026-09-15 に shadai / renovate / tamasagashi / worklog-cloud へ当てた。
