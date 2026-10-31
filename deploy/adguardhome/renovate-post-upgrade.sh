#!/usr/bin/env bash
# Renovate の postUpgradeTasks から呼ぶ(renovate.json)。AdGuard Home の版を上げた枝で、deployment.yaml の設定(initContainer の `CONFIG`)を新しい版に移行させる。
#
# AdGuard は起動時に古い schema_version の設定を移行する。git の設定は起動のたびに PVC に書き戻すので、
# そのままでも動くが、git 側は古い schema_version のまま残り、移行が外された版で起動に失敗する。そこで版上げの PR の中で
# 新しい版に `--check-config` させる。これは移行が要るときだけ設定ファイルを書き直し(要らなければ一切書かない)、
# 読めない設定なら失敗する(= PR の postUpgradeTasks が落ちて気づける)。書き直したら deployment.yaml に戻す。
#
# 動くのは Renovate のコンテナ(ghcr.io/renovatebot/renovate、deploy/renovate/renovate.yaml の CronJob)の中、リポジトリの直下。
# AdGuard の版は deployment.yaml のイメージのタグ(Renovate が上げた後の値)から取り、公式のチェックサムと照らしてから使う。
# 許可は deploy/renovate/renovate.yaml の RENOVATE_ALLOWED_COMMANDS
set -euo pipefail
cd "$(dirname "$0")"

v=$(sed -n 's|^ *image: adguard/adguardhome:\(v[0-9.]*\).*$|\1|p' deployment.yaml)
[ -n "$v" ] || { echo "deployment.yaml に adguard/adguardhome のタグが見つからない" >&2; exit 1; }
a=$(uname -m); case "$a" in x86_64) a=amd64 ;; aarch64) a=arm64 ;; esac
f=AdGuardHome_linux_$a.tar.gz
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
base=https://github.com/AdguardTeam/AdGuardHome/releases/download/$v
curl -fsSL -o "$d/$f" "$base/$f"
# checksums.txt の行は「<sha256>  ./<ファイル名>」
want=$(curl -fsSL "$base/checksums.txt" | awk -v f="./$f" '$2 == f { print $1 }')
[ -n "$want" ] || { echo "checksums.txt に $f が無い" >&2; exit 1; }
echo "$want  $d/$f" | sha256sum -c --strict - >/dev/null
tar -xzf "$d/$f" -C "$d"

# deployment.yaml の「            - name: CONFIG」の次の「              value: |」から、字下げが 16 文字より浅い行の手前までが
# AdGuard の設定(16 文字字下げ)
grep -qxF '            - name: CONFIG' deployment.yaml || { echo "deployment.yaml に CONFIG の env が無い" >&2; exit 1; }
# s: 0=前 1=value: | を待つ 2=本体 3=後
split() { # $1=前/本体/後 のどれを出すか
  awk -v want="$1" '
    s == 0 && $0 == "            - name: CONFIG" { print_line("pre"); s = 1; next }
    s == 1 { print_line("pre"); if ($0 == "              value: |") s = 2; next }
    s == 2 && length($0) && $0 !~ /^                / { s = 3 }
    s == 2 { if (want == "body") { sub(/^                /, ""); print } next }
    { print_line(s == 3 ? "post" : "pre") }
    function print_line(part) { if (part == want) print }
  ' deployment.yaml
}
split body >"$d/AdGuardHome.yaml"
cp "$d/AdGuardHome.yaml" "$d/before.yaml"

"$d/AdGuardHome/AdGuardHome" --check-config --no-check-update -c "$d/AdGuardHome.yaml" -w "$d"

if cmp -s "$d/before.yaml" "$d/AdGuardHome.yaml"; then
  echo "AdGuard $v: 移行は要らなかった"
  exit 0
fi

{
  split pre
  awk '{ print (length($0) ? "                " $0 : "") }' "$d/AdGuardHome.yaml"
  split post
} >"$d/deployment.yaml"
mv "$d/deployment.yaml" deployment.yaml
echo "AdGuard $v: 設定を移行した ($(sed -n 's/^                schema_version: //p' deployment.yaml))"
