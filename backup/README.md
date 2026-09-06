# backup

ホストを丸ごと restic で Cloudflare R2 に取る。**毎日 04:00 JST**、systemd timer(`k3s-backup.timer`)。
戻し方は [`../recovery/`](../recovery/)、設計の理由は [`../docs/decisions.md`](../docs/decisions.md)。

| | |
| --- | --- |
| `k3s-backup` | 本体。`/usr/local/bin/` に入れる |
| `k3s-backup.service` / `.timer` | systemd unit |
| `install.sh` | 稼働中ホストへの導入(1 回だけ) |
| `env.example` | `/etc/k3s-backup/env` の雛形。実物は `../recovery/env.age`(age 暗号化) |
| `k3s-server-config.yaml` | `/etc/rancher/k3s/config.yaml` の控え。実体はバックアップから戻る |

## やっていること

1. PVC を持つ namespace を scale down(`denpa` は録画の grace period が 6 時間なので除外)
2. **scale down の前に** state.db を sqlite のホットバックアップで取る(順序を間違えると `replicas: 0` が焼き込まれる)
3. PVC データ・k3s の証明書と token・`/etc/rancher/k3s/{config,registries}.yaml`・ネットワーク設定・
   スクリプトと unit 自身を restic へ
4. scale up → `forget --keep-daily 7 --keep-weekly 4 --keep-monthly 2 --prune` → `check --read-data-subset=5%`
5. Mattermost に結果を通知(成功時はスナップショット数と R2 の実サイズ付き)

## 導入

```shell
sudo ./install.sh          # env を埋めて再実行 → restic init と timer 有効化
```

導入が済んだらホストに repo は要らない。

## 様子を見る

```shell
systemctl list-timers k3s-backup.timer
journalctl -u k3s-backup -n 50
sudo sh -c 'set -a; . /etc/k3s-backup/env; set +a; restic snapshots'
```
