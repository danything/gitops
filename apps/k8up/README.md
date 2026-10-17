# k8up

バックアップの担い手。ノードにシェルが無いので、Pod として restic リポジトリ(Cloudflare R2 の `doany-restic`)に書く。
論理バックアップもファイルの PVC も k8up が取り、etcd のスナップショットも同じリポジトリへ([etcd-snapshot.yaml](etcd-snapshot.yaml))。
**戻す手順は [../../recovery/README.md](../../recovery/README.md)**(Infisical は 6、ほかは 8)。

## 秘密の渡し方

**`Schedule` や `Backup` に `backend` を書かない。** 書くと endpoint(Cloudflare のアカウント ID を含む)が
git に載る。代わりに **operator の環境変数(グローバル設定)**に寄せて、`backend` を持たない
`Backup` はそこへ落ちるようにしてある。

**Secret `k8up-global` の正本は Infisical**(`/k8up/k8up-global`)。[k8up-secrets.yaml](k8up-secrets.yaml) の
`InfisicalSecret` が作る。キーは `endpoint` / `bucket` / `accessKeyId` / `secretAccessKey` / `repoPassword` /
`mattermostWebhook` の 6 つで、**足りないとバックアップが全部落ちる**(operator は Infisical にあるものだけを書く)。
2026-09-08 に入れて、手で作っていた Secret と 6 つとも突き合わせた。**手で作るのは災害復旧のときだけ**(下)。

**値を変えたら `kubectl -n k8up rollout restart deploy/k8up`。** 他のアプリのような
`auto-reload` の注釈は使えない ── あれは Deployment 自身の注釈に要るが、
**k8up の chart は `podAnnotations` しか公開していない**。理由と例外
(`mattermostWebhook` は再起動不要)は [k8up-secrets.yaml](k8up-secrets.yaml) に書いた。

**建て直しのときは k8up で Infisical を戻せない。** この Secret の中身(R2 の資格情報)が Infisical から来るのに、
Infisical を戻すための `infisical-postgresql.sql` はその R2 にある。なので Infisical だけは手元の restic で
`recovery/env.age`(同じ値)を使って戻す([../../recovery/README.md](../../recovery/README.md) の 6)。
戻れば operator がこの Secret を作り、k8up が動き出す。

`mattermostWebhook` は [notify.yaml](notify.yaml) が使う。**新しい秘密を増やさないために
`k8up-global` に相乗りさせている**(`env.age` の `MATTERMOST_WEBHOOK` と同じ値)。名前は据え置きで、中身はいま Matrix の部屋 `server`
の webhook([../matrix/README.md](../matrix/README.md)「通知のルーム」)。

## 失敗したときに気づけるようにする

**k8up には通知が無い。** [notify.yaml](notify.yaml) の CronJob が日次(18:00 UTC)でそれを埋める。

その 30 分後に [denpa-encoded-forget.yaml](denpa-encoded-forget.yaml) が走る。
録画データだけ世代を持たないための forget で、理由は
[../../docs/decisions.md](../../docs/decisions.md)「バックアップに何を含めるか」。

**ArgoCD の通知は使えない。** 通知の部屋に繋がってはいるが(`bootstrap/argocd/helmchart.yaml`)、
**あれは Application しか見ない**ので k8up の `Backup` CR の失敗は拾えない。

**見るのは restic の中身**であって、k8up のオブジェクトではない。**オブジェクトは掃除される** ──
`successfulJobsHistoryLimit` で消えるし、**スケジュールを書き換えただけで消えることも確認した**
(2026-09-08)。「`Backup` が無い」は「取れていない」の証拠にならない。

なので init コンテナで `restic snapshots --json` を取ってきて、それを数える。
k8up のイメージに restic が入っている(`/usr/local/bin/restic`)ので、余計なものを持ち込まなくてよい。

見張りは 4 つ重ねてある。どれか 1 つでは穴が残るため:

| | 何を捕まえる | 減衰 | なぜ要るか |
| --- | --- | --- | --- |
| 履歴(過去 8 日に出てきた `(host, path)`。最新が 25 時間以内か) | **経路ごと**の退行(PVC 1 本だけ落ちた、など) | 8 日 | 一覧を人が書き写さなくても、PVC や namespace が増えれば勝手に追いつく。etcd(`host=etcd`)も同じ物差しで見られる |
| `Schedule`(`backup` を持つ namespace には、その名前のホストのスナップショットが 25 時間以内にあるはず) | namespace が**丸ごと**無音になった | しない | 履歴は 8 日で忘れるので、止まったまま 8 日を過ぎた経路は無音に戻る |
| `summary.total_bytes_processed` | 走ってはいるが**何も読めていない** | しない | 新しいのに中身が 0 バイト、が実際に起きていた(下の「空のスナップショット」) |
| PVC / Pod の注釈(`k8up.io/backup` と `k8up.io/backupcommand` の両方)× `Schedule` の namespace | **一度も取られたことがない** PVC・Pod | しない | 注釈を付けても `Schedule` が無ければ**ジョブ自体が作られず、エラーも出ない**(2026-09-08 に `yuzuriha-data` が落ちていた) |

**残る割り切り**: 経路を複数持つ namespace で**そのうち 1 本だけ**が 8 日を超えて止まった場合は、
履歴からは落ち、namespace 単位では他の経路が新しいので無音に戻る。**その 8 日間は毎日
FAILED を出している**ので、そこで気づけなかった、という形でしか起きない。

**やめた経路を失敗と呼ばない。** 取る対象を広げると古い経路が履歴に残る
(個別のファイルを取るのをやめてディレクトリごと取るようにした、など)。
**同じホストでより上の階層が新しく取れているなら、その中身も取れている**ので黙って落とす。

あわせて `Backup` / `Prune` / `Check` / `Restore` の `Completed` 条件も見て、
残っていれば失敗の理由まで書く。

成功時も 1 行投げる。**通知の仕組み自体が生きていることの確認**になる。

本番のリポジトリで流して確かめた(2026-09-08。32 系統すべて OK、上の階層で取れている 2 件を無視)。

## 戻せるかを月次で確かめる

**notify は「取れたか」しか見ない。** 壊れた SQLite や途中で切れたダンプでも、新しくて 0 バイトでないスナップショットはできる。
[restore-check.yaml](restore-check.yaml) が毎月 1 日 06:00 UTC に、(host, path) ごとの最新を取り出して開き、notify と同じ webhook に 1 通投げる。
四半期ごとの手動のリハーサルはこれに置き換えた。

| 中身 | 何を見るか |
| --- | --- |
| SQLite(`.db`) | `PRAGMA integrity_check` が ok、表が 1 つ以上 |
| `pg_dump`(`.sql`) | 使い捨ての postgres 17 に流して `ERROR` が 0 行。**ロールはダンプの `OWNER TO` から先に作る**(下の「戻し方」と同じ理由) |
| tar | 展開できる。netbird は 3 つの DB を SQLite と同じく、matrix は `backups/meta/<番号>` が指すファイルが全部あるか |
| ファイルの PVC・etcd | `restic ls` が通って合計が 0 バイトでない(取り出さない) |

restic は全部 `--no-lock`(リポジトリに何も書かない)。ロールを作らずに流すと 3 本とも `role … does not exist` で
FAILED になることも確かめた(2026-10-17。本番は 27 件すべて OK、2 分ほど)。

## やめたアプリの残り(2026-09-19)

通知は**過去 8 日に出てきた (host, path) を「あるべきもの」**とみなす。namespace ごと
消したアプリや名前を変えたアプリは、その 8 日のあいだ毎日「25 時間以上更新されていない」と
鳴り続ける(2026-09-19 に noren 3 本と shadai 3 本で起きた。noren は 09-12 に撤去、
shadai は 09-16 に todoroku に改名)。窓が閉じれば黙るが、5 日も FAILED を眺めるものではない。

やめ方は 2 つ。どちらも `restic` を repo に向けて 1 回打つだけ(下の Job)。

- **消してよいもの**(noren): `restic forget --host noren`。スナップショットが消え、
  中身は日曜の prune で解放される
- **残しておきたいもの**(shadai = トドロクの改名前の履歴):
  `restic tag --host shadai --add retired`。通知は `retired` の付いたスナップショットを
  見ない([notify.yaml](notify.yaml))。**中身はそのまま**で、`restic restore` も
  `snapshots` も今までどおり効く。保持は schedule の prune(`--keep-daily` 等)に
  そのまま従うので、時間が経てば自然に減る

打ち方。k8up の CronJob と同じイメージ・同じ秘密(`k8up-global`)で、Job を 1 つ流す。
**バックアップの時間帯(14:45〜18:30 UTC、日曜は 23:15 まで)を外す** ── forget と tag は
repo をロックする。gitops には置かない(Argo CD が毎回流してしまう)ので、その場で
`kubectl create -f -` に食わせる。1 時間で自分で消える(`ttlSecondsAfterFinished`)。

```sh
kubectl -n k8up create -f - <<'JOB'
apiVersion: batch/v1
kind: Job
metadata:
  name: k8up-retire
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: restic
          image: ghcr.io/k8up-io/k8up:v2.16.0
          command:
            - sh
            - -ec
            - |
              export RESTIC_REPOSITORY="s3:${ENDPOINT}/${BUCKET}"
              # forget は「方針」か ID を要る(--host だけだと何も消さずに落ちる)。ID を並べる。
              # 2 つの操作は独立。消すものが無くても(2 回目など)tag のほうまで進む
              ids=$(restic snapshots --host noren --compact | awk '/^[0-9a-f]{8} /{print $1}')
              [ -n "$ids" ] && restic forget $ids
              restic tag --host shadai --add retired
              restic snapshots --compact --host noren --host shadai
          env:
            - name: ENDPOINT
              valueFrom: {secretKeyRef: {name: k8up-global, key: endpoint}}
            - name: BUCKET
              valueFrom: {secretKeyRef: {name: k8up-global, key: bucket}}
            - name: AWS_ACCESS_KEY_ID
              valueFrom: {secretKeyRef: {name: k8up-global, key: accessKeyId}}
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom: {secretKeyRef: {name: k8up-global, key: secretAccessKey}}
            - name: RESTIC_PASSWORD
              valueFrom: {secretKeyRef: {name: k8up-global, key: repoPassword}}
JOB
kubectl -n k8up logs -f job/k8up-retire
```

**2026-10-06 に mattermost・erpnext・zulip も `retired` にした**(チャットは Mattermost → Zulip → Matrix と移して畳み、
ERPNext は消した。zulip の最後のバックアップは `final` のタグ付き)。最後のスナップショットは残っている。
Schedule を消したので forget も prune もされず、**消すまで R2 に残り続ける**。

## 何をどう取っているか

`Schedule` は [schedules.yaml](schedules.yaml) に 15 本まとめてある(時刻と決まりごともあちら)。
14 本が namespace ごとの backup + prune で、**残り 1 本はリポジトリ全体の `check`**。
**注釈だけでは動かない** ── その namespace に `Schedule` が無いとジョブが作られない。
**取る中身を決めているのは Pod 側の注釈**で、それがどこにあるかがここ。

| namespace | 中身 | `k8up.io/backupcommand` の在処 |
| --- | --- | --- |
| forgejo | postgres の `pg_dump` + リポジトリの PVC(ファイル) | [../forgejo/postgres.yaml](../forgejo/postgres.yaml) |
| rybbit | postgres の `pg_dump` + ClickHouse の PVC(ファイル。パートは追記だけなので動いたまま取る) | [../rybbit/postgres.yaml](../rybbit/postgres.yaml) / [../rybbit/clickhouse.yaml](../rybbit/clickhouse.yaml) |
| infisical | postgres の `pg_dump` | `bootstrap/infisical/helmchart.yaml` の `postgresql.primary.podAnnotations`(**SOPS 済みなので編集は `sops set`**) |
| lgtm / xool / worklog / denpa / blog / todoroku | SQLite を `serialize()` した 1 ファイル | 各アプリのリポジトリの `deploy/`(denpa と yosegaki は chart) |
| netbird | `store.db` / `idp.db` / `events.db` を tar 1 本に | [../netbird/deployment.yaml](../netbird/deployment.yaml) |
| adguardhome | ファイルだけ(下記) | ─ |

PVC のファイルは `k8up.io/backup: "true"` を付けたものだけ取る。operator が
`BACKUP_SKIP_WITHOUT_ANNOTATION=true` なので、**注釈がその宣言そのもの**。
`"false"` と**注釈が無いのは同じ意味**(どちらも取らない)。同じファイルに `"true"` が
並んでいるときだけ、取らない側にも `"false"` を書いて意図を見えるようにしてある。

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
- **ほかのホスト名とは衝突しない。** **k8up の `hostname` は namespace**(タグ `k8up`)。etcd は `etcd`、前のホストのスクリプトは `main`。
  `restic/cli/prune.go` は `--host=<自分の namespace>` を必ず渡すので、
  **prune は他の namespace にも etcd や `main` にも届かない**。`tags: [k8up]` は二重の歯止め
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

**これは k8up だけの話ではない。** 同じ穴が `InfisicalSecret` にも開いていて、
2026-09-08 のドリルで踏んだ ── **CRD を Application が入れる種類のリソースは、
全部これが要る**([bootstrap/README.md](../../bootstrap/README.md)
「`InfisicalSecret` には sync-options を 2 つ付けること」)。

## SQLite を整合したまま取る(2026-09-07 実施)

k8up は**動いたまま**取るので、
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
こちらでは変えられないので、**bun の slim イメージ(版は [../netbird/deployment.yaml](../netbird/deployment.yaml)。[notify.yaml](notify.yaml) と同じ)のサイドカーを足して
`k8up.io/backupcommand-container: backup` でそちらを指している**。
PVC は `readOnly: true` でマウントする。

`store.db` / `idp.db` / `events.db` の 3 つを `serialize()` して tar 1 本にまとめる。
同じ PVC の `GeoLite2-City`(65 MB)と `geonames`(7 MB)は**入れない** ── 起動時に落とし直せる。

実際の PVC を読み取り専用でマウントして確認済み(3 ファイル入りの tar 約 0.9 MB が出た)。

**ハングした書き込みが残っていると失敗する。** 3 つとも rollback journal モードなので、
放置された `-journal` があると読み取り専用の接続はロールバックできず `SQLITE_READONLY_ROLLBACK`
で落ちる。そのときは k8up のジョブが失敗として見える(黙って壊れたコピーが残るよりよい)。

## 空のスナップショット(2026-09-08 に見つけた)

**3 本のバックアップが何週間も中身 0 バイトだった。**

```
76f8e95e  /data/adguardhome-conf   2 files, 0 B
a9d31edb  /data/adguardhome-work   1 files, 0 B
50f68f0b  /data/portainer-data     2 files, 0 B
```

(数えられている「2 files」はディレクトリのエントリだけ。中身は入っていない)

### なぜ

**k8up のバックアップ Pod は既定で nonroot(65532)で走る**ので、
`0600 root:root` のファイルが読めない。そのとき restic は落ちずに**エラーを数えながら
先へ進む**:

```
ERROR  /data/adguardhome-conf/AdGuardHome.yaml during archival  {"error": "error occurred during backup"}
       … 7 本ぜんぶ …
INFO   backup finished  {"new files": 0, "changed files": 0, "errors": 7}
```

**そして k8up はこの Backup を `Succeeded` にする。** オブジェクトを見ても、
スナップショットの有無を見ても、日次通知を見ても気づけなかった
── **どれも「新しいスナップショットができたか」しか見ていなかった**ため。

`0640 root:root` は読めていた(`adguardhome-ssl`)。イメージが GID 0 で走るので
グループ読みは通り、**その他ビットが無い `0600` だけが落ちる**。

### 直し方

Schedule 全部に `podSecurityContext: {runAsUser: 0, runAsGroup: 0}` を付けた。
実測で `errors: 0`(adguardhome-conf が `new files: 7`)になることを確認済み。

**Talos の PSA `baseline` でも通る** ── root を禁じるのは `restricted` だけ。

### 気づけるようにした

`notify.js` が **`summary.total_bytes_processed == 0` のスナップショットを報告する**。
`restic snapshots --json` にもとから入っている値なので、コマンドは増えない。
実際の(直す前の)データで鳴ることを確かめた:

```
[k8up] FAILED ❌
**中身が空のスナップショット(読めていない可能性)**
- adguardhome/data/adguardhome-conf (0 バイト)
- adguardhome/data/adguardhome-work (0 バイト)
- portainer/data/portainer-data (0 バイト)
```

**本当に空の PVC は誤検知する。** そのときは通知の文面どおり「読めていない可能性」を
確かめて、空でよいなら放っておくしかない(いまのところそんな PVC は無い)。
`summary` を持たない古いスナップショットは黙って見送る。

## 戻し方

**手順は [../../recovery/README.md](../../recovery/README.md) の 8、道具は [../../recovery/pv.sh](../../recovery/pv.sh)。** 要点だけ:

- k8up の `Restore` を作る。**バックエンドは書かない**(operator のグローバル設定を使う)。**`podSecurityContext: {runAsUser: 0, runAsGroup: 0}` を付ける**
  (Schedule と同じ理由。無いと mkdir が permission denied で、それでも `Succeeded`)。`xattr.LRemove … security.selinux` のエラーは害が無い
- **`folder` は PVC にそのまま書き戻す。** `/data/<pvc>` で取ったものは `/data/<pvc>` の階層を落として PVC の直下に出る(`trimPath`)
- **`backupcommand` で取ったもの**(SQLite・pg_dump・tar)は 1 個のファイルとして PVC の直下に出る。`/worklog-worklog.db` なら
  `worklog-worklog.db`。**そのままではアプリのファイル名ではない**ので付け替える(`-wal` / `-shm` / `-journal` も消す)
- **バイナリを `kubectl exec -i` の標準入力で流さない。** 末尾が欠ける(2026-10-17 に SQLite で 237568 → 98304 バイト)
- **SQL のダンプは、アプリを普通に起動してから流す。** `pg_dump` は `--no-owner` を付けていないので `ALTER … OWNER TO <ロール>` が入っていて、
  ロールが無いとそこだけ全部落ちる(データは入るが所有者が postgres のまま)。chart が初期化すればロールも DB もある
- **`Succeeded` は「中身が戻った」の意味ではない。** 空のスナップショットを戻したときも `Succeeded` で、ログだけが
  `Restored 0 files/dirs (0 B)` と言っていた。**戻したあとは必ず中身を見ること**

## ファイルの PVC の扱い

ファイルとして取っている PVC と、取らない PVC(2026-09-08 に揃えた)。

| PVC | 中身 | どうするか |
| --- | --- | --- |
| `adguardhome-conf` `adguardhome-work` `netbird-routing-peer-data` `forgejo-repos` | ファイル | gitops にあるのでここで `"true"` |
| `denpa-encoded`(旧 `denpa-library`) `agent-config` `lgtm-images` `lgtm-assets` `xool-assets` `yuzuriha-data` | ファイル | 各アプリのリポジトリ側で `"true"`(lgtm#26 / xool#136 / yuzuriha#12 / denpa#85) |
| `lgtm-db` `xool-db` `worklog-db` `yosegaki-db` | SQLite だけ | **済み**(上の `backupcommand`)。PVC 側は `false` のまま ── ファイルとして二重に取らない |
| `denpa-data` | SQLite + ファイル | `"true"` + `k8up.io/backup-restic-args: '["--exclude","denpa.db*"]'`。DB は `backupcommand` で取っているので**ファイルとしては除外**し、`logos/` だけを取る。**この注釈は JSON でパースされる**(`backupcommand` の `qsplit` とは別の経路。`operator/backupcontroller/executor.go`)。**パースに失敗すると `continue` でその PVC が黙って飛ばされる**ので、変えたら実物を見ること |
| `netbird-data` | SQLite + 再取得できるファイル | `"false"`。DB はサイドカーの `backupcommand` で取る。同居している GeoLite2-City(65 MB)と geonames(7 MB)は起動時に落とし直せる |
| `data-postgresql-0`(infisical) `postgres-data`(forgejo / rybbit) | RDBMS | もう論理バックアップがある。`postgres-data` には `k8up.io/backup: "false"` を明示してある(注釈が無ければ既に対象外だが、意図して外していると分かるように) |
| `denpa-raw`(旧 `denpa-recorded`) | 生 TS の作業領域 | 取らない(容量。docs/decisions.md「バックアップに何を含めるか」) |
