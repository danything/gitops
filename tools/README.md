# tools

手元で使う運用のコマンドを **Docker で動かす**(2026-10-06 から)。手元に入れるのは Docker だけで、
版は [Dockerfile](Dockerfile) で固定し、Renovate が上げる。

```sh
tools/t cf r2 buckets list
tools/t sops -d bootstrap/infisical/secrets.yaml
INFISICAL_PROFILE=info@doany.io--doa tools/t infisical secrets --env prod --path /matrix/matrix
tools/t            # 引数なしならシェルに入る
```

fish なら `abbr -a t ~/dev/gitops/tools/t` などで短くしておくと楽。

| 入っているもの | 用途 |
| --- | --- |
| cf | Cloudflare(R2 など) |
| sops / age | `bootstrap/` と `talos/` の暗号化したファイル |
| infisical | 秘密の読み書き |
| kubectl / talosctl / helm | クラスタ(Talos の移行後は手元から直接) |
| restic | R2 のバックアップの中身を見る・戻す |
| pulumi / bun | `pulumi/`(ふだんは CI が流す) |
| jq | 上の出力の加工 |

## 仕組み

- [../compose.yaml](../compose.yaml) の `tools` を `docker compose run` で動かす。リポジトリは `/repo` に、
  各コマンドのログインと鍵は**手元の置き場所をそのまま**差し込む(`~/.config/cloudflare`、`~/.config/sops`、
  `~/.infisical` と `~/infisical-keyring`、`~/.kube`、`~/.talos`、`~/.pulumi`)。無ければ `tools/t` が空で作る
- **手元のユーザーの uid で動く**ので、作ったファイルの持ち主は自分のまま
- ネットワークは host(`cf auth login` がブラウザから localhost に戻ってくるため)
- Dockerfile を変えると、次の `tools/t` でイメージを作り直す(変わっていなければキャッシュで一瞬)
- パイプやリダイレクトのときは TTY を付けない(`tools/t` が見分ける)

## 版

`# renovate: datasource=… depName=…` の次の `ARG` を Renovate が上げる([../renovate.json](../renovate.json))。
**kubectl と talosctl は talos の群**(自動マージしない)── ノードの版と揃えて上げる。

`gh` と `git` は手元のまま(このリポジトリに限らず使うため)。
