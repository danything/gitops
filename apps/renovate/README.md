# renovate

Renovate を CronJob で回す(2026-10-16〜)。GitHub の `danything` と `5ym`、Forgejo(fj.doany.io)の `doa` の全リポジトリ。
設定は各リポジトリの `renovate.json`(共通は `github>5ym/repo-config`)。

それまでは GitHub Actions(5ym/repo-config の `renovate.yml`)と Forgejo Actions(doa/renovate)で毎時回していたが、
GitHub の schedule は 15〜40 分遅れ、丸ごと飛ばされることもあった。

| CronJob | 対象 | 時刻(毎時) |
| --- | --- | --- |
| `renovate-danything` | GitHub の danything | 2・17・32・47 分 |
| `renovate-5ym` | GitHub の 5ym | 7・22・37・52 分 |
| `renovate-forgejo` | Forgejo の doa | 12・27・42・57 分 |

**Job はいつも成功で終わる**(失敗で CronJob が Degraded になると、ArgoCD が gitops の同期を止めるため。
[renovate.yaml](renovate.yaml) の冒頭)。うまく動いているかはログで見る:

```shell
tools/t.ps1 kubectl -n renovate get jobs
tools/t.ps1 kubectl -n renovate logs job/<名前>
# 待たずに 1 回回す
tools/t.ps1 kubectl -n renovate create job --from=cronjob/renovate-5ym renovate-5ym-manual
```

## 秘密

Infisical の `/renovate/renovate-secrets`。**どれも無いあいだは、その CronJob は何もせずに終わる。**

| キー | 中身 | 使う CronJob |
| --- | --- | --- |
| `github-app-private-key` | GitHub App `doa-renovate` の秘密鍵(PEM をそのまま)。App の設定画面の Private keys で作る | danything・5ym |
| `forgejo-token` | Forgejo のユーザー `renovate` のトークン(チーム `bots` = 全リポジトリに書き込み) | forgejo |
| `github-com-token` | 任意。権限なしの GitHub のトークン。github.com のリリースノートやタグを読むときの回数制限(匿名 60 回/時)よけ | forgejo |

GitHub のトークンは実行のたびに App の鍵から作る(1 時間で切れる。[renovate.yaml](renovate.yaml) の `github-app-token.mjs`)。

## クラスタが落ちているとき

Renovate も止まる。もとの workflow は `workflow_dispatch` だけ残してあるので、急ぐときは手で回す
(GitHub は 5ym/repo-config の Actions → Renovate、Forgejo は doa/renovate の Actions)。
**CronJob と同時に走らせないこと**(同じリポジトリに 2 つの Renovate が触る)。
