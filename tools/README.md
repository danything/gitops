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

- [../compose.yaml](../compose.yaml) の `tools` を `docker compose run` で動かす。リポジトリは `/repo` に置く
- **ログインと鍵はリポジトリの `.home/` に置く**(コンテナの中の `HOME`。`.gitignore` 済み)。手元のホームは汚さない。
  cf のログイン(`.config/cloudflare`)、sops の age 鍵(`.config/sops/age/keys.txt`)、infisical のログイン
  (`.infisical` と `infisical-keyring`)、pulumi(`.pulumi`)、kubectl / talosctl(`.kube` / `.talos`)がここに入る。
  kubeconfig と talosconfig は今は無い(k3s の間はノードに ssh して kubectl を使うため。Talos に移ったら置く)。
  `.home/` は `tools/t` が自分だけ読める権限(700)にする
- **`git clean -fdx` で消える**(無視しているファイルも消すため)。age 鍵は `recovery/sops-age.key.age` から戻せる
  (README「Infisical より下の層」)、ほかはログインし直せば戻る
- **手元のユーザーの uid で動く**ので、作ったファイルの持ち主は自分のまま
- ネットワークは host(`cf auth login` がブラウザから localhost に戻ってくるため)
- Dockerfile を変えると、次の `tools/t` でイメージを作り直す(変わっていなければキャッシュで一瞬)
- パイプやリダイレクトのときは TTY を付けない(`tools/t` が見分ける)

## 版

`# renovate: datasource=… depName=…` の次の `ARG` を Renovate が上げる([../renovate.json](../renovate.json))。
**kubectl と talosctl は talos の群**(自動マージしない)── ノードの版と揃えて上げる。

`gh` と `git` は手元のまま(このリポジトリに限らず使うため)。
