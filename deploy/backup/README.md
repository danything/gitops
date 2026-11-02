# backup

PVC のバックアップは VolSync([../volsync/application.yaml](../volsync/application.yaml)。PVC ごとにスナップショットから restic で R2 へ)。
ここに置くのはその見張りと、PVC ではない etcd のスナップショット。2026-11 に k8up の後を継いだ(経緯は ROADMAP.md)。

| | 何 | 時刻(UTC) |
| --- | --- | --- |
| 各アプリの `deploy/volsync.yaml`(VolSync 本体は [../volsync/](../volsync/)) | PVC ごとの ReplicationSource。保持は日次 7・週次 4・月次 6(録画だけ 1 世代) | 19:00 |
| [etcd-snapshot.yaml](etcd-snapshot.yaml) | etcd のスナップショット(`<bucket>/etcd`)。保持は日次 7・週次 4 | 13:00 |
| [notify.yaml](notify.yaml) | 全部の ReplicationSource と etcd-snapshot が 26 時間以内に成功したかを、日次で通知の部屋に 1 行 | 21:00 |
| [restore-check.yaml](restore-check.yaml) | 毎月 1 日、全部の PVC の最新を実際に取り出して開けるかを確かめる | 06:00(1 日) |

戻し方は [../../recovery/README.md](../../recovery/README.md) の 6(populator で PVC を作ると埋まる)。

## 秘密

**Secret `backup` は [secrets.sops.yaml](secrets.sops.yaml)**(SOPS。`tools/t sops edit` で直す)。
キーは `endpoint` / `bucket` / `accessKeyId` / `secretAccessKey` / `repoPassword` / `mattermostWebhook` の 6 つ。
VolSync の Secret(`volsync-<pvc>`。各 namespace の secrets.sops.yaml)も同じ R2 の資格情報とパスワード(変えるときは全部)。
値は `recovery/env.age` にもある。

`mattermostWebhook` は名前は据え置きで、中身は Matrix の部屋 `server` の webhook([../matrix/README.md](../matrix/README.md)「通知のルーム」)。

## PVC を足すとき・やめるとき

**取る定義はアプリと一緒に置く**(そのアプリのリポジトリの `deploy/volsync.yaml`。gitops の中のアプリは `../<アプリ>/volsync.yaml`)。
アプリを消せば定義も消えるので、gitops を直す必要は無い。戻すときは各 PVC の `dataSourceRef`(volsync.yaml の `<pvc>-dst`)で、PVC を作ると R2 の最新から埋まる。

- **足す**: アプリの secrets.sops.yaml に `volsync-<pvc>` の secretTemplate(ほかの PVC のものを写してリポジトリだけ変える)、`volsync.yaml` に ReplicationSource・ReplicationDestination(`<pvc>-dst`。
  capacity は PVC と同じ)を 1 組足し、PVC に `dataSourceRef` で `<pvc>-dst` を書く(ほかのアプリの volsync.yaml と pvc.yaml を写す。時刻はどれも 19:00)。
  **dataSourceRef は PVC を作るときにしか書けない**(今ある PVC に足しても効かない。Argo CD は差分を見ない設定)。新しいアプリなら secrets.sops.yaml ごと作る。
  その namespace に `volsync.backube/privileged-movers: "true"` の注釈があるかを見る(無いと mover が root で動けず、読めないファイルで落ちる)
- **やめる**: 定義を消す(アプリごと消すなら何もしない)。**PVC を残したまま取るのだけやめるなら、R2 のリポジトリも消す**(残すと、あとで同じ名前の PVC を作ったときに古い中身で埋まる)。
  アプリごとやめたときもリポジトリ `<bucket>/volsync/<namespace>/<pvc>` は R2 に残る。要らなければ `rclone purge` か R2 の画面で消す

## バケットの中

`<bucket>/volsync/<namespace>/<pvc>`(PVC ごと)と `<bucket>/etcd` だけ。
k8up の頃のリポジトリ(バケットの根。host が namespace)は 2026-11-01 に消した(VolSync からの全件の取り出し確認が通ったあと)。
それより前のものは戻せない。
