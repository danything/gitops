# backup

PVC のバックアップは VolSync([../volsync/application.yaml](../volsync/application.yaml)。PVC ごとにスナップショットから restic で R2 へ)。
ここに置くのはその見張りと、PVC ではない etcd のスナップショット。2026-11 に k8up の後を継いだ(経緯は ROADMAP.md)。

| | 何 | 時刻(UTC) |
| --- | --- | --- |
| [../volsync/](../volsync/) | PVC ごとの ReplicationSource。保持は日次 7・週次 4・月次 6(録画だけ 1 世代) | 19:00 |
| [etcd-snapshot.yaml](etcd-snapshot.yaml) | etcd のスナップショット(`<bucket>/etcd`)。保持は日次 7・週次 4 | 13:00 |
| [notify.yaml](notify.yaml) | 全部の ReplicationSource と etcd-snapshot が 26 時間以内に成功したかを、日次で通知の部屋に 1 行 | 21:00 |
| [restore-check.yaml](restore-check.yaml) | 毎月 1 日、全部の PVC の最新を実際に取り出して開けるかを確かめる | 06:00(1 日) |

戻し方は [../../recovery/README.md](../../recovery/README.md) の 6(Infisical)と 8(ほかの PVC。`recovery/pv.sh`)。

## 秘密

**Secret `backup` の正本は Infisical の `/backup/backup`**([secret.yaml](secret.yaml))。
キーは `endpoint` / `bucket` / `accessKeyId` / `secretAccessKey` / `repoPassword` / `mattermostWebhook` の 6 つ。
VolSync の Secret(namespace ごとの InfisicalSecret `volsync` が作る `volsync-<pvc>`)も同じフォルダから組む。
値は `recovery/env.age` にもある(Infisical を戻すときは Infisical が無いので、こちらを使う。recovery/README.md の 6)。

`mattermostWebhook` は名前は据え置きで、中身は Matrix の部屋 `server` の webhook([../matrix/README.md](../matrix/README.md)「通知のルーム」)。

## PVC を足すとき・やめるとき

- **足す**: `../volsync/<namespace>.yaml` に InfisicalSecret の `managedKubeSecretReferences` と ReplicationSource を足す(時刻はほかと同じ 19:00)。
  その namespace に `volsync.backube/privileged-movers: "true"` の注釈があるかを見る(無いと mover が root で動けず、読めないファイルで落ちる)
- **やめる**: `../volsync/` から消す。リポジトリ `<bucket>/volsync/<namespace>/<pvc>` は R2 に残るので、要らなければ消す
  (`rclone purge` か R2 の画面。リポジトリが PVC ごとなので、ほかを巻き込まない)

## バケットの中

`<bucket>/volsync/<namespace>/<pvc>`(PVC ごと)と `<bucket>/etcd` だけ。
k8up の頃のリポジトリ(バケットの根。host が namespace)は 2026-11-01 に消した(VolSync からの全件の取り出し確認が通ったあと)。
それより前のものは戻せない。
