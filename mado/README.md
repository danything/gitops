# mado

**`main` が落ちたときの入口。** JCOM 側の PC(10.10.0.2、手元の Windows)で [mado](https://github.com/danything/mado)
(OIDC でログインしてブラウザから RDP する、自作の小さなゲートウェイ。.NET の Windows サービスとタスクトレイ)を動かし、`https://md.doany.io` から
この PC の画面に入るか、Z440 の AMT(10.10.0.3)を直接開いて電源を入れ直し、SOL で Talos のコンソールを見て `main` を直す。
NetBird は管理サーバーも routing peer も `main` の上なので、`main` が落ちると使えない。

| | |
| --- | --- |
| 中身 | ブラウザの中の自前の RDP クライアント(TypeScript)が RDP を話し、mado は Entra の OIDC でのログインの確認と、ブラウザ ↔ この PC の 3389 の中継だけ。Windows のパスワードは mado に届かない |
| 動かし方 | **Windows のサービス `mado`**(MSI で入れる。`C:\Program Files\mado\mado.exe`、LocalSystem、自動起動、落ちたら 5 秒後に起こし直す)。設定・client secret・証明書・ログは `C:\ProgramData\mado\`(`mado.json`、`client-secret.txt`、`data\`、`logs\mado.log`。SYSTEM と Administrators だけが読める)。この PC の中から `http://127.0.0.1:8788/status` で版・つないでいる数・証明書の残り日数が見られる |
| タスクトレイ | `mado-tray.exe`(サインイン時に起動)。動いているか・版・つないでいる数・証明書の残り日数を出し、止まったら通知する。右クリックで画面を開く・今すぐ更新・サービスを再起動・ログ |
| 名前 | `md.doany.io` の A / AAAA を JCOM の固定の IP(`61.21.173.41`、PC に足した `2405:1201:5201:3a00::2`)に([pulumi/dns.ts](../pulumi/dns.ts))。Cloudflare も `main` の Gateway も通さない |
| ルーター | J:COM のアプリで、この PC(OD00)を 10.10.0.2 に予約し、TCP 80 / 443 を転送する。IPv6 はルーターが止めないので設定は要らない([docs/router.md](../docs/router.md)) |
| 証明書 | mado が Let's Encrypt から自分で取る(80 で HTTP-01)。30 日を切ったら取り直す |
| ログイン | Entra の共用のアプリ登録(戻り先 `https://md.doany.io/callback` は [pulumi/entra.ts](../pulumi/entra.ts))。アプリロール `admin` が無いと入れない(ほかのアプリと共通) |
| 設定 | [mado.json](mado.json)。`targets` がつなぐ先(画面で選ぶ。この PC(RDP)と Z440 の AMT(`"type": "amt"`、電源と SOL。AMT の port 16992 / 16994 はルーターで開けない。この PC から届けばよい)と Z440 の Talos(`"type": "talos"`、ダッシュボードとシャットダウン・再起動)。10.0 側の PC は、この PC の Wi-Fi がつながっているときだけ届く)。秘密は書かない(client secret は `setup.ps1` が gitops の SOPS から取り出して `client-secret.txt` に置く)。`required_role` の `admin` はほかのアプリと共通([docs/entra.md](../docs/entra.md)) |
| 版 | **mado が自分で上げる**(6 時間ごとに GitHub のリリースを見て、ECDSA の署名を確かめた MSI を、誰もつないでいないときに入れる)。タスクトレイの「今すぐ更新を確かめる」でもよい。`setup.ps1` は版を固定せず、流したときの最新のリリースを入れる(`gh release view`)。動いているほうが同じか新しければ MSI は入れない |
| Talos のダッシュボード | 一覧の「Z440(Talos)」で `talosctl dashboard`(AMT の認証は要らない。mado が ConPTY で動かして中継する。バーの「シャットダウン」「再起動」は 2 回押しで `talosctl shutdown` / `reboot` を頼む。mado の [docs/talos.md](https://github.com/danything/mado/blob/main/docs/talos.md))。鍵は役割 `os:operator` の talosconfig(90 日。止める・再起動と etcd のスナップショットまでで、設定は変えられない。漏れたときの影響と理由は [docs/decisions.md](../docs/decisions.md))で、`setup.ps1` が管理者の talosconfig(`tools/t.ps1 --admin`。SOPS の Talos の CA からその場で作る)で `talosctl config new --roles os:operator --crt-ttl 2160h` して作り、DPAPI(LocalMachine)で保護して `C:\ProgramData\mado\talosconfig.dpapi` に置く。平文はディスクに書かない(mado も名前付きパイプで talosctl に渡す)。`talosctl.exe` は `tools/Dockerfile` と同じ版を公式の SHA-256 と照らして `C:\ProgramData\mado\bin\` に置く |

## 入れ方

```powershell
pwsh -File mado/setup.ps1
```

普段のユーザーで流す。gitops の SOPS(`deploy/auth/secrets.sops.yaml` の `oidc-client-secret`。age の鍵が無ければパスフレーズを聞く)から client secret を取り出し、Talos の `os:operator` の talosconfig を作って DPAPI で保護し(ノードの 10.10.0.4 に届くこと。クラスタは変えない)、リリースの `mado.msi` を落として
SHA-256 と出どころ(`gh attestation verify`)を確かめたあと、残りを UAC で昇格して流す
(`C:\ProgramData\mado` に設定と client secret を置く → MSI を入れる → サービスを起動し直す。IPv6 のアドレス、60fps、スリープ無効も)。
何度流してもよい。
**client secret を回したときも流し直す。**
**Talos の証明書の期限が近いとき(mado の Talos の画面のバーに「あと N 日で切れます」と出る。14 日前から)も流し直す。** 作り直した talosconfig は次に開くときから使われる(mado の再起動は要らない)。

## 使い方

`https://md.doany.io` を開く → Entra でログイン → つなぐ先を選び(複数あるとき)、Windows のユーザー名とパスワードを入れて「つなぐ」。
画面の上に Ctrl+Alt+Del・Windows キー・全画面・切断のボタンがある。

Z440 の AMT は一覧の「Z440(AMT)」を選び、AMT のユーザー名(`admin`)とパスワードで「開く」。電源の状態と、電源の操作のボタン(2 回押しで確定)、開くとすぐ Talos のシリアルのコンソール(SOL)が出る。

Talos のダッシュボードは一覧の「Z440(Talos)」を選んで「開く」(ユーザー名とパスワードは要らない)。`talosctl dashboard` が出る(F1〜F4 で画面を切り替え、`q` で閉じる。「もう一度開く」で開き直す)。
バーの「シャットダウン」「再起動」は Talos に止める準備をさせてから電源を切る・再起動する(2 回押しで確定。AMT の強制電源オフ・強制再起動より先にこちらを使う)。
AMT のパスワードはブラウザの中で Digest の計算に使うだけで、mado には届かない。詳しくは mado の [docs/amt.md](https://github.com/danything/mado/blob/main/docs/amt.md)。

## 遅いとき

`setup.ps1` はこの PC の RDP を 60fps にしている(レジストリの `DWMFRAMEINTERVAL` = 15。既定は 30fps)。

mado の画面(自前の RDP クライアント)は H.264 を使わず、昔からのビットマップの更新(RemoteFX など)をブラウザの CPU で描く。
普段使いは家の中から Windows App で直接 RDP し、mado は外からの非常口と割り切る。遅いときはブラウザの窓を小さくする
(窓の大きさがそのまま RDP の解像度になる)か、「窓に合わせる(画素数 50%)」にする(解像度を半分にして拡大表示する)か、Windows 側で見た目の効果を切る。