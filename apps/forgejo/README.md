# forgejo

`fj.doany.io`。git のホスティングと Forgejo Actions。**GitHub Actions の課金を避けて、CI をこのクラスタで回す**ために置いた。

| ファイル | 中身 |
| --- | --- |
| [application.yaml](application.yaml) | Forgejo 本体(chart `forgejo-helm/forgejo` 17.1.6 = Forgejo 15.0.8 LTS) |
| [postgres.yaml](postgres.yaml) | DB。k8up が `pg_dump` を取る |
| [runner.yaml](runner.yaml) | Runner(v13)+ docker(dind)。`runs-on: ubuntu-latest` をそのまま拾う |
| [httproute.yaml](httproute.yaml) | 公開経路。SSH は出さない(clone / push は HTTPS + トークン) |
| [forgejo-secrets.yaml](forgejo-secrets.yaml) | Infisical から Secret 3 つ |

バックアップは [../k8up/schedules.yaml](../k8up/schedules.yaml)(毎日 14:45 UTC)。

## 使い始め

1. **Infisical に 2 つ入れる(同期より先に)**
   - `/forgejo/forgejo-db`: `postgres-password`
   - `/forgejo/forgejo-admin`: `username` / `password`(`admin` は Forgejo が予約しているので使えない)
2. main にマージ → ArgoCD が同期。`https://fj.doany.io` に上の管理者で入る
3. **Runner を登録**: 管理画面 `/admin/actions/runners` →「Create new runner」。
   出た UUID と Token を Infisical `/forgejo/forgejo-runner` に `uuid` / `token` で入れる。
   Pod が入れ替わり、一覧に Runner が「Idle」で出れば済み

## リポジトリを移す(1 本ずつ)

ArgoCD の ApplicationSet は GitHub の org を見ている([bootstrap/argocd/repos.yaml](../../bootstrap/argocd/repos.yaml))ので、
**GitHub は残して、Forgejo から GitHub へ push ミラーする**形にする。

1. Forgejo で「新しい移行」→ GitHub から取り込む(Issue / PR も取れる)
2. リポジトリの設定 → ミラー → **push ミラー**で GitHub へ(GitHub の fine-grained トークン、Contents: write)
3. **GitHub 側の Actions を止める**(Settings → Actions → Disable)。止めないとミラーの push で GitHub でも走り、課金が減らない
4. ワークフローは `.github/workflows/` のままで Forgejo が読む(`.forgejo/workflows/` が無ければそちら)。
   `uses: actions/checkout@v4` などは GitHub から取る設定(`DEFAULT_ACTIONS_URL`)
5. `secrets.GITHUB_TOKEN` で ghcr.io に push していたものは、GitHub の PAT(`write:packages`)を Forgejo の Secret に入れて差し替える。
   Forgejo の `GITHUB_TOKEN` は Forgejo 自身のトークンで、GitHub には効かない

**失うもの**: claude-review(GitHub App)は GitHub の PR でしか動かない。PR を Forgejo で開くなら使えなくなる。

## 気をつけること

- **Runner の docker は privileged**。namespace の PSA が `privileged` なのはこのため。
  登録していない人は push できない(`DISABLE_REGISTRATION`)ので、ジョブを走らせられるのは自分だけ
- dind のイメージ置き場は `emptyDir`。Pod が入れ替わると次のジョブで pull し直す
- Cilium は vxlan なので dind の MTU を 1400 にしてある。1500 に戻すと大きい pull が途中で止まる
