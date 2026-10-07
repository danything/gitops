#!/bin/sh
# NetBird の SDK (sdks/netbird) を作り直す。tools の中で流す: `tools/t sh pulumi/sdks/generate.sh`
#
# **SDK は生成物だが git に入れる。** Pulumi のおすすめは .gitignore して `pulumi install` で作らせる形だが、
# `runtime: bun` だと Pulumi が `pulumi-language-bun` を探しに行って生成できない (3.267.0 で確認。
# bun は Node.js の言語ホストが動かしているのに、生成だけは runtime の名前で言語を引く)。
# なので `runtime: nodejs` (packagemanager: bun) の使い捨てのプロジェクトで生成して、ここへ写す。
#
# 版を上げるときは下の VERSION を変えて流す (Renovate が PR で知らせる。renovate.json)。
# SDK の package.json の typescript / @types/node が古いのは Pulumi の生成がわざと下限 (^4.7.0 / ^20) を書くため。
# ビルド (bun install のとき) にしか使わないので追わない
set -eu

# renovate: datasource=terraform-provider depName=netbirdio/netbird
VERSION=0.0.10

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
cat > Pulumi.yaml <<EOF
name: sdkgen
runtime:
  name: nodejs
  options:
    packagemanager: bun
EOF
echo '{"name": "sdkgen", "private": true}' > package.json
PULUMI_SKIP_UPDATE_CHECK=1 pulumi package add terraform-provider netbirdio/netbird "$VERSION"

rm -rf "$here/netbird"
cp -R sdks/netbird "$here/netbird"
rm -rf "$here/netbird/node_modules" "$here/netbird/bin"
cd "$here/.." && bun install
