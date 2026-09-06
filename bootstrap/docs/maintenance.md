# メンテナンスページ

Talos 入れ替えのようにクラスタごと落とすあいだ、`doany.io` 配下を Cloudflare 側で受けてメンテナンス表示にする。

## 仕組み

Cloudflare の DNS は `*.doany.io` のワイルドカード CNAME 1 本でほぼ全部のサブドメインを賄っている
(明示レコードは apex と `l` `ts` `w` `x` `y` だけ)。**このワイルドカードの proxied を倒すだけ**で、
Cloudflare が TLS を終端してリクエストを受けるようになる。

そこに Worker (`worker.js`) を被せてある。中身は「まずオリジンに投げて、届かなかったときだけメンテページを返す」。
平常時は素通しなので置きっぱなしにでき、計画メンテだけでなく突然の障害でも 521/522 の代わりに読めるページが出る。

```
平常時   client → (灰色雲) → 自宅の Traefik
メンテ中 client → (オレンジ雲) → Worker → オリジン不達 → 503 メンテページ
```

## 準備 (1 回だけ)

```shell
cd bootstrap/maintenance
npx wrangler login          # または Workers Scripts:Edit を持つトークン
npx wrangler deploy         # route も wrangler.toml から作られる
```

route は proxied なホストにしか当たらないので、deploy した時点では `l` `ts` `w` `x` `y` と apex だけが
Worker を通る (中身は素通し)。挙動が変わらないことを確認しておくとよい。

## 当日

```shell
export CF_API_TOKEN=$(sops -d ../traefik/cloudflare-secret.yaml | awk '/CF_DNS_API_TOKEN/{print $2}')
./maintenance.sh status     # いまの proxied を一覧
./maintenance.sh on         # *.doany.io を proxied に → 全サブドメインがメンテページ
#   … Talos インストール …
./maintenance.sh off        # 元に戻す
```

## 注意

- **proxied にすると HTTP/HTTPS 以外は通らない。** WireGuard の UDP 51820 (`v.doany.io`)、AdGuard の DNS/DoT
  (`a.doany.io`)、3proxy の TCP (`px.doany.io`)、Mattermost の calls (UDP) は切れる。どのみちクラスタごと
  止めるので実害は無いが、**作業は LAN (10.0.0.2 / 10.10.0.4) か iLO (10.0.0.3) から行うこと。**
  cloudflared 経由の ssh も外からは入れない前提で動く。
- 証明書は Cloudflare の Universal SSL (`doany.io` と `*.doany.io`) が使われる。Traefik の Let's Encrypt 証明書は
  メンテ中は出番が無い。
- `off` に戻したあと、ブラウザやリゾルバのキャッシュで数分ずれることがある。
- `cloudflare-ddns` はクラスタの中にいるので、メンテ中は apex の A/AAAA を触らない。IP が変わると復帰後に
  自分で直す。
