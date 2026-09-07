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

`/etc/k3s-backup/env` は `recovery/restore.sh` が復元する。**復元時はスクリプトが
この Secret も作り直すので手作業は要らない**(2026-09-07 に追加。それまでは作られず、
operator が `CreateContainerConfigError` で上がらなかった)。
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

`apps/mattermost/k8up-schedule.yaml` と `apps/erpnext/k8up-schedule.yaml` の 2 本。
**どちらも論理バックアップ専用**で、PVC のファイルは引き続きホストの `backup/k3s-backup` が見ている。

PVC を取らせない仕掛けは operator の `BACKUP_SKIP_WITHOUT_ANNOTATION=true`
(注釈が無い PVC は対象外)。mattermost の PVC にはそれとは別に
`k8up.io/backup: "false"` も明示してある。**Talos に移ってホストのスクリプトが
使えなくなったら、この設定を外して PVC も k8up に寄せる。**

| | |
| --- | --- |
| バックアップ | mattermost 15:00 UTC / erpnext 15:30 UTC(ホストのスクリプトは 19:00 UTC。restic のロックを避ける) |
| prune | 毎週日曜 16:00 / 16:30 UTC、`keepDaily 7 / keepWeekly 4 / keepMonthly 6`、**タグは `k8up`** |
| 中身 | mattermost `/mattermost-postgres.sql`(9.3 MB)、erpnext `/erpnext-gunicorn.sql`(10.7 MB) |

erpnext だけ形が違う。**chart の `mariadb-sts` の StatefulSet テンプレートに
`podAnnotations` が無い**ので、MariaDB の Pod には注釈を付けられない。代わりに
gunicorn の Pod から `mariadb-dump` を打っている。あちらには `site_config.json`
(`db_host` / `db_name` / `db_password`)と `mariadb-dump` が入っていて、
root のパスワードも要らない。

## CRD がまだ無いクラスタで apps を止めないこと

`Schedule` には `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true` を必ず付ける。

ArgoCD は同期の前にマニフェスト一式を dry-run で検証する。**k8up の CRD が入る前だと
「`k8up.io/v1` が引けない」で `apps/` 配下が丸ごと適用されなくなる** ── CRD を入れる
Application 自身が同じ同期の中にいるので抜けられない(2026-09-07 の復元リハーサルで発覚。
子 Application 5 本が作られなかった)。このリソースだけ dry-run を飛ばせば、CRD を入れる
Application が先に通る。

**「git がバックアップより進んでいる」状態は復元では普通に起きる**ので、
スナップショットが古かったから、では済まない。

## 次にやること

- 残りの namespace の PVC をどうするか。いまはホストのスクリプトが全部見ているので、
  **Talos に移る時点で k8up 側に寄せる**(ホストにシェルが無くなるため)

## ファイルの PVC をどう移すか(2026-09-07 調査)

**Talos にはシェルが無いので、`backup/k3s-backup` の形は持っていけない。** いまホストのスクリプトが
全 PVC を見ているぶんを k8up に寄せる必要がある(ROADMAP の Phase 2)。ただし**そのまま寄せると壊れる**。

### 何が問題か

ホストのスクリプトは **scale down してから取っている**。k8up の PVC バックアップは
**動いたまま**取るので、**開いている DB のファイルをコピーすることになる**。

実際に中を見たら、アプリのデータはほぼ全部 **SQLite の WAL モード**だった:

```
lgtm.db / lgtm.db-shm / lgtm.db-wal
xool.db / xool.db-shm / xool.db-wal
worklog.db / worklog.db-shm / worklog.db-wal
denpa.db (20 MB) / denpa.db-wal (5 MB)
```

restic はファイルを順に読むので、**本体と WAL が別の瞬間のものになりうる**。
「ファイルはホスト、論理は k8up」という今の切り分けは、**ホスト側が scale down している**という
前提の上に成り立っていた。

### 対象と手当て

| PVC | 中身 | どうするか |
| --- | --- | --- |
| `lgtm-db` `xool-db` `worklog-db` `denpa-data` `yosegaki-db` | SQLite(WAL) | **イメージに `sqlite3` を足して `k8up.io/backupcommand`。** どれも自前のイメージなので入れられる |
| `netbird-data` | SQLite(`store.db` / `idp.db`) | **サイドカーを足す。** 上流イメージに `sqlite3` が無く、こちらでは変えられない |
| `portainer-data` | boltdb | **シェルすら無い**(`exec: "sh": executable file not found`)。Portainer の backup API(`POST /api/backup`)を叩くサイドカーか、この 1 本だけ別扱い |
| `adguardhome-*` `denpa-library` `erpnext-sites` `mattermost-data` `lgtm-images` `lgtm-assets` `xool-assets` `yuzuriha-data` `agent-config` `netbird-routing-peer-data` | ファイル | **そのまま `k8up.io/backup: "true"` でよい。** 書き換わっても部分的に古いだけで壊れない |
| `data-erpnext-mariadb-sts-0` `data-postgresql-0` `postgres-data` | RDBMS | **もう論理バックアップがある**。PVC 側は `false` のまま |
| `denpa-recorded` | 生 TS の作業領域 | 取らない(容量。docs/decisions.md「バックアップに何を含めるか」) |

### 確認したこと

```
lgtm / xool / worklog / denpa / yosegaki … sqlite3 無し
portainer                                … sh すら無い
```

**どのイメージにも `sqlite3` が入っていない。** つまり「注釈を足すだけ」では終わらず、
**自前イメージ 5 つに `sqlite3` を足す PR が要る**(Alpine なら `apk add --no-cache sqlite` の 1 行)。

`backupcommand` はこの形になる:

```yaml
annotations:
  k8up.io/backupcommand: sh -c 'sqlite3 /usr/src/app/data/lgtm.db ".backup /tmp/b" && cat /tmp/b'
  k8up.io/file-extension: .db
```

`.backup` は**開いたままでも整合したコピーを作る**ので、scale down が要らなくなる。
`VACUUM INTO` でもよいが、どちらも出力先に実ファイルが要るので `/tmp` を経由する。
