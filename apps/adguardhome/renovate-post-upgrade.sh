#!/usr/bin/env bash
# Renovate の postUpgradeTasks から呼ぶ(renovate.json)。AdGuard Home の版を上げた枝で、config.yaml の設定を新しい版に移行させる。
#
# AdGuard は起動時に古い schema_version の設定を移行する。git の config.yaml は起動のたびに PVC に書き戻すので、
# そのままでも動くが、git 側は古い schema_version のまま残り、移行が外された版で起動に失敗する。そこで版上げの PR の中で
# 新しい版に `--check-config` させる。これは移行が要るときだけ設定ファイルを書き直し(要らなければ一切書かない)、
# 読めない設定なら失敗する(= PR の postUpgradeTasks が落ちて気づける)。書き直したら config.yaml に戻し、
# deployment.yaml の doany.io/config-sha256 も合わせる(CI の adguard-config が見る)。
#
# 動くのは Renovate のコンテナ(ghcr.io/renovatebot/renovate、5ym/repo-config の renovate.yml)の中、リポジトリの直下。
# AdGuard の版は deployment.yaml のイメージのタグ(Renovate が上げた後の値)から取り、公式のチェックサムと照らしてから使う。
# 許可は repo-config の renovate.yml の RENOVATE_ALLOWED_COMMANDS
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

# ConfigMap の「  AdGuardHome.yaml: |」より後(4 文字字下げ)が AdGuard の設定。前はコメントと ConfigMap の頭
marker='  AdGuardHome.yaml: |'
grep -qxF "$marker" config.yaml || { echo "config.yaml に「$marker」の行が無い" >&2; exit 1; }
awk -v m="$marker" 'f { sub(/^    /, ""); print } $0 == m { f = 1 }' config.yaml >"$d/AdGuardHome.yaml"
cp "$d/AdGuardHome.yaml" "$d/before.yaml"

"$d/AdGuardHome/AdGuardHome" --check-config --no-check-update -c "$d/AdGuardHome.yaml" -w "$d"

if cmp -s "$d/before.yaml" "$d/AdGuardHome.yaml"; then
  echo "AdGuard $v: 移行は要らなかった"
  exit 0
fi

{
  awk -v m="$marker" '{ print } $0 == m { exit }' config.yaml
  awk '{ print (length($0) ? "    " $0 : "") }' "$d/AdGuardHome.yaml"
} >"$d/config.yaml"
mv "$d/config.yaml" config.yaml
sum=$(sha256sum config.yaml | cut -d' ' -f1)
sed -i "s|^\( *doany.io/config-sha256: *\)[0-9a-f]*$|\1$sum|" deployment.yaml
echo "AdGuard $v: config.yaml を移行した ($(sed -n 's/^    schema_version: //p' config.yaml))"
