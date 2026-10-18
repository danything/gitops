#!/usr/bin/env bash
# 鍵の期限を見て、30 日を切ったか切れていたら Matrix の部屋 server に知らせる。pulumi.yml の expiry ジョブから呼ぶ。
#
# 期限を API から読めるものだけを見る。日付を手で書くファイルは置かない (書き忘れと書き換え忘れが起きる)。
# **鍵は自分の期限だけを読む。** NetBird の Auditor は利用者の一覧は読めても他人のトークンは読めない (403) ので、
# preview 用と apply 用をそれぞれのジョブで使う (KEY=preview|apply)。
#   - NetBird のサービスユーザーのトークン (README.md「NetBird」)
#   - Cloudflare の API トークン (期限が付いていれば)
#   - Entra のアプリ登録のクライアントシークレットと証明書 (テナントの全部。共用の Main が切れると SSO が全部止まる)。
#     preview のジョブだけで見る (az login 済みであること)
# 期限の無いもの (WINGET_TOKEN など) は対象外。
#
# env: KEY NB_PAT CF_TOKEN CF_ACCOUNT WEBHOOK DRY_RUN REPORT_ALL WARN_DAYS
set -euo pipefail
now=$(date -u +%s)
items=$(mktemp)   # 1 行 1 件: 残り日数<TAB>名前<TAB>期限

add() { # $1 名前 $2 期限 (ISO 8601)
  local exp; exp=$(date -u -d "$2" +%s)
  # 切り捨てを負の側にも効かせる (切れて 1 日未満を「あと 0 日」にしない)
  local d=$(( exp - now )); d=$(( d < 0 ? -((-d + 86399) / 86400) : d / 86400 ))
  printf '%s\t%s\t%s\n' "$d" "$1" "$(date -u -d "$2" +%Y-%m-%d)" >> "$items"
}

# NetBird: この鍵のサービスユーザー (gitops-pulumi-<preview|apply>) のトークン。名前で選ぶ:
# サービスユーザーは users/current が 403 で自分を引けず、apply 用 (Admin) は他人のトークンも読めて二重に数えてしまう
nb() { curl -fsS -H "Authorization: Token $NB_PAT" -H "Accept: application/json" "https://nb.doany.io/api/$1"; }
u=$(nb "users?service_user=true" | jq -r --arg n "gitops-pulumi-$KEY" '.[] | select(.name == $n) | .id')
[ -n "$u" ] || { echo "NetBird: サービスユーザー gitops-pulumi-$KEY が無い" >&2; exit 1; }
# 先に変数へ受ける (`< <(…)` だと失敗しても落ちない)
tokens=$(nb "users/$u/tokens" | jq -r '.[] | select(.expiration_date) | [.name, .expiration_date] | @tsv')
while IFS=$'\t' read -r tname exp; do
  if [ -n "$tname" ]; then add "NetBird gitops-pulumi-$KEY / $tname" "$exp"; fi
done <<< "$tokens"

# Cloudflare: この鍵自身 (期限が無ければ null)。アカウントのトークンは accounts/<ID>/tokens/verify でしか確かめられない
cf() { curl -fsS -H "Authorization: Bearer $CF_TOKEN" "https://api.cloudflare.com/client/v4/$1/tokens/verify"; }
cf_exp=$( { cf user 2>/dev/null || cf "accounts/$CF_ACCOUNT"; } | jq -r '.result.expires_on // empty')
[ -n "$cf_exp" ] && add "Cloudflare ($KEY 用)" "$cf_exp"

# Entra: テナントの全アプリ登録のシークレットと証明書 (preview のジョブだけ。apply と二重に数えない)
if [ "$KEY" = preview ]; then
  creds=$(az rest --method GET --url 'https://graph.microsoft.com/v1.0/applications?$select=displayName,passwordCredentials,keyCredentials&$top=999' |
    jq -r '.value[] | .displayName as $app | ((.passwordCredentials // []) + (.keyCredentials // []))[] | select(.endDateTime) | [$app, (.displayName // .keyId), .endDateTime] | @tsv')
  while IFS=$'\t' read -r app cname exp; do
    if [ -n "$app" ]; then add "Entra $app / $cname" "$exp"; fi
  done <<< "$creds"
fi

sort -n "$items" | tee /dev/stderr > "$items.sorted"
if [ "$REPORT_ALL" = true ]; then
  due=$(cat "$items.sorted")
else
  due=$(awk -F'\t' -v w="$WARN_DAYS" '$1 <= w' "$items.sorted")
fi
if [ -z "$due" ]; then echo "期限が近いものは無い"; exit 0; fi

lines=$(printf '%s\n' "$due" | awk -F'\t' '{ s = ($1 < 0) ? "切れている" : "あと " $1 " 日"; printf "- **%s**: %s (%s)\n", $2, $3, s }')
if [ "$REPORT_ALL" = true ]; then
  text=$(printf ':key: 鍵の期限 (%s 用、全部)\n\n%s' "$KEY" "$lines")
else
  text=$(printf ':key: 鍵の期限 (%s 用、%s 日以内)\n\n%s\n\n作り直して差し替える。手順は gitops の pulumi/README.md' "$KEY" "$WARN_DAYS" "$lines")
fi
if [ "$DRY_RUN" = true ]; then
  echo "--- 投稿する内容 (PR なので投稿しない)"; echo "$text"; exit 0
fi
jq -n --arg text "$text" '{text: $text}' | curl -fsS -X POST -H "Content-Type: application/json" --data-binary @- "$WEBHOOK"

