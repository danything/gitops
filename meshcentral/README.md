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
| 動かし方 | Node.js + `C:\meshcentral` の MeshCentral を Windows サービス(名前 `meshcentral.exe`、表示名 `MeshCentral`)で。**WSL(wslc)では動かさない** ── サインインするまで起動しないので、停電のあとに入れない |
| 名前 | `mc.doany.io` の A / AAAA を JCOM の固定の IP(`61.21.173.41` と、PC に足した `2405:1201:5201:3a00::2`)に([pulumi/dns.ts](../pulumi/dns.ts))。Cloudflare も `main` の Gateway も通さない |
| ルーター | JCOM の HUMAX HGJ310V4 は Plume の機種で、設定は **J:COM のアプリ**だけ。IPv4 は「設定 → ネットワーク → IP 予約」でこの PC(OD00)を 10.10.0.2 に予約し、同じ画面で TCP 80 / 443 を転送する。**IPv6 はルーターが外からの接続を何も止めない**(2026-10-11 に au 側の `main` から確かめた)ので設定は要らず、止めるのは各機器のファイアウォールだけ。アプリの Guard の「Remote Access Protection」は無効のままにする(有効にすると転送した 80 / 443 も許可待ちで止まる) |
| 証明書 | MeshCentral に組み込みの Let's Encrypt(80 で HTTP-01。IPv6 でも確認しに来る) |
| ログイン | Entra の OIDC だけ(共用のアプリ登録 `b0fa498f-…`。リダイレクト URI は [pulumi/entra.ts](../pulumi/entra.ts))。アプリロール `admin` が無いと入れず、あればサイト管理者([docs/entra.md](../docs/entra.md))。**`admin` はほかのアプリ(Argo CD・Headlamp など)と共通**で、どれかの管理者はここでも管理者になる(LAN の PC を操作できる)。ID とパスワードの欄は出さず、自分でのアカウント作成もさせない |
| AMT | LAN の中から直接つなぐ(この PC の Wi-Fi から 10.0 側へ)。AMT のほうから外へつないでくる CIRA は使わないので、その受け口(MPS、4433)は `mpsPort: 0` で閉じている |
| ログ | ログインの経過(OIDC の設定、誰がどのロールで入ったか、弾いた理由)は `C:\meshcentral\meshcentral-data\auth.log`(`authLog`。管理者だけが読める)。**ログアウト用の URL に ID トークンがそのまま書かれる**ので、外に出さない。サービスの標準出力は `C:\meshcentral\WinService\daemon\meshcentral.out.log` |
| 画面 | 新しい UI(Bootstrap の「Modern UI」)を既定にする(`siteStyle: 3`。2026-10-11)。まだ公式の既定ではなく、スマホの表示やファイル転送の進み具合に未解決の不具合がある(#7838・#8145)ので、`showModernUIToggle` で画面から旧 UI に戻せるようにしてある(選んだほうはユーザーごとに覚える)。URL に `?sitestyle=1` を付けてもそのときだけ旧 UI |
| テーマ | [shadcn](https://github.com/bherbruck/meshcentral-shadcn-theme)(MIT。shadcn/ui 風、ライト / ダーク)を [theme-pack/shadcn/](theme-pack/shadcn/) に**取り込んで**使う(`themePack`。`setup.ps1` が `meshcentral-data\theme-pack\` に置く)。コミット `d7e7a65`(2026-09-21、1.2.5 で作られたもの)。MeshCentral の公式の theme pack の口(新しい UI のときだけ `styles/theme.css` と `scripts/theme.js` を読む)に CSS を足すだけで、画面のファイルは書き換えないので、selfUpdate で版が上がっても崩れにくい。JS は管理画面の中で動くので、取り込み直すときは中身を読む(今の JS はダークモードをログイン画面に揃えるだけ。CSS は同梱のフォントと埋め込みの SVG しか読まない)。やめるときは `themePack` の行を消す |
| 更新 | `selfUpdate`: 毎晩 0 時すぎに自分で新しい版を見て上げる。インターネットに直接出ているので、上げ遅れないようにする |

設定は [config.json](config.json)(`C:\meshcentral\meshcentral-data\config.json` に置く。client secret は置くときに埋める)。

## 入れ方

1. J:COM のアプリで上の「ルーター」(IPv4 の IP 予約と転送)を設定する
2. 普段のユーザーで流す。Infisical の `/shared/entra` から client secret を取り出し、残りを UAC で昇格して流す
   (Node.js、MeshCentral、IPv6 のアドレス、ファイアウォール、スリープ無効、サービス)。何度流してもよい

   ```powershell
   pwsh -File meshcentral/setup.ps1
   ```

3. `https://mc.doany.io` を開いて Entra でログインする(最初のログインでアカウントができる)
4. デバイスグループを作り、**この PC にエージェントを入れる**(画面の「エージェントを追加」の Windows 版)。
   エージェントからこの PC の画面・ターミナル・ファイルが使える
5. Z440 に移ったら、AMT のデバイスとして 10.0.0.5 を足す(電源操作・SOL・IDE-R)

**client secret を回したら `setup.ps1` を流し直す**(このファイルは Infisical の参照を読まない)。

## ロール

MeshCentral は既定では userinfo の答えだけを見ていて、Entra はそこにロールを入れない。**`custom.authorities: ["roles"]`
があるときだけ ID トークンの `roles` を読む**(1.2.5 の webserver.js の `oidcCallback`)。これが無いと `roles` が空になり、
`required` で全員が弾かれる(2026-10-11、最初のログインがそうだった。auth.log に `Login denied. No membership to required group.`)。
`authorities` に `groups` を入れないので、`groups` のスコープも要求しない(Entra は知らないスコープを拒む)

## 気をつけること

- **10.0 側(iLO・AMT)へは、この PC の Wi-Fi(au)でつなぐ。** 有線は JCOM 側だけ。Wi-Fi は自動で接続するようにしておく
- **この PC が落ちていると入れない。** スリープは `setup.ps1` で止めている。BIOS で「通電したら起動」にしておく
- 3389 はもう開けない
- **JCOM 側の LAN の機器は、IPv6 ではインターネットからそのまま届く**(ルーターが止めない。上の「ルーター」)。
  この PC は Windows のファイアウォールが 80 / 443 以外を止めているが、プリンターなどは機器まかせ
