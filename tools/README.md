# tools

手元で使う運用のコマンドを **コンテナで動かす**(2026-10-06 から)。手元の Windows から WSL コンテナで、
[t.ps1](t.ps1) を通して使う(中身は [../compose.yaml](../compose.yaml) の `tools` を `wslc-compose run`)。
版は [Dockerfile](Dockerfile) で固定し、Renovate が上げる。
Linux 用の `tools/t`(docker compose)は、手元が Windows に移ったので消した(2026-10-07)。

```powershell
tools/t.ps1 cf r2 buckets list
tools/t.ps1 sops -d bootstrap/infisical/secrets.yaml
$env:INFISICAL_PROFILE = 'info@doany.io--doa'; tools/t.ps1 infisical secrets --env prod --path /matrix/matrix
tools/t.ps1        # 引数なしならシェルに入る
```

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

- [../compose.yaml](../compose.yaml) の `tools` を `wslc-compose run` で動かす(`winget` で入る wslc-compose)。リポジトリは `/repo` に置く
- **ログインと鍵はリポジトリの `.home/` に置く**(コンテナの中の `HOME`。`.gitignore` 済み)。手元のホームは汚さない。
  cf のログイン(`.config/cloudflare`)、sops の age 鍵(`.config/sops/age/keys.txt`)、infisical のログイン
  (`.infisical` と `infisical-keyring`)、pulumi(`.pulumi`)、kubectl / talosctl(`.kube` / `.talos`)がここに入る。
  kubeconfig と talosconfig は今は無い(k3s の間はノードに ssh して kubectl を使うため。Talos に移ったら置く)。
  `.home/` は本人だけが読める ACL にする
- **`git clean -fdx` で消える**(無視しているファイルも消すため)。age 鍵は `recovery/sops-age.key.age` から戻せる
  (README「Infisical より下の層」)、ほかはログインし直せば戻る
- Dockerfile を変えると、次の `tools/t.ps1` でイメージを作り直す(変わっていなければキャッシュで一瞬)
- パイプやリダイレクトのときは TTY を付けない(`tools/t.ps1` が見分ける)

## wslc の制限

- **wslc は host ネットワークに対応していない。** ブラウザのログインは手元の `localhost:<ポート>` に結果を送ってくるので、
  `infisical login` のときだけ t.ps1 が同じポートで待ち受けて、`wslc exec` の curl でコンテナの中の CLI に渡す。
  `cf auth login` には対応していない
- uid は指定しない(Windows のファイルに持ち主の uid は無い)
- NetBird の exit ノード越しだと `*.doany.io` を外向きの IPv4 で引いたときに届かないので、NetBird の DNS ゾーンで
  内部の 10.0.0.2 に向けている(`nb.doany.io` だけは例外)

## 入れるものの確かめ方

**全部、公式が出しているチェックサムと照らし合わせてから入れる**(2026-10-07)。sops は age 鍵を、infisical は秘密を扱うので、
取得元やミラーで差し替えられても気づけるようにする。一致しなければ組み立てごと止まる。

- kubectl・talosctl・helm・sops・infisical・restic・jq・pulumi: 各リリースのチェックサムのファイル
- age: チェックサムのファイルを出していない(sigsum の証明だけ)ので、Go のモジュールとして `go install` し、
  Go の公開のチェックサムの台帳(sum.golang.org)で確かめる
- cf: npm の integrity

## 版

`# renovate: datasource=… depName=…` の次の `ARG` を Renovate が上げる([../renovate.json](../renovate.json))。
**kubectl と talosctl は talos の群**(自動マージしない)── ノードの版と揃えて上げる。

`gh` と `git` は手元のまま(このリポジトリに限らず使うため)。
