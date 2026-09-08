# recovery

サーバをまっさらな状態から戻すためのもの。**秘密は暗号化してあるので、この repo は公開のままでよい。**

| | |
| --- | --- |
| `restore.sh` | 復元スクリプト。Cloudflare R2 の restic バックアップから k3s ホストを丸ごと戻す |
| `env.age` | バックアップ先の資格情報(R2 の鍵、restic のパスワード)。age のパスフレーズで暗号化 |
| `sops-age.key.age` | `../bootstrap/` の SOPS ファイルを復号する age 秘密鍵。**同じパスフレーズ**で暗号化 |

手で持つのは **age のパスフレーズ 1 つだけ**。GitHub へのログインは要らない。
置き場の考え方は [../docs/decisions.md](../docs/decisions.md)「そのパスフレーズをどこに置くか」。

**Talos の秘密はここには無い。** `talos/secrets.yaml`(SOPS 済み)にあり、上の age 鍵で開く。
**`talosconfig` はどこにも保存していない** ── `secrets.yaml` から `talosctl gen config` で毎回出る
派生物なので、使い捨てにする([../talos/README.md](../talos/README.md))。

**この 2 ファイルは紙にも刷っておくこと。** 上の手順は「GitHub にログインしなくてよい」だけで、
**リポジトリが読めることは前提にしている**。base64 で `env.age` が 12 行、`sops-age.key.age` が 7 行。

```shell
base64 recovery/env.age recovery/sops-age.key.age   # 印刷して封筒へ
```

```shell
curl -fsSLO https://raw.githubusercontent.com/danything/gitops/main/recovery/restore.sh
sudo sh restore.sh          # パスフレーズを聞かれる
```

SOPS の鍵を使うとき:

```shell
mkdir -p ~/.config/sops/age
age -d -o ~/.config/sops/age/keys.txt sops-age.key.age
sops -d bootstrap/infisical/secrets.yaml | kubectl apply -f -
```

値を入れ替えたら作り直してコミットする。

```shell
age -p -o recovery/env.age /etc/k3s-backup/env
```

リハーサルの手順と結果は [`../docs/restore-drill.md`](../docs/restore-drill.md)。
