# k8up

Talos に移ったあとのバックアップの担い手。いまの `backup/k3s-backup` は
「サーバに入って PVC のディレクトリを restic に流す」形なので、**ホストにシェルが無い Talos では成立しない**。
k8up は Pod として同じ restic リポジトリ(Cloudflare R2 の `doany-restic`)に書く。

**いまは operator を置いてあるだけで `Schedule` は無い。** 本番のバックアップは引き続きホストのスクリプト。

## 秘密の渡し方

**`Schedule` や `Backup` に `backend` を書かない。** 書くと endpoint(Cloudflare のアカウント ID を含む)が
git に載る。代わりに **operator の環境変数(グローバル設定)**に寄せて、`backend` を持たない
`Backup` はそこへ落ちるようにしてある。

Secret は手で作る(値が手元を通らないよう、ホストの env ファイルから割って入れる):

```shell
sudo sh -c '. /etc/k3s-backup/env
  raw="${RESTIC_REPOSITORY#s3:}"
  k3s kubectl -n k8up create secret generic k8up-global \
    --from-literal=endpoint="${raw%/*}" \
    --from-literal=bucket="${raw##*/}" \
    --from-literal=accessKeyId="$AWS_ACCESS_KEY_ID" \
    --from-literal=secretAccessKey="$AWS_SECRET_ACCESS_KEY" \
    --from-literal=repoPassword="$RESTIC_PASSWORD" \
    --dry-run=client -o yaml | k3s kubectl apply -f -'
```

`/etc/k3s-backup/env` は `recovery/restore.sh` が復元するので、まっさらから戻すときもこの 1 コマンドで済む。
**Talos に移ったら Infisical に移す**(ホストに env ファイルが無くなるため)。

## 確かめたこと(2026-09-07)

- **`backend.envFrom` だけでは動かない。** k8up は `Backend` が nil でなければ
  `RESTIC_REPOSITORY` を**空の literal env として必ず入れる**ので、`envFrom` の値が上書きされる。
  実際に `Fatal: Please specify repository location` で落ちた。
  グローバル設定に寄せる(`backend` を書かない)のが正解。
- `backend` を持たない `Backup` が R2 へ書けることを、使い捨ての PVC で確認済み(確認後に削除)。
- **ホストのスクリプトとは衝突しない。** あちらは `restic forget --tag k3s-host` でタグを絞っているので、
  k8up のスナップショット(タグ無し・`hostname` は namespace)を消さない。
  **逆方向は確認した(2026-09-07)**: k8up の `Prune` は `retention.tags` を書かないと
  `restic forget` を**リポジトリ全体**に効かせる(`operator/prunecontroller/executor.go` の
  `setupArgs` はタグがあるときだけ `--tag` を渡す)。バックアップに `tags: [k8up]`、
  prune に `retention.tags: [k8up]` を付けて隔離すること。**これを忘れるとホストの
  スナップショットが消える。**

## いま動いているもの

`apps/mattermost/k8up-schedule.yaml` の 1 本だけ。**論理バックアップ専用**で、
PVC のファイルは引き続きホストの `backup/k3s-backup` が見ている
(mattermost の PVC には `k8up.io/backup: "false"` を付けてある)。

| | |
| --- | --- |
| バックアップ | 毎日 15:00 UTC(ホストのスクリプトは 19:00 UTC。restic のロックを避ける) |
| prune | 毎週日曜 16:00 UTC、`keepDaily 7 / keepWeekly 4 / keepMonthly 6`、**タグは `k8up`** |
| 中身 | `/mattermost-postgres.sql`(実測 9.3 MB) |

## 次にやること

- erpnext の MariaDB も同じ形に。chart 管理の StatefulSet なので values 経由になる
- 残りの namespace の PVC をどうするか。いまはホストのスクリプトが全部見ているので、
  **Talos に移る時点で k8up 側に寄せる**(ホストにシェルが無くなるため)
