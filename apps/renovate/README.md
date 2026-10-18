# renovate

Renovate を CronJob で回す(GitHub Actions の schedule は遅れ、飛ばされることもあるため)。
GitHub の `danything` と `5ym`、Forgejo(fj.doany.io)の `doa` の全リポジトリ。
設定は各リポジトリの `renovate.json`(共通は `github>5ym/repo-config`)。

CronJob `renovate` が 15 分おき(毎時 2・17・32・47 分)に Job を 1 つ作り、その中の 3 つの Pod が並んで回る
(Indexed Job。番号 0・1・2 が GitHub の danything・5ym、Forgejo の doa)。

**Job はいつも成功で終わる**(失敗で CronJob が Degraded になると、ArgoCD が gitops の同期を止めるため。
[renovate.yaml](renovate.yaml) の冒頭)。うまく動いているかはログで見る:

```shell
tools/t.ps1 kubectl -n renovate get jobs
tools/t.ps1 kubectl -n renovate logs job/<名前> --all-pods --prefix
# 待たずに 1 回回す
tools/t.ps1 --admin kubectl -n renovate create job --from=cronjob/renovate renovate-manual
```

## 秘密

Infisical の `/renovate/renovate-secrets`。**無いあいだは、それを使う Pod は何もせずに終わる。**

| キー | 中身 | 使う Pod |
| --- | --- | --- |
| `github-app-private-key` | GitHub App `doa-renovate` の秘密鍵(PEM をそのまま)。App の設定画面の Private keys で作る | danything・5ym |
| `forgejo-token` | Forgejo のユーザー `renovate` のトークン(チーム `bots` = 全リポジトリに書き込み) | forgejo |
| `github-com-token` | 任意。権限なしの GitHub のトークン。github.com のリリースノートやタグを読むときの回数制限(匿名 60 回/時)よけ | forgejo |

GitHub のトークンは実行のたびに App の鍵から作る(1 時間で切れる。[renovate.yaml](renovate.yaml) の `github-app-token.mjs`)。

## クラスタが落ちているとき

Renovate も止まる。予備は置かない。
クラスタが止まっているときはそれを直すのが先で、ほかの依存を上げる PR を出しても仕方がない(Forgejo はそもそもクラスタの上)。戻れば次の実行で追いつく。
