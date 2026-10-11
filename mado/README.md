# mado

**`main` が落ちたときの入口。** JCOM 側の PC(10.10.0.2、手元の Windows)で [mado](https://github.com/danything/mado)
(OIDC でログインしてブラウザから RDP する、自作の小さなゲートウェイ。exe 1 つ)を動かし、`https://md.doany.io` から
この PC の画面に入る(2026-10-11)。入ったら、この PC から iLO(10.0.0.3)や Z440 の AMT(10.0.0.5)を開いて `main` を直す。

それまでは NetBird(`main` のクラスタの中の routing peer)で LAN に入り、この PC に RDP していた。NetBird の管理サーバーも
routing peer も `main` にあるので、`main` が落ちると入れず、JCOM のルーターで 3389 を開けていた。MeshCentral を
試したが、部品の多さと見た目でやめた(#333〜#338)。

| | |
| --- | --- |
| 中身 | ブラウザの中の IronRDP(WASM)が RDP を話し、mado は Entra の OIDC でのログインの確認と、ブラウザ ↔ この PC の 3389 の中継だけ。Windows のパスワードは mado に届かない |
| 動かし方 | `C:\mado\`(`mado.exe`、`mado.json`、`client-secret.txt`、`run.cmd`、`data\`)。タスク スケジューラのタスク `mado` が「起動時に SYSTEM で」`run.cmd` を動かし、`run.cmd` が mado を起こし直し続ける(落ちたときも、自動更新で入れ替えたときも)。出力は `C:\mado\mado.log`。この PC の中から `http://127.0.0.1:8788/status` で版・つないでいる数・証明書の残り日数・更新の有無が見られる |
| 名前 | `md.doany.io` の A / AAAA を JCOM の固定の IP(`61.21.173.41`、PC に足した `2405:1201:5201:3a00::2`)に([pulumi/dns.ts](../pulumi/dns.ts))。Cloudflare も `main` の Gateway も通さない |
| ルーター | J:COM のアプリで、この PC(OD00)を 10.10.0.2 に予約し、TCP 80 / 443 を転送する。IPv6 はルーターが止めないので設定は要らない([docs/router.md](../docs/router.md)) |
| 証明書 | mado が Let's Encrypt から自分で取る(80 で HTTP-01)。30 日を切ったら取り直す |
| ログイン | Entra の共用のアプリ登録(戻り先 `https://md.doany.io/callback` は [pulumi/entra.ts](../pulumi/entra.ts))。アプリロール `admin` が無いと入れない(ほかのアプリと共通) |
| 設定 | [mado.json](mado.json)。`targets` がつなぐ先(画面で選ぶ。今はこの PC だけ。10.0 側の PC は、この PC の Wi-Fi がつながっているときだけ届く)。秘密は書かない(client secret は `setup.ps1` が Infisical から取り出して `client-secret.txt` に置く)。`required_role` の `admin` はほかのアプリと共通([docs/entra.md](../docs/entra.md)) |
| 版 | **mado が自分で上げる**(6 時間ごとに GitHub のリリースを見て、Ed25519 の署名を確かめ、誰もつないでいないときに入れ替える。v0.3.0 から)。`setup.ps1` の `$version` は初めて入れる版で、Renovate が上げる。動いているほうが新しければ、`setup.ps1` は exe を置き換えない |

## 入れ方・版を上げる

```powershell
pwsh -File mado/setup.ps1
```

普段のユーザーで流す。Infisical の `/shared/entra` から client secret を取り出し、リリースの `mado.exe` を落として
SHA-256 と出どころ(`gh attestation verify`)を確かめたあと、残りを UAC で昇格して流す
(`C:\mado` に置く、IPv6 のアドレス、ファイアウォール、スリープ無効、タスクの登録と起動)。何度流してもよい。
**client secret を回したときも流し直す。**

## 使い方

`https://md.doany.io` を開く → Entra でログイン → つなぐ先を選び(複数あるとき)、Windows のユーザー名とパスワードを入れて「つなぐ」。
画面の上に Ctrl+Alt+Del・Windows キー・全画面・切断のボタンがある。

## 遅いとき

`setup.ps1` はこの PC の RDP を 60fps にしている(レジストリの `DWMFRAMEINTERVAL` = 15。既定は 30fps)。

mado の画面(IronRDP の Web 版)は H.264 を使わず、昔からのビットマップの更新(RemoteFX など)をブラウザの CPU で描く。
普段使いは家の中から Windows App で直接 RDP し、mado は外からの非常口と割り切る。遅いときはブラウザの窓を小さくする
(窓の大きさがそのまま RDP の解像度になる)か、Windows 側で見た目の効果を切る。