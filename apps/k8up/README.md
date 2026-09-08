# k8up

Talos に移ったあとのバックアップの担い手。いまの `backup/k3s-backup` は
「サーバに入って PVC のディレクトリを restic に流す」形なので、**ホストにシェルが無い Talos では成立しない**。
k8up は Pod として同じ restic リポジトリ(Cloudflare R2 の `doany-restic`)に書く。

**論理バックアップもファイルの PVC も、もう k8up が取っている**(2026-09-08 に全 11 namespace で成功を確認)。
ホストのスクリプトはまだ並走していて、畳むのは Talos に移る時点。

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
    --from-literal=mattermostWebhook="$MATTERMOST_WEBHOOK" \
    --dry-run=client -o yaml | k3s kubectl apply -f -'
```

`/etc/k3s-backup/env` は `recovery/restore.sh` が復元する。**復元時はスクリプトが
この Secret も作り直すので手作業は要らない**(2026-09-07 に追加。それまでは作られず、
operator が `CreateContainerConfigError` で上がらなかった)。
**Talos に移ったら Infisical に移す**(ホストに env ファイルが無くなるため)。

`mattermostWebhook` は [notify.yaml](notify.yaml) が使う。**新しい秘密を増やさないために
`k8up-global` に相乗りさせている** ── 値は同じ env ファイルの `MATTERMOST_WEBHOOK` で、
ホストの `backup/k3s-backup` が使っているものと同じ。

## 失敗したときに気づけるようにする

**k8up には通知が無い。** ホストの `backup/k3s-backup` には最初からあるので
(`notify()` が Mattermost に投げる)、**バックアップを全部 k8up に移した時点で穴になった。**
[notify.yaml](notify.yaml) の CronJob が日次(18:00 UTC)でそれを埋める。

**ArgoCD の通知は使えない。** Mattermost に繋がってはいるが(`bootstrap/argocd/helmchart.yaml`)、
**あれは Application しか見ない**ので k8up の `Backup` CR の失敗は拾えない。

**見るのは restic の中身**であって、k8up のオブジェクトではない。**オブジェクトは掃除される** ──
`successfulJobsHistoryLimit` で消えるし、**スケジュールを書き換えただけで消えることも確認した**
(2026-09-08)。「`Backup` が無い」は「取れていない」の証拠にならない。

なので init コンテナで `restic snapshots --json` を取ってきて、それを数える。
k8up のイメージに restic が入っている(`/usr/local/bin/restic`)ので、余計なものを持ち込まなくてよい。

**何が取れているべきかは履歴から学ぶ。** 過去 8 日に出てきた `(host, path)` の組を「あるべきもの」と
みなし、それぞれの最新が 25 時間以内かを見る。**一覧を人が書き写す必要がなく**、PVC や namespace が
増えても勝手に追いつく。ホストのスクリプト(`host=main`)のぶんも同じ物差しで見られる。

**履歴だけには頼らない。** 学習は 8 日で忘れるので、止まったまま 8 日を過ぎた経路は追跡対象から
落ちて無音に戻る。そこで**クラスタ側から見た「あるべき姿」**も突き合わせる ── `backup` を持つ
`Schedule` の namespace には、その namespace 名のホストのスナップショットが 25 時間以内にあるはず。
**こちらは時間で減衰しない。**

| | 何を捕まえる | 減衰 |
| --- | --- | --- |
| 履歴(過去 8 日の `(host, path)`) | **経路ごと**の退行(PVC 1 本だけ落ちた、など) | 8 日 |
| `Schedule`(クラスタの意図) | namespace が**丸ごと**無音になった | しない |

**残る割り切り**: 経路を複数持つ namespace で**そのうち 1 本だけ**が 8 日を超えて止まった場合は、
履歴からは落ち、namespace 単位では他の経路が新しいので無音に戻る。**その 8 日間は毎日
FAILED を出している**ので、そこで気づけなかった、という形でしか起きない。

**やめた経路を失敗と呼ばない。** 取る対象を広げると古い経路が履歴に残る
(`/etc/rancher/k3s/config.yaml` を個別に取るのをやめて `/etc/rancher/k3s` ごと取るようにした、など)。
**同じホストでより上の階層が新しく取れているなら、その中身も取れている**ので黙って落とす。

あわせて `Backup` / `Prune` / `Check` / `Restore` の `Completed` 条件も見て、
残っていれば失敗の理由まで書く。

成功時も 1 行投げる。**通知の仕組み自体が生きていることの確認**になる(ホストのスクリプトと同じ考え方)。

本番のリポジトリで実際に流して確かめた(2026-09-08):

```
追跡 32 系統 / 上位の階層が新しいので無視 2 件
   無視  29.1h  main/etc/rancher/k3s/config.yaml
   無視  29.1h  main/etc/rancher/k3s/registries.yaml

[k8up] OK ✅ (32 系統すべて 25 時間以内)
```

## 何をどう取っているか

`Schedule` は [schedules.yaml](schedules.yaml) に 12 本まとめてある(時刻と決まりごともあちら)。
11 本が namespace ごとの backup + prune で、**残り 1 本はリポジトリ全体の `check`**。
**注釈だけでは動かない** ── その namespace に `Schedule` が無いとジョブが作られない。
**取る中身を決めているのは Pod 側の注釈**で、それがどこにあるかがここ。

| namespace | 中身 | `k8up.io/backupcommand` の在処 |
| --- | --- | --- |
| mattermost | postgres の `pg_dump` | [../mattermost/postgres.yaml](../mattermost/postgres.yaml) |
| erpnext | mariadb の `mariadb-dump` | 上流 chart の `worker.gunicorn.podAnnotations`([application.yaml](../erpnext/application.yaml)) |
| infisical | postgres の `pg_dump` | `bootstrap/infisical/helmchart.yaml` の `postgresql.primary.podAnnotations`(**SOPS 済みなので編集は `sops set`**) |
| lgtm / xool / worklog / denpa / blog | SQLite を `serialize()` した 1 ファイル | 各アプリのリポジトリの `deploy/`(denpa と yosegaki は chart) |
| netbird | `store.db` / `idp.db` / `events.db` を tar 1 本に | [../netbird/deployment.yaml](../netbird/deployment.yaml) |
| adguardhome / portainer | ファイルだけ(下記) | ─ |

PVC のファイルは `k8up.io/backup: "true"` を付けたものだけ取る。operator が
`BACKUP_SKIP_WITHOUT_ANNOTATION=true` なので、**注釈がその宣言そのもの**。
`"false"` と**注釈が無いのは同じ意味**(どちらも取らない)。同じファイルに `"true"` が
並んでいるときだけ、取らない側にも `"false"` を書いて意図を見えるようにしてある。

いまホストの `backup/k3s-backup` と二重に取っているが、restic は内容で重複を除くので
実際に増えるのはメタデータだけ。**Talos に移る時点でホスト側を畳む**。

erpnext だけ形が違う。**chart の `mariadb-sts` の StatefulSet テンプレートに `podAnnotations` が無い**
ので、MariaDB の Pod には注釈を付けられない。代わりに gunicorn の Pod から `mariadb-dump` を打っている。
あちらには `site_config.json`(`db_host` / `db_name` / `db_password`)と `mariadb-dump` が入っていて、
root のパスワードも要らない。

Infisical の Postgres は**クラスタで一番失えないデータ**(全アプリの秘密)。DB そのものは
`ENCRYPTION_KEY` で暗号化されているのでダンプだけ手に入っても読めない ── **復元にはその鍵も要る**。
Infisical 本体は `bootstrap/` に居るが、Schedule は `apps/` に置いて Argo CD に見てもらっている
(バックアップはアプリ層の関心事で、Infisical より下の層である必要が無いため)。

## 確かめたこと(2026-09-07)

- **`backend.envFrom` だけでは動かない。** k8up は `Backend` が nil でなければ
  `RESTIC_REPOSITORY` を**空の literal env として必ず入れる**ので、`envFrom` の値が上書きされる。
  実際に `Fatal: Please specify repository location` で落ちた。
  グローバル設定に寄せる(`backend` を書かない)のが正解。
- `backend` を持たない `Backup` が R2 へ書けることを、使い捨ての PVC で確認済み(確認後に削除)。
- **ホストのスクリプトとは衝突しない。** 実測したスナップショットの内訳:

  ```
     1  host=erpnext      tags=['k8up']      path=/erpnext-gunicorn.sql
     1  host=infisical    tags=['k8up']      path=/infisical-postgresql.sql
     1  host=mattermost   tags=['k8up']      path=/mattermost-postgres.sql
     4  host=main         tags=['k3s-host']  path=/etc/...
  ```

  **k8up の `hostname` は namespace**、ホストのスクリプトは `main`。
  `restic/cli/prune.go` は `--host=<自分の namespace>` を必ず渡すので、
  **prune は他の namespace にもホストのぶんにも届かない**。`tags: [k8up]` は二重の歯止め
  (`--tag` は `retention.tags` があるときだけ渡る)。
  **同じ理由で prune は namespace ごとに要る** ── 1 本にまとめても他には効かない。

## CRD がまだ無いクラスタで apps を止めないこと

`Schedule` には `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true` を必ず付ける。

ArgoCD は同期の前にマニフェスト一式を dry-run で検証する。**k8up の CRD が入る前だと
「`k8up.io/v1` が引けない」で `apps/` 配下が丸ごと適用されなくなる** ── CRD を入れる
Application 自身が同じ同期の中にいるので抜けられない(2026-09-07 の復元リハーサルで発覚。
子 Application 5 本が作られなかった)。このリソースだけ dry-run を飛ばせば、CRD を入れる
Application が先に通る。

**「git がバックアップより進んでいる」状態は復元では普通に起きる**ので、
スナップショットが古かったから、では済まない。

## SQLite を整合したまま取る(2026-09-07 実施)

ホストのスクリプトは **scale down してから** PVC を写している。k8up は**動いたまま**取るので、
ファイルをそのままコピーすると **本体と `-wal`(または `-journal`)が別の瞬間のものになりうる**。
アプリのデータはほぼ全部 SQLite なので、ここを先に片付けた。

**`bun -e` で済む。イメージには何も足さない。**

```yaml
k8up.io/backupcommand: >-
  bun -e 'process.stdout.write(new(require("bun:sqlite").Database)("/usr/src/app/data/lgtm.db",{readonly:true}).serialize())'
k8up.io/file-extension: .db
```

- `serialize()` は SQLite の pager を通して読むので、**書き込み中でも 1 つのコミット済みの状態**が出る
- **自前アプリ 5 つは全部 bun で動いている**ので `bun:sqlite` が最初から使える。
  当初は「イメージに `sqlite3` を足す PR が 5 本要る」と見積もっていたが、要らなかった
- **スクリプトに空白を入れない。** k8up は注釈を `qsplit` でシェル風に分割する
  (`restic/kubernetes/pod_exec.go`)。引用符が効く範囲を `-e` の前後だけにしておくと確実
- netbird だけ `"` で括って中を **バッククォート**にしてある。qsplit の既定の引用符は
  `'` と `"` の 2 つだけなので、バッククォートは素通りする

本番の Pod で実測(`live_rows` は今の DB、`copy_rows` はコピーを開き直して数えたもの):

| | bytes | live_rows | copy_rows | tables | integrity |
| --- | --- | --- | --- | --- | --- |
| lgtm | 69,632 | 132 | 132 | 4 | ok |
| xool | 237,568 | 242 | 242 | 8 | ok |
| worklog | 167,936 | 107 | 107 | 13 | ok |
| denpa | 20,598,784 | 30,309 | 30,309 | 12 | ok |
| yosegaki | 53,248 | 0 | 0 | 4 | ok |

### netbird はサイドカーで取る

上流イメージ(`netbirdio/netbird-server`)には `sqlite3` が無く、あるのは perl だけ。
こちらでは変えられないので、**`oven/bun:1.4.2-slim` のサイドカーを足して
`k8up.io/backupcommand-container: backup` でそちらを指している**。
PVC は `readOnly: true` でマウントする。

`store.db` / `idp.db` / `events.db` の 3 つを `serialize()` して tar 1 本にまとめる。
同じ PVC の `GeoLite2-City`(65 MB)と `geonames`(7 MB)は**入れない** ── 起動時に落とし直せる。

実際の PVC を読み取り専用でマウントして確認済み:

```
exit=0 bytes=911360
-rw-r--r-- root/root 745472 ./store.db
-rw-r--r-- root/root  36864 ./events.db
-rw-r--r-- root/root 122880 ./idp.db
```

**ハングした書き込みが残っていると失敗する。** 3 つとも rollback journal モードなので、
放置された `-journal` があると読み取り専用の接続はロールバックできず `SQLITE_READONLY_ROLLBACK`
で落ちる。そのときは k8up のジョブが失敗として見える(黙って壊れたコピーが残るよりよい)。

## ファイルの PVC をどう移すか(Talos で外す時)

ホストの `backup/k3s-backup` が見ているぶんを k8up に寄せる(ROADMAP の Phase 2)。
SQLite は上で片付いたので、残りは注釈を足すだけ。

**全部済んだ(2026-09-08)。** 残っているのはホストのスクリプトを畳むことだけで、それは Talos に移る時点。

| PVC | 中身 | どうするか |
| --- | --- | --- |
| `adguardhome-*` `erpnext-sites` `mattermost-data` `portainer-data` `netbird-routing-peer-data` | ファイル | gitops にあるのでここで `"true"` |
| `denpa-library` `agent-config` `lgtm-images` `lgtm-assets` `xool-assets` `yuzuriha-data` | ファイル | 各アプリのリポジトリ側で `"true"`(lgtm#26 / xool#136 / yuzuriha#12 / denpa#85) |
| `lgtm-db` `xool-db` `worklog-db` `yosegaki-db` | SQLite だけ | **済み**(上の `backupcommand`)。PVC 側は `false` のまま ── ファイルとして二重に取らない |
| `denpa-data` | SQLite + ファイル | `"true"` + `k8up.io/backup-restic-args: '["--exclude","denpa.db*"]'`。DB は `backupcommand` で取っているので**ファイルとしては除外**し、`logos/` だけを取る。**この注釈は JSON でパースされる**(`backupcommand` の `qsplit` とは別の経路。`operator/backupcontroller/executor.go`)。**パースに失敗すると `continue` でその PVC が黙って飛ばされる**ので、変えたら実物を見ること |
| `netbird-data` | SQLite + 再取得できるファイル | `"false"`。DB はサイドカーの `backupcommand` で取る。同居している GeoLite2-City(65 MB)と geonames(7 MB)は起動時に落とし直せる |
| `data-erpnext-mariadb-sts-0` `data-postgresql-0` `postgres-data` | RDBMS | もう論理バックアップがある。mattermost の 2 本には `k8up.io/backup: "false"` を明示してある(注釈が無ければ既に対象外だが、意図して外していると分かるように) |
| `portainer-data` | boltdb | **ファイルとして取る。** シェルが無く(`exec: "sh": executable file not found`)SQLite でもないので `backupcommand` が使えない。動いたままのコピーなので**整合は保証されない**。中身は OIDC 設定とエンドポイント 1 本だけで画面から数分で作り直せるため、これで割り切る(厳密にやるなら backup API `POST /api/backup` を叩くサイドカー) |
| `denpa-recorded` | 生 TS の作業領域 | 取らない(容量。docs/decisions.md「バックアップに何を含めるか」) |
