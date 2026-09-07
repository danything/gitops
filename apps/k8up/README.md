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
  **逆方向は未確認** — k8up の `Prune` はリポジトリ全体を見るので、**入れるときにスコープを確かめること。**

## 次にやること

- `Schedule` を namespace ごとに置く(k8up は Schedule と同じ namespace の PVC だけを見る)
- DB は `k8up.io/backupcommand` 注釈で dump を流す(ファイルコピーではなく論理バックアップにする)。
  ホストのスクリプトには無い利点で、**ここが k8up を入れる本当の動機**
- `Prune` のスコープを確かめてから retention を決める
