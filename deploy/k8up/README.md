# k8up

バックアップの担い手。ノードにシェルが無いので、Pod として restic リポジトリ(Cloudflare R2 の `doany-restic`)に書く。
論理バックアップもファイルの PVC も k8up が取り、etcd のスナップショットも同じリポジトリへ([etcd-snapshot.yaml](etcd-snapshot.yaml))。
**戻す手順は [../../recovery/README.md](../../recovery/README.md)**(Infisical は 6、ほかは 8。道具は [pv.sh](../../recovery/pv.sh))。

## 何をどう取っているか

`Schedule` は [schedules.yaml](schedules.yaml) に 15 本(14 本が namespace ごとの backup + prune、1 本がリポジトリ全体の `check`)。
時刻と決まりごともあちら。**注釈だけでは動かない** ── その namespace に `Schedule` が無いとジョブが作られない。
**取る中身を決めているのは Pod と PVC の注釈**で、それがどこにあるかがここ。

| namespace | 中身 | `k8up.io/backupcommand` の在処 |
| --- | --- | --- |
| forgejo | postgres の `pg_dump` + リポジトリの PVC(ファイル) | [../forgejo/postgres.yaml](../forgejo/postgres.yaml) |
| rybbit | postgres の `pg_dump` + ClickHouse の PVC(ファイル。パートは追記だけなので動いたまま取る) | [../rybbit/postgres.yaml](../rybbit/postgres.yaml) / [../rybbit/clickhouse.yaml](../rybbit/clickhouse.yaml) |
| infisical | postgres の `pg_dump` | `bootstrap/infisical-values.sops.yaml` の `postgresql.primary.podAnnotations` |
| lgtm / xool / worklog / denpa / yosegaki / todoroku | SQLite を `serialize()` した 1 ファイル | 各アプリのリポジトリの `deploy/`(denpa と yosegaki は chart) |
| netbird | `store.db` / `idp.db` / `events.db` を tar 1 本に(bun のサイドカー) | [../netbird/deployment.yaml](../netbird/deployment.yaml) |
| matrix | Tuwunel 自身のバックアップと `media/` を tar 1 本に(DB は動いたまま写さない) | [../matrix/tuwunel.yaml](../matrix/tuwunel.yaml) |
| adguardhome / yuzuriha / ashi | ファイルだけ(下の表) | ─ |

**SQLite は `bun -e` の `serialize()` で取る。** ファイルをそのまま写すと本体と `-wal` が別の瞬間のものになりうる。
`serialize()` は pager を通すので 1 つのコミット済みの状態が出る。自前のアプリは全部 bun なのでイメージに何も足さない。
注釈は k8up が `qsplit` でシェル風に分割する(`restic/kubernetes/pod_exec.go`)ので、スクリプトに空白を入れない。
放置された `-journal` があると `SQLITE_READONLY_ROLLBACK` で落ちる(黙って壊れたコピーが残るよりよい)。

Infisical の Postgres は**クラスタで一番失えないデータ**(全アプリの秘密)。DB は `ENCRYPTION_KEY` で暗号化されているので、
**復元にはその鍵も要る**。Schedule はアプリ層の関心事なので、本体が `bootstrap/` に居ても `deploy/` に置いてある。

### ファイルの PVC

`k8up.io/backup: "true"` を付けたものだけ取る(operator が `skipWithoutAnnotation`)。`"false"` と注釈が無いのは同じ意味。
同じファイルに `"true"` が並ぶときだけ、取らない側にも `"false"` を書いて意図を見せる。

| PVC | 中身 | どうするか |
| --- | --- | --- |
| `adguardhome-conf` `adguardhome-work` `netbird-routing-peer-data` `forgejo-repos` `clickhouse-data`(rybbit) | ファイル | gitops で `"true"` |
| `denpa-encoded` `agent-config` `lgtm-images` `xool-assets` `yuzuriha-data` `ashi-data` `todoroku-files` | ファイル | 各アプリのリポジトリで `"true"` |
| `lgtm-db` `xool-db` `worklog-db` `yosegaki-db` | SQLite だけ | `backupcommand` で取るので PVC は取らない |
| `denpa-data` | SQLite + ファイル | `"true"` + `k8up.io/backup-restic-args: '["--exclude","denpa.db*"]'`(DB は `backupcommand`)。**この注釈は JSON で、パースに失敗するとその PVC が黙って飛ばされる**(`operator/backupcontroller/executor.go`)ので、変えたら実物を見る |
| `netbird-data` `tuwunel-data` | DB + 再取得できるファイル | `"false"`。DB はサイドカーの `backupcommand` |
| `data-postgresql-0`(infisical) `postgres-data`(forgejo / rybbit) | RDBMS | 論理バックアップがあるので取らない |
| `denpa-raw` | 生 TS の作業領域 | 取らない(数時間で入れ替わり、14 GB まで育つ) |

録画(`denpa-encoded`)だけ世代を持たない([denpa-encoded-forget.yaml](denpa-encoded-forget.yaml))。

## 秘密の渡し方

**`Schedule` や `Backup` に `backend` を書かない。** 書くと endpoint(Cloudflare のアカウント ID を含む)が git に載る。
operator の環境変数(グローバル設定、[application.yaml](application.yaml))に寄せてある。
`backend.envFrom` では駄目 ── `backend` があると k8up は `RESTIC_REPOSITORY` を空の env として必ず入れ、上書きされる。

**Secret `k8up-global` の正本は Infisical**(`/k8up/k8up-global`、[k8up-secrets.yaml](k8up-secrets.yaml))。
キーは `endpoint` / `bucket` / `accessKeyId` / `secretAccessKey` / `repoPassword` / `mattermostWebhook` の 6 つで、
**足りないとバックアップが全部落ちる**。値を変えたら `kubectl -n k8up rollout restart deploy/k8up`
(chart が `podAnnotations` しか出さないので auto-reload は使えない。例外は k8up-secrets.yaml)。

**建て直しのときは k8up で Infisical を戻せない。** この Secret が Infisical から来るのに、Infisical のダンプは R2 にある。
Infisical だけは手元の restic で `recovery/env.age` を使って戻す(recovery/README.md の 6)。

`mattermostWebhook` は [notify.yaml](notify.yaml) と [restore-check.yaml](restore-check.yaml) が使う(`env.age` の `MATTERMOST_WEBHOOK` と同じ値)。
名前は据え置きで、中身はいま Matrix の部屋 `server` の webhook([../matrix/README.md](../matrix/README.md)「通知のルーム」)。

## 失敗したときに気づけるようにする

**k8up には通知が無く、ArgoCD の通知は Application しか見ない。** [notify.yaml](notify.yaml) の CronJob が日次(18:00 UTC)で
restic の中身を数えて 1 行投げる(成功時も。通知の仕組みが生きていることの確認)。見張りの中身はあちらのコメント。

**[restore-check.yaml](restore-check.yaml) が毎月 1 日 06:00 UTC に、(host, path) ごとの最新を取り出して開く。**
notify は「取れたか」しか見ず、壊れた SQLite や途中で切れたダンプでも新しいスナップショットはできるため。

| 中身 | 何を見るか |
| --- | --- |
| SQLite(`.db`) | `PRAGMA integrity_check` が ok、表が 1 つ以上 |
| `pg_dump`(`.sql`) | 使い捨ての postgres 17 に流して `ERROR` が 0 行。ロールはダンプの `OWNER TO` から先に作る |
| tar | 展開できる。netbird は 3 つの DB を SQLite と同じく、matrix は `backups/meta/<番号>` が指すファイルが全部あるか |
| ファイルの PVC・etcd | `restic ls` が通って合計が 0 バイトでない(取り出さない) |

restic は全部 `--no-lock`。OOMKilled や期限切れで投稿まで届かないときは、notify が CronJob の `lastSuccessfulTime` で拾う。

## 空のスナップショット

**k8up のバックアップ Pod は既定で nonroot(65532)で走り、`0600 root:root` のファイルが読めない。** restic は
`errors: N` を出しながら 0 バイトのスナップショットを作り、**k8up はそれを `Succeeded` にする**。
`0640` はグループ読みで通る。

Schedule 全部に `podSecurityContext: {runAsUser: 0, runAsGroup: 0}` を付けて直した(PSA `baseline` でも通る。
`restricted` に寄せるなら、アプリ側がファイルを `0640` で作るようにする)。notify は `summary.total_bytes_processed == 0`
を報告する。本当に空の PVC は誤検知するので、そのときは確かめて放っておく。

戻すときも同じで、`Restore` に `runAsUser: 0` が無いと mkdir が permission denied のまま `Succeeded` になる。
**`Succeeded` は「中身が戻った」の意味ではない。** 戻したら必ず中身を見る(recovery/README.md の 8)。

## CRD がまだ無いクラスタで apps を止めないこと

`Schedule` には `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true` を必ず付ける。
無いと、k8up の CRD が入る前の dry-run で `deploy/` の同期が丸ごと落ち、CRD を入れる Application 自身も抜けられない。
CRD を Application が入れる種類のリソースは全部同じ([../../bootstrap/README.md](../../bootstrap/README.md)「`InfisicalSecret` には sync-options を 2 つ付けること」)。

## やめたアプリの残り

notify は過去 8 日に出てきた (host, path) を「あるべきもの」とみなすので、消したアプリや改名したアプリは 8 日のあいだ毎日鳴る。
**残さずに `restic forget --prune <ID…>` で消す。** Schedule が無くなったホストは forget も prune もされないので、消すまで R2 に残る。

- **ID で指定する。** `--host` だけでは何も消さない。`--keep-tag` などの保持ポリシーで全部を外そうとすると、
  restic は `refusing to delete last snapshot of snapshot group` で止まる
- 打つときは k8up のイメージ(`ghcr.io/k8up-io/k8up`、restic 入り)と `k8up-global` の秘密で使い捨ての Job を
  `kubectl -n k8up create -f -` で流す(env の渡し方は [denpa-encoded-forget.yaml](denpa-encoded-forget.yaml) と同じ)
- forget はリポジトリを排他でロックするので、schedules.yaml の時刻を外す
