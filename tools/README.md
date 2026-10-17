# tools

手元で使う運用のコマンドを **コンテナで動かす**(2026-10-06 から)。手元の Windows から WSL コンテナで、
[t.ps1](t.ps1) を通して使う(中身は [../compose.yaml](../compose.yaml) の `tools` を `wslc-compose run`)。
版は [Dockerfile](Dockerfile) で固定し、Renovate が上げる。
Linux 用の `tools/t`(docker compose)は、手元が Windows に移ったので消した(2026-10-07)。

```powershell
tools/t.ps1 cf r2 buckets list
tools/t.ps1 sops -d bootstrap/infisical/secrets.yaml
$env:INFISICAL_PROFILE = 'info@doany.io--doa'; tools/t.ps1 infisical secrets --env prod --path /matrix/matrix
tools/t.ps1 kubectl get pods -A           # クラスタは読み取り用で繋ぐ
tools/t.ps1 --admin kubectl apply -f x.yaml  # 書くときだけ管理者(下の「クラスタの資格情報」)
tools/t.ps1        # 引数なしならシェルに入る
```

| 入っているもの | 用途 |
| --- | --- |
| cf | Cloudflare(R2 など) |
| sops / age | `bootstrap/` と `talos/` の暗号化したファイル |
| infisical | 秘密の読み書き |
| kubectl / talosctl / helm | クラスタ(資格情報は下の「クラスタの資格情報」) |
| restic | R2 のバックアップの中身を見る・戻す |
| pulumi / bun | `pulumi/`(ふだんは CI が流す) |

**jq はここに入れず、手元に置く**(dotfiles の `init.ps1` が winget で入れる。2026-10-07)。上の出力の加工は
`tools/t.ps1 … | jq …` のようにコンテナの外でする(コンテナを起こすほどではなく、パイプの先で使うことが多いため)。

## 仕組み

- [../compose.yaml](../compose.yaml) の `tools` を `wslc-compose run` で動かす(`winget` で入る wslc-compose)。リポジトリは `/repo` に置く
- **ログインと鍵はリポジトリの `.home/` に置く**(コンテナの中の `HOME`。`.gitignore` 済み)。手元のホームは汚さない。
  cf のログイン(`.config/cloudflare`)、sops の age 鍵(`.config/sops/age/keys.txt`)、infisical のログイン
  (`.infisical` と `infisical-keyring`)、pulumi(`.pulumi`)がここに入る。
  クラスタの資格情報はここにも置かない(下の「クラスタの資格情報」)。
  `.home/` は本人だけが読める ACL にする
- **`git clean -fdx` で消える**(無視しているファイルも消すため)。age 鍵は `recovery/sops-age.key.age` から戻せる
  (README「Infisical より下の層」)、ほかはログインし直せば戻る
- Dockerfile を変えると、次の `tools/t.ps1` でイメージを作り直す(変わっていなければキャッシュで一瞬)
- パイプやリダイレクトのときは TTY を付けない(`tools/t.ps1` が見分ける)
- PowerShell でパイプしたもの(`tools/t.ps1 sops -d … | tools/t.ps1 --admin kubectl apply -f -`)は、`t.ps1` がコンテナの標準入力に流し直す。
  行を LF でつないだ UTF-8 にして渡す(PowerShell のまま流すと CRLF になり、5.1 では日本語が `?` に化けるため、
  base64 で包んでコンテナの中で戻す)。PowerShell のパイプは行(文字列)単位なので、バイナリは通らない。
  バイナリはファイルに書いてリポジトリの中から読ませる
- `t.ps1` は **BOM 付きの UTF-8** にしてある。BOM が無いと Windows PowerShell 5.1 が Shift_JIS として読み、
  日本語のコメントで構文が壊れる(2026-10-07 まで 5.1 では動かなかった)

## クラスタの資格情報

**kubectl・talosctl・helm は、クラスタに繋ぐときだけ資格情報をコンテナの中で作るか復号して渡す**(2026-10-17。
[creds.sh](creds.sh))。置き場はコンテナの `/dev/shm`(tmpfs)で、コンテナと一緒に消える。
**平文は手元のディスクにも `.home/` にも残らない。** age 鍵(上の「仕組み」)が無いと止まる。

**既定は読み取り用。管理者は `tools/t.ps1 --admin …` と書いたときだけ。** 書く操作(`apply`・`delete`・
`create job` など)は `--admin` を付ける。`--admin` はシェルにも効く(`tools/t.ps1 --admin`)。
**誤操作を防ぐための分け方で、権限の境界ではない**(どちらも同じ age 鍵から作れる)。

| | 読み取り用(既定) | 管理者(`--admin`) |
| --- | --- | --- |
| kubectl / helm | その場で作る。`talos/secrets.yaml` の Kubernetes の CA で、グループ `entra:viewer` の証明書(1 日で切れる) | `talos/kubeconfig.yaml`(SOPS 済み)を復号する |
| talosctl | その場で作る。Talos の CA で `os:reader` の証明書(1 日で切れる) | 同じく `os:admin` |

- 読み取り用の権限は [`../bootstrap/apiserver/rbac.yaml`](../bootstrap/apiserver/rbac.yaml) の `entra:viewer`
  (組み込みの `view` と `readonly-extra`。ログは読めて、Secret は読めない)。Headlamp で Entra の viewer が持つものと同じ
- **helm はリリースの情報を Secret に持つ**ので、`helm list` や `helm status` も `--admin` を付ける
- **talosconfig は保存しない**([../docs/decisions.md](../docs/decisions.md)「手で持つもの」)。`secrets.yaml` から毎回作る
- 管理者の kubeconfig だけはファイルで持つ。Talos が出す正式なもの(`talosctl kubeconfig`)を使い、証明書は 1 年で切れる。
  中身は `secrets.yaml` の CA で作れるものなので、置いても開けられる範囲は今と変わらない
- 行き先はどれも `10.0.0.2`(`talos/render.sh` と同じ)。`KUBECONFIG` / `TALOSCONFIG` や `--kubeconfig` / `--talosconfig` /
  `--server` を自分で渡したときは何もしない。繋がないもの(`kubectl kustomize`、`helm template`、`talosctl gen`、`--client` など)も同じ

**管理者の kubeconfig の入れ方**(作り直すときも同じ。切れる前に):

```powershell
tools/t.ps1 --admin sh -c 'talosctl kubeconfig /dev/shm/k && sops -e --filename-override talos/kubeconfig.yaml /dev/shm/k > talos/kubeconfig.yaml'
tools/t.ps1 --admin kubectl get nodes   # 確かめる
git add talos/kubeconfig.yaml           # 暗号化済み(`sops:` がある)ことを見てからコミットする
```

`talosctl kubeconfig` が書き出す先も暗号化の入力も `/dev/shm` なので、平文は一度もディスクに出ない。
規則は [`../.sops.yaml`](../.sops.yaml)。平文の `kubeconfig` / `talosconfig` という名前のファイルは `.gitignore` 済みで、
`creds.sh` も暗号化されていない `talos/kubeconfig.yaml` は使わずに止まる。

## wslc の制限

- **wslc は host ネットワークに対応していない。** ブラウザのログインは手元の `localhost:<ポート>` に結果を送ってくるので、
  `infisical login` のときだけ t.ps1 が同じポートで待ち受けて、`wslc exec` の curl でコンテナの中の CLI に渡す。
  `cf auth login` には対応していない
- uid は指定しない(Windows のファイルに持ち主の uid は無い)
- **標準入力が NUL のところ(Claude Code のツールなど)では、`wslc-compose run` がつなぐ標準入力が無効なハンドルになる。**
  1 秒ほど以上かかるコマンドの出力が落ちて `ERROR_INVALID_HANDLE` で終わるので、`t.ps1` はそのときだけ空のパイプを渡す(2026-10-07)。
  NUL かどうかは標準入力の種類(`GetFileType`)で見分けるので、ファイルや外のパイプからの入力は今までどおり届く
- NetBird の exit ノード越しだと `*.doany.io` を外向きの IPv4 で引いたときに届かないので、NetBird の DNS ゾーンで
  内部の 10.0.0.2 に向けている(`nb.doany.io` だけは例外)

## 入れるものの確かめ方

**全部、公式が出しているチェックサムと照らし合わせてから入れる**(2026-10-07)。sops は age 鍵を、infisical は秘密を扱うので、
取得元やミラーで差し替えられても気づけるようにする。一致しなければ組み立てごと止まる。

- kubectl・talosctl・helm・sops・infisical・restic・pulumi: 各リリースのチェックサムのファイル
- age: チェックサムのファイルを出していない(sigsum の証明だけ)ので、Go のモジュールとして `go install` し、
  Go の公開のチェックサムの台帳(sum.golang.org)で確かめる
- cf: npm の integrity

## 版

`# renovate: datasource=… depName=…` の次の `ARG` を Renovate が上げる([../renovate.json](../renovate.json))。
**kubectl と talosctl は talos の群**(自動マージしない)── ノードの版と揃えて上げる。

`gh`・`git`・`jq` は手元のまま(このリポジトリに限らず使うため。dotfiles の `init.ps1` が winget で入れる)。
