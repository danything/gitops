#!/bin/sh
# メンテナンス表示の入り切り。やっているのは *.doany.io の proxied (オレンジ雲) を倒すだけ。
# proxied になると Cloudflare が TLS を終端し、worker.js の route が当たるようになる。
# オリジン (このクラスタ) が落ちていれば Worker がメンテページを返す。
#
#   CF_API_TOKEN=... ./maintenance.sh status|on|off
#
# トークンは Zone:DNS:Edit があればよい。Traefik の DNS-01 用と同じもので足りる:
#   CF_API_TOKEN=$(sops -d bootstrap/traefik/cloudflare-secret.yaml | awk '/CF_DNS_API_TOKEN/{print $2}')
#
# 注意: proxied にすると HTTP/HTTPS 以外は通らなくなる (WireGuard の UDP 51820、
# AdGuard の DNS/DoT、3proxy の TCP)。メンテ中はどのみち落ちているので実害は無いが、
# 作業を LAN か iLO からやること (cloudflared 経由の ssh も含めて外からは入れない)。

set -eu

ZONE="${ZONE:-doany.io}"
RECORD="${RECORD:-*.doany.io}"
API="https://api.cloudflare.com/client/v4"
: "${CF_API_TOKEN:?set CF_API_TOKEN (Zone:DNS:Edit)}"

api() {
	method="$1"; path="$2"; shift 2
	curl -sS -X "$method" "$API$path" \
		-H "Authorization: Bearer $CF_API_TOKEN" \
		-H "Content-Type: application/json" "$@"
}

zone_id() {
	api GET "/zones?name=$ZONE" | python3 -c '
import sys,json
o=json.load(sys.stdin)
if not o.get("success") or not o.get("result"): sys.exit("zone lookup failed: %s" % o.get("errors"))
print(o["result"][0]["id"])'
}

records() {
	api GET "/zones/$1/dns_records?per_page=200" | python3 -c '
import sys,json
o=json.load(sys.stdin)
for r in sorted(o["result"], key=lambda r: r["name"]):
    if r["type"] in ("A","AAAA","CNAME"):
        print(r["id"], r["name"], r["type"], r.get("proxied"))'
}

ZID="$(zone_id)"

case "${1:-status}" in
	status)
		printf '%-34s %-6s %s\n' NAME TYPE PROXIED
		records "$ZID" | while read -r id name type proxied; do
			printf '%-34s %-6s %s\n' "$name" "$type" "$proxied"
		done
		;;
	on|off)
		want=false; [ "$1" = on ] && want=true
		records "$ZID" | while read -r id name type proxied; do
			[ "$name" = "$RECORD" ] || continue
			[ "$proxied" = "True" ] && cur=true || cur=false
			if [ "$cur" = "$want" ]; then
				echo "$name: already proxied=$want"
			else
				api PATCH "/zones/$ZID/dns_records/$id" --data "{\"proxied\":$want}" \
					| python3 -c 'import sys,json;o=json.load(sys.stdin);print("%s: proxied=%s" % (o["result"]["name"], o["result"]["proxied"]) if o["success"] else "FAILED: %s" % o["errors"])'
			fi
		done
		echo "反映は数十秒。ブラウザ側の DNS キャッシュに注意。"
		;;
	*)
		echo "usage: CF_API_TOKEN=... $0 status|on|off" >&2; exit 1 ;;
esac
