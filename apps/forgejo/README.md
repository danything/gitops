# forgejo

`fj.doany.io`。git のホスティングと Forgejo Actions。**GitHub Actions の課金を避けて、CI をこのクラスタで回す**ために置いた。

| ファイル | 中身 |
| --- | --- |
| [application.yaml](application.yaml) | Forgejo 本体(chart `forgejo-helm/forgejo` 17.1.6 = Forgejo 15.0.8 LTS) |
| [postgres.yaml](postgres.yaml) | DB。k8up が `pg_dump` を取る |
| [runner.yaml](runner.yaml) | Runner(v13)+ docker(dind)。`runs-on: ubuntu-latest` をそのまま拾う |
| [httproute.yaml](httproute.yaml) | 公開経路。SSH は出さない(clone / push は HTTPS + トークン) |
| [forgejo-secrets.yaml](forgejo-secrets.yaml) | Infisical から Secret 4 つ |
| [argocd-creds.yaml](argocd-creds.yaml) | ArgoCD が Forgejo のリポジトリを読むための資格情報 |

バックアップは [../k8up/schedules.yaml](../k8up/schedules.yaml)(毎日 14:45 UTC)。

## 使い始め

1. **Infisical に 3 つ入れる(同期より先に)**
   - `/forgejo/forgejo-db`: `postgres-password` ── 英数字だけのランダム(`openssl rand -hex 32` など)。
     postgres は最初の起動でしかパスワードを設定しないので、**後から変えるなら DB 側も変える**
   - `/forgejo/forgejo-admin`: `username` / `password` ── Entra が使えないときの非常口(`admin` は予約語で使えない)
   - `/forgejo/forgejo-oauth`: `key` = アプリ登録 Main のクライアント ID、`secret` = `${prod.auth.auth-secrets.oidc-client-secret}`(値は写さず参照)
2. **Entra のアプリ登録 Main にリダイレクト URI を足す**: `https://fj.doany.io/user/oauth2/entra/callback`(Web)
3. main にマージ → ArgoCD が同期。`https://fj.doany.io` で「entra でサインイン」。
   **アプリロール admin を持つ人だけ入れて、Forgejo の管理者になる**(ゲストは入れない)
4. **Runner を登録**: 管理画面 `/admin/actions/runners` →「Create new runner」。
   出た UUID と Token を Infisical `/forgejo/forgejo-runner` に `uuid` / `token` で入れる。
   Pod が入れ替わり、一覧に Runner が「Idle」で出れば済み

## プライベートのリポジトリを移す(1 本ずつ)

**方針: プライベートは GitHub に置かない**(2026-09-15)。GitHub Actions の課金はプライベートにだけ掛かるので、
公開リポジトリ(gitops・blog など)は GitHub のままでよい。対象は shadai / tamasagashi / worklog-cloud(noren は閉じた)。

**Forgejo が唯一の置き場になる。** バックアップは k8up(R2)の 1 日 1 回だけなので、手元の clone も捨てないこと。

先に 1 回だけ:

1. Forgejo に組織 `danything` を作る
2. ArgoCD 用のアクセストークンを作り(`read:repository` と `read:organization`)、Infisical `/argocd/forgejo-repo-creds` に
   `url` = `https://fj.doany.io/danything` / `username` / `password` = トークン で入れる([argocd-creds.yaml](argocd-creds.yaml))
3. `bootstrap/argocd/repos.yaml` に Forgejo の generator を足す PR をマージする(**Forgejo とトークンが揃ってから**。
   API に届かないと ApplicationSet 全体の生成が止まる)

リポジトリごとに:

1. Forgejo の「新しい移行」で GitHub から取り込む(Issue / PR / リリースも)
2. ワークフローを Forgejo 向けに直す(`.github/workflows/` のままで読まれる)
   - イメージは `ghcr.io/danything/<name>` → `fj.doany.io/danything/<name>`。push はワークフローの `secrets.GITHUB_TOKEN`(Forgejo のトークン)で通る
   - クラスタが pull できるように、アプリの namespace に `imagePullSecrets` を足す(Forgejo の `read:package` トークンを Infisical から `kubernetes.io/dockerconfigjson` で)
   - claude-review(GitHub App)のワークフローは消す。Forgejo では動かない
3. Forgejo で CI とイメージの push が通るのを確かめる
4. **GitHub のリポジトリを消す**。両方に `deploy/argocd.yaml` があると Application 名がぶつかる。
   ApplicationSet は `preserveResourcesOnDeletion: true` なので、Application が作り直されても Pod や PVC は消えない
5. ghcr.io の古いパッケージを消す

## 気をつけること

- **Runner の docker は privileged**。namespace の PSA が `privileged` なのはこのため。
  入れるのは Entra のロール admin を持つ人だけ(`requiredClaimValue`)なので、ジョブを走らせられるのもその人だけ
- dind のイメージ置き場は `emptyDir`。Pod が入れ替わると次のジョブで pull し直す
- Cilium は vxlan なので dind の MTU を 1400 にしてある。1500 に戻すと大きい pull が途中で止まる
