# meshcentral

**`main` が落ちたときの入口。** JCOM 側の PC(10.10.0.2、手元の Windows)で [MeshCentral](https://github.com/Ylianst/MeshCentral) を
Windows サービスとして動かし、`https://mc.doany.io` で外から入る(2026-10-11)。

それまでは NetBird(`main` のクラスタの中の routing peer)で LAN に入り、この PC に RDP していた。NetBird の管理サーバーも
routing peer も `main` にあるので、`main` が落ちると入れなくなり、JCOM のルーターで 3389 を開けて直接 RDP していた。
MeshCentral はこの PC だけで完結するので、`main` が落ちていても入れる。入ったら、この PC の画面から iLO(10.0.0.3)や
Z440 の AMT(10.0.0.5。[docs/z440-migration.md](../docs/z440-migration.md))を開いて `main` を直す。

## 構成

| | |
| --- | --- |
| 動かし方 | Node.js + `C:\meshcentral` の MeshCentral を Windows サービス(`MeshCentral`)で。**WSL(wslc)では動かさない** ── サインインするまで起動しないので、停電のあとに入れない |
| 名前 | `mc.doany.io` の A を JCOM の固定の IP(`61.21.173.41`)に([pulumi/dns.ts](../pulumi/dns.ts))。Cloudflare も `main` の Gateway も通さない。**IPv4 だけ** ── JCOM のルーターに IPv6 で外からの接続を通す設定が無い |
| ルーター | JCOM の HUMAX HGJ310V4 は Plume の機種で、設定は **J:COM のアプリ**だけ。「設定 → ネットワーク → IP 予約」でこの PC(OD00)を 10.10.0.2 に予約し、同じ画面で TCP 80 / 443 を転送する |
| 証明書 | MeshCentral に組み込みの Let's Encrypt(80 で HTTP-01) |
| ログイン | Entra の OIDC だけ(共用のアプリ登録 `b0fa498f-…`。リダイレクト URI は [pulumi/entra.ts](../pulumi/entra.ts))。アプリロール `admin` が無いと入れず、あればサイト管理者([docs/entra.md](../docs/entra.md))。**`admin` はほかのアプリ(Argo CD・Headlamp など)と共通**で、どれかの管理者はここでも管理者になる(LAN の PC を操作できる)。ID とパスワードの欄は出さず、自分でのアカウント作成もさせない |
| AMT | LAN の中から直接つなぐ(この PC の Wi-Fi から 10.0 側へ)。AMT のほうから外へつないでくる CIRA は使わないので、その受け口(MPS、4433)は `mpsPort: 0` で閉じている |
| 更新 | `selfUpdate`: 毎晩 0 時すぎに自分で新しい版を見て上げる。インターネットに直接出ているので、上げ遅れないようにする |

設定は [config.json](config.json)(`C:\meshcentral\meshcentral-data\config.json` に置く。client secret は置くときに埋める)。

## 入れ方

1. J:COM のアプリで上の「ルーター」を設定する
2. 普段のユーザーで流す。Infisical の `/shared/entra` から client secret を取り出し、残りを UAC で昇格して流す
   (Node.js、MeshCentral、ファイアウォール、スリープ無効、サービス)。何度流してもよい

   ```powershell
   pwsh -File meshcentral/setup.ps1
   ```

3. `https://mc.doany.io` を開いて Entra でログインする(最初のログインでアカウントができる)
4. デバイスグループを作り、**この PC にエージェントを入れる**(画面の「エージェントを追加」の Windows 版)。
   エージェントからこの PC の画面・ターミナル・ファイルが使える
5. Z440 に移ったら、AMT のデバイスとして 10.0.0.5 を足す(電源操作・SOL・IDE-R)

**client secret を回したら `setup.ps1` を流し直す**(このファイルは Infisical の参照を読まない)。

## 確かめていないこと

- ロール(`roles` の claim)を MeshCentral が ID トークンから読むか。読まないと `required` で全員が弾かれる。
  最初のログインで弾かれたら `groups` を外して入り、ログを見る(`C:\meshcentral\meshcentral-data` の下)

## 気をつけること

- **10.0 側(iLO・AMT)へは、この PC の Wi-Fi(au)でつなぐ。** 有線は JCOM 側だけ。Wi-Fi は自動で接続するようにしておく
- **この PC が落ちていると入れない。** スリープは `setup.ps1` で止めている。BIOS で「通電したら起動」にしておく
- 3389 はもう開けない
